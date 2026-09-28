"""Invite codes and ``POST /agents/enroll`` — self-service but not open.

The relay is reachable from the public internet, so the whole point of this
route is that it is *closed*: no valid, unused, unexpired invite, no identity.
These tests pin that, plus the properties a distributed flow depends on — the
secret is returned exactly once, only its hash is stored, and a redeemed code
cannot be replayed.
"""

from __future__ import annotations

import pytest

from store import DEFAULT_INVITE_TTL_MS, InviteRejected, Store


async def test_enroll_happy_path_returns_a_usable_identity(client, store):
    invite = store.mint_invite(note="for Sam")

    response = await client.post("/agents/enroll", json={
        "inviteCode": invite["code"],
        "name": "Sam's MacBook",
    })
    assert response.status == 200, await response.text()
    body = await response.json()
    assert body["ok"] is True
    assert body["agentId"].startswith("agt_")
    assert body["agentSecret"].startswith("as_")
    assert body["agentName"] == "Sam's MacBook"
    assert body["accountId"].startswith("acc_")

    # The returned secret is the real credential, not a decorative string.
    agent = store.agent_by_secret(body["agentSecret"])
    assert agent is not None
    assert agent["agentId"] == body["agentId"]
    assert agent["accountId"] == body["accountId"]
    assert agent["name"] == "Sam's MacBook"
    assert agent["disabled"] == 0

    # And it is its own account: enrolling must never join an existing one.
    assert store.get_account(body["accountId"])["name"] == "Sam's MacBook"


async def test_enroll_creates_a_separate_account_per_invite(client, store):
    first = store.mint_invite()
    second = store.mint_invite()
    one = await (await client.post("/agents/enroll", json={"inviteCode": first["code"], "name": "A"})).json()
    two = await (await client.post("/agents/enroll", json={"inviteCode": second["code"], "name": "B"})).json()
    assert one["accountId"] != two["accountId"]
    assert one["agentId"] != two["agentId"]
    assert one["agentSecret"] != two["agentSecret"]
    assert len(store.list_accounts()) == 2


async def test_enroll_invite_is_one_time(client, store):
    invite = store.mint_invite()
    payload = {"inviteCode": invite["code"], "name": "Sam"}
    assert (await client.post("/agents/enroll", json=payload)).status == 200

    replay = await client.post("/agents/enroll", json=payload)
    assert replay.status == 404
    assert (await replay.json())["error"]["code"] == "enroll/used"


async def test_enroll_rejects_an_expired_invite(client, store):
    invite = store.mint_invite(ttl_ms=-1000)
    response = await client.post("/agents/enroll", json={"inviteCode": invite["code"], "name": "Sam"})
    assert response.status == 404
    assert (await response.json())["error"]["code"] == "enroll/expired"
    # An expired code must not leave a half-created account behind.
    assert store.list_accounts() == []


async def test_enroll_rejects_an_unknown_invite(client, store):
    response = await client.post("/agents/enroll", json={"inviteCode": "ZZZZ-ZZZZ-ZZZZ-ZZZZ", "name": "Sam"})
    assert response.status == 404
    assert (await response.json())["error"]["code"] == "enroll/unknown"
    assert store.list_accounts() == []


@pytest.mark.parametrize("payload", [
    {},
    {"inviteCode": ""},
    {"inviteCode": "   "},
    {"name": "Sam"},
])
async def test_enroll_rejects_bad_input(client, payload):
    response = await client.post("/agents/enroll", json=payload)
    assert response.status == 400
    assert (await response.json())["ok"] is False


async def test_enroll_rejects_non_json(client):
    response = await client.post("/agents/enroll", data=b"not json",
                                 headers={"content-type": "application/json"})
    assert response.status == 400


async def test_enroll_is_rate_limited_per_code(client, store):
    """A frozen code cannot be used to probe the relay indefinitely.

    Five failures are allowed against one code — that is what the budget means —
    and the next request naming it is refused.
    """
    for _ in range(5):
        assert (await client.post("/agents/enroll",
                                  json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})).status == 404
    blocked = await client.post("/agents/enroll", json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})
    assert blocked.status == 429
    assert (await blocked.json())["error"]["code"] == "enroll/rate-limited"
    assert store.list_accounts() == []


