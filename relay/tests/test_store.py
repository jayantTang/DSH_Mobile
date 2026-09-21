"""SQLite store tests: hashing, one-time codes, rotation, revocation."""

from __future__ import annotations

import json
import time

import pytest

from store import Conflict, InviteRejected, NotFound, Store, normalize_pair_code


def test_pair_codes_are_stored_hashed(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"])
    raw = store._conn.execute("SELECT codeHash FROM pairCodes").fetchone()["codeHash"]
    assert raw.startswith("scrypt$")
    assert normalize_pair_code(minted["code"]) not in raw


def test_agent_secret_is_stored_hashed_and_looked_up(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    row = store._conn.execute("SELECT secretHash FROM agents").fetchone()["secretHash"]
    assert agent["agentSecret"] not in row
    assert store.agent_by_secret(agent["agentSecret"])["agentId"] == agent["agentId"]
    assert store.agent_by_secret("as_wrong") is None


def test_pair_code_is_single_use_and_normalized(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    messy = f" {minted['code'][:4].lower()} {minted['code'][5:].lower()} "
    claimed = store.claim_pair_code(messy, device_name="iPhone", model="iPhone17,1", app_version="1.0")
    assert claimed["ok"] is True
    assert claimed["agentId"] == agent["agentId"]
    assert claimed["deviceToken"].startswith("dt_")
    with pytest.raises(NotFound):
        store.claim_pair_code(minted["code"], device_name="iPhone")


def test_pair_code_expiry(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"], ttl_ms=-1)
    with pytest.raises(NotFound):
        store.claim_pair_code(minted["code"], device_name="iPhone")


def test_disabled_agent_cannot_be_paired(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    store.set_agent_disabled(agent["agentId"], True)
    with pytest.raises(Conflict):
        store.mint_pair_code(agent["agentId"])
    assert store.agent_by_secret(agent["agentSecret"]) is None


def test_device_token_lifecycle(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    claimed = store.claim_pair_code(code["code"], device_name="iPhone")
    token = claimed["deviceToken"]
    assert store.device_by_token(token)["deviceId"] == claimed["deviceId"]

    refreshed = store.refresh_device(token, ttl_ms=10_000)
    assert refreshed["deviceToken"] != token
    assert store.device_by_token(token) is None
    assert store.device_by_token(refreshed["deviceToken"]) is not None

    store.revoke_device(claimed["deviceId"])
    assert store.device_by_token(refreshed["deviceToken"]) is None
    assert store.list_devices(agent["agentId"]) == []
    assert len(store.list_devices(agent["agentId"], include_revoked=True)) == 1


def test_expired_device_token_is_rejected(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    claimed = store.claim_pair_code(code["code"], device_name="iPhone", ttl_ms=-1)
    assert store.device_by_token(claimed["deviceToken"]) is None


def test_register_agent_rotates_in_place(store: Store):
    account = store.create_account("a")
    first = store.register_agent(account["accountId"], "mac")
    second = store.register_agent(account["accountId"], "mac renamed", agent_id=first["agentId"])
    assert second["agentId"] == first["agentId"]
    assert store.agent_by_secret(first["agentSecret"]) is None
    assert store.agent_by_secret(second["agentSecret"])["name"] == "mac renamed"


def test_unknown_account_and_agent_raise(store: Store):
    with pytest.raises(NotFound):
        store.register_agent("acc_nope", "mac")
    with pytest.raises(NotFound):
        store.mint_pair_code("agt_nope")
    with pytest.raises(NotFound):
        store.revoke_device("dev_nope")


def test_purge_expired_removes_only_stale_codes(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    store.mint_pair_code(agent["agentId"], ttl_ms=-1)
    live = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    assert store.purge_expired() == 1
    assert store.claim_pair_code(live["code"], device_name="iPhone")["ok"] is True

def test_a_leaked_invite_can_be_revoked_before_it_is_used():
    """The one path that neutralises a code that got out in public.

    A leaked invite (review notes, a screenshot, a chat) used to be stuck until
    its TTL ran out; revoking expires it now, and the state it leaves behind is
    indistinguishable from an expired code — which is what an invitee should
    see.
    """
    store = Store(":memory:")
    minted = store.mint_invite(note="审核用", code="AAAA-BBBB-CCCC-DDDD")

    assert store.invite_status("AAAA-BBBB-CCCC-DDDD")["state"] == "unused"

    result = store.revoke_invite("AAAA-BBBB-CCCC-DDDD")

    assert result["revoked"] is True
    assert result["note"] == "审核用"
    assert "AAAA-BBBB-CCCC-DDDD" not in json.dumps(result), "只在库里存哈希，回执里也不能有明文"
    assert store.invite_status("AAAA-BBBB-CCCC-DDDD")["state"] == "expired"
    # And redeeming it now fails the way an expired code does.
    with pytest.raises(InviteRejected) as rejected:
        store.claim_invite("AAAA-BBBB-CCCC-DDDD", "有人")
    assert rejected.value.reason == "expired"
    store.close()


def test_revoking_reports_why_it_could_not():
    store = Store(":memory:")
    assert store.revoke_invite("NOPE-NOPE-NOPE-NOPE") == {"revoked": False, "reason": "unknown"}
    # Normalising strips separators and case, so only an input with no
    # alphanumerics at all is malformed; anything else is simply unknown.
    assert store.revoke_invite("!!!")["reason"] == "malformed"
    assert store.revoke_invite("not-a-real-code")["reason"] == "unknown"

    store.mint_invite(note="兑换过的", code="EEEE-FFFF-GGGG-HHHH")
    store.claim_invite("EEEE-FFFF-GGGG-HHHH", "有人")
    used = store.revoke_invite("EEEE-FFFF-GGGG-HHHH")
    assert used["revoked"] is False and used["reason"] == "used"

    store.mint_invite(note="短的", ttl_ms=1, code="IIII-JJJJ-KKKK-LLLL")
    time.sleep(0.01)
    assert store.revoke_invite("IIII-JJJJ-KKKK-LLLL")["reason"] == "already-expired"
    store.close()


def test_enrollments_join_invites_with_accounts_and_totals(store: Store):
    """`enrollments` 要一次说清：码铸了多少/用掉几张，以及用码的人是谁。"""
    code = store.mint_invite(note="公开试用 批次1")
    assert store.invite_totals() == {"minted": 1, "used": 0, "remaining": 1}

    claimed = store.claim_invite(code["code"], "My computer")
    agent = {"agentId": claimed["agentId"]}

    assert store.invite_totals() == {"minted": 1, "used": 1, "remaining": 0}
    (row,) = store.list_enrollments()
    assert row["agentId"] == agent["agentId"]
    assert row["accountName"] == "My computer"
    assert row["inviteNote"] == "公开试用 批次1"
    assert row["devices"] == 0 and row["usedAt"] > 0