async def test_enroll_is_rate_limited_per_client_across_codes(client, store):
    """The per-code budget alone bounds nothing, so the client has its own.

    Invite codes are handed out publicly — review notes, chat, a screenshot — so
    an attacker who spends one failed guess per code never fills any single
    code's bucket. Keying only on the code (which is what this route did before
    CI-02) let them probe indefinitely; the client address is what accumulates.

    Under the owner's ruling of 2026-09-25 the client bucket is a *record*, not a
    veto: the failures are charged to it and stay visible to the operator, but
    they do not stop a valid code. What still stops the walk is the code bucket —
    five guesses against any one code and that code is frozen. Both are asserted
    here, so neither can quietly become the other.
    """
    for index in range(5):
        response = await client.post("/agents/enroll",
                                     json={"inviteCode": f"AAAA-BBBB-CCCC-DDD{index}"})
        assert response.status == 404, await response.text()
    limiter = client.app["enroll_limiter"]
    assert limiter.blocked("127.0.0.1") is True, "同一来源的失败必须被累计"
    assert limiter.failures_total == 5

    # Hammering one code is still bounded: the sixth guess against it is refused.
    for _ in range(5):
        await client.post("/agents/enroll", json={"inviteCode": "EEEE-FFFF-GGGG-HHHH"})
    frozen = await client.post("/agents/enroll", json={"inviteCode": "EEEE-FFFF-GGGG-HHHH"})
    assert frozen.status == 429
    assert (await frozen.json())["error"]["code"] == "enroll/rate-limited"

    # A different client is a different bucket and is unaffected.
    invite = store.mint_invite()
    other = await client.post("/agents/enroll",
                              json={"inviteCode": invite["code"], "name": "Sam"},
                              headers={"X-Forwarded-For": "203.0.113.8"})
    assert other.status == 200, await other.text()


async def test_a_valid_code_is_admitted_after_five_failures_from_the_same_client(client, store):
    """A valid invite is sufficient to get in, whatever the client did before.

    Owner's ruling, 2026-09-25: the failures are counted and attributable, but
    they must not veto the operator's own decision to admit someone. The exact
    sequence asked for: five failures from one source, then the *valid* code.
    """
    for _ in range(5):
        assert (await client.post("/agents/enroll",
                                  json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})).status == 404
    # The failures really were accumulated against this source…
    limiter = client.app["enroll_limiter"]
    assert limiter.blocked("127.0.0.1") is True
    assert limiter.failures_total == 5

    # …and the valid code goes through anyway.
    invite = store.mint_invite()
    admitted = await client.post("/agents/enroll",
                                 json={"inviteCode": invite["code"], "name": "Late but valid"})
    assert admitted.status == 200, await admitted.text()
    body = await admitted.json()
    assert body["ok"] is True
    assert body["agentId"].startswith("agt_")
    assert body["agentSecret"].startswith("as_")
    assert body["agentName"] == "Late but valid"
    # A real identity was created, not just a 200.
    assert store.agent_by_secret(body["agentSecret"]) is not None
    assert len(store.list_accounts()) == 1

    # The five failures are still on the books — for watching, not for vetoing.
    assert limiter.failures_total == 5

    # The code itself was consumed exactly once, like any other redemption. This
    # rejection is itself a failure, which is why the tally is read above.
    replay = await client.post("/agents/enroll", json={"inviteCode": invite["code"], "name": "Sam"})
    assert replay.status == 404
    assert (await replay.json())["error"]["code"] == "enroll/used"
    assert limiter.failures_total == 6


async def test_after_five_failures_an_invalid_code_is_still_refused(client, store):
    """The other half: the same client, no valid code, still runs into a wall.

    The wall is the *code* bucket, not a ban on the caller: under the owner's
    ruling the client bucket records failures without vetoing admission, so what
    keeps the endpoint closed is that a code with five failures behind it is
    frozen. Everything below is a code that could not have been redeemed.
    """
    # An unknown code: five guesses at it are allowed, the sixth is refused.
    for _ in range(5):
        assert (await client.post("/agents/enroll",
                                  json={"inviteCode": "ZZZZ-ZZZZ-ZZZZ-ZZZZ"})).status == 404
    unknown = await client.post("/agents/enroll", json={"inviteCode": "ZZZZ-ZZZZ-ZZZZ-ZZZZ"})
    assert unknown.status == 429
    assert (await unknown.json())["error"]["code"] == "enroll/rate-limited"

    # The refusal is about that code, not about the caller: a code nobody has
    # guessed at yet is still answered normally rather than 429'd.
    fresh = await client.post("/agents/enroll", json={"inviteCode": "YYYY-YYYY-YYYY-YYYY"})
    assert fresh.status == 404
    assert (await fresh.json())["error"]["code"] == "enroll/unknown"

    assert store.list_accounts() == []


async def test_after_five_failures_a_missing_code_is_still_a_bad_request(client, store):
    """Malformed input never reaches the limiter: 400 stays 400."""
    for _ in range(5):
        assert (await client.post("/agents/enroll",
                                  json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})).status == 404

    response = await client.post("/agents/enroll", json={"name": "Sam"})
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "enroll/bad-request"



async def test_enroll_tolerates_separators_and_case(client, store):
    """Codes are read off a screen and retyped, so be forgiving about shape."""
    invite = store.mint_invite(code="ABCD-EFGH-JKMN-PQRS")
    response = await client.post("/agents/enroll",
                                 json={"inviteCode": " abcd efgh jkmn pqrs ", "name": "Sam"})
    assert response.status == 200, await response.text()


async def test_enroll_name_falls_back_to_a_default(client, store):
    invite = store.mint_invite()
    body = await (await client.post("/agents/enroll", json={"inviteCode": invite["code"]})).json()
    assert body["agentName"] == "My computer"


async def test_enrolled_agent_can_mint_pairing_codes(client, store):
    """The whole point: an enrolled computer can pair a phone like any other."""
    invite = store.mint_invite()
    enrolled = await (await client.post("/agents/enroll", json={
        "inviteCode": invite["code"], "name": "Sam's Mac"})).json()

    minted = await client.post("/pair/code", json={"ttlMs": 60_000},
                               headers={"Authorization": f"Bearer {enrolled['agentSecret']}"})
    assert minted.status == 200, await minted.text()
    claimed = await client.post("/pair/claim", json={
        "pairCode": (await minted.json())["code"], "deviceName": "Sam's iPhone"})
    assert claimed.status == 200
    assert (await claimed.json())["agentId"] == enrolled["agentId"]


# ── store level ────────────────────────────────────────────────────────────
#
# The route is a thin wrapper; the guarantees live in the store.


def test_only_the_hash_of_an_invite_is_stored(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        invite = store.mint_invite(code="ABCD-EFGH-JKMN-PQRS")
        rows = store.list_invites()
        assert len(rows) == 1
        assert "ABCD" not in rows[0]["codeHash"]
        assert rows[0]["codeHash"] not in invite["code"]
        # Nothing on the row is the plaintext code.
        assert invite["code"] not in " ".join(str(value) for value in rows[0].values())
    finally:
        store.close()


def test_claim_invite_reports_the_reason(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        with pytest.raises(InviteRejected) as unknown:
            store.claim_invite("NOPE-NOPE-NOPE-NOPE", "Sam")
        assert unknown.value.reason == "unknown"

        expired = store.mint_invite(ttl_ms=-1000)
        with pytest.raises(InviteRejected) as late:
            store.claim_invite(expired["code"], "Sam")
        assert late.value.reason == "expired"

        invite = store.mint_invite()
        store.claim_invite(invite["code"], "Sam")
        with pytest.raises(InviteRejected) as used:
            store.claim_invite(invite["code"], "Someone else")
        assert used.value.reason == "used"

        # A failed redemption leaves nothing behind.
        assert len(store.list_accounts()) == 1
        assert len(store.list_agents()) == 1
    finally:
        store.close()


def test_invite_status_reports_without_consuming(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        invite = store.mint_invite()
        assert store.invite_status(invite["code"])["state"] == "unused"
        store.claim_invite(invite["code"], "Sam")
        status = store.invite_status(invite["code"])
        assert status["state"] == "used"
        assert status["usedByAgentId"].startswith("agt_")
        assert store.invite_status("ZZZZ-ZZZZ-ZZZZ-ZZZZ") == {"exists": False}
    finally:
        store.close()


def test_minted_invites_use_the_unambiguous_alphabet(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        codes = [store.mint_invite()["code"] for _ in range(20)]
        assert len(set(codes)) == len(codes)
        for code in codes:
            assert len(code) == 19 and code.count("-") == 3
            assert not set(code) & set("01OIL")
        assert DEFAULT_INVITE_TTL_MS > 24 * 60 * 60 * 1000
    finally:
        store.close()


def test_schema_addition_is_additive(tmp_path):
    """An existing relay database must gain the table without a migration."""
    path = str(tmp_path / "state.db")
    store = Store(path)
    account = store.create_account("existing")
    store.register_agent(account["accountId"], "existing mac")
    store.close()

    reopened = Store(path)
    try:
        invite = reopened.mint_invite()
        assert reopened.claim_invite(invite["code"], "new machine")["agentId"].startswith("agt_")
        # The pre-existing rows survived.
        assert len(reopened.list_accounts()) == 2
    finally:
        reopened.close()
