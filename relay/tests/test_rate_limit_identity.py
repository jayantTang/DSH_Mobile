"""Who a rate-limit bucket is keyed on — the relay's one trust boundary.

Every caller of the relay arrives from the front end, i.e. from loopback, so
keying the limiter on the socket peer alone would put the entire internet in one
bucket: one attacker would exhaust everybody's budget, and a second attacker
would be invisible. ``X-Forwarded-For`` fixes that, but the header is also
attacker-controlled, so believing it from the wrong peer is worse than not
believing it at all.

The tests below pin both directions, which is the point of the item:

* loopback peer + header  → bucketed by the **leftmost** entry (the original
  client; a single-hop front end appends the real peer after it);
* non-loopback peer + header → header **ignored**, bucketed by the socket peer.
  This is the forged-header case, and the one that must never regress.

The end-to-end half also pins *when* a bucket may refuse: a bucket stops the next
bad guess, never a valid invite code (owner's ruling, 2026-09-25).
"""

from __future__ import annotations

import pytest

import api
from api import ClaimLimiter, client_identifier
from relay import create_app
from hub import Limits
from test_stats_exposure import _make_request


async def identifier(remote, headers=None):
    """``client_identifier`` for a request built with a chosen peer and headers.

    Async because building an aiohttp ``Request`` needs a running loop.
    """
    app = create_app(store=_NoopStore(), limits=Limits(queue_depth=8))
    request = _make_request(app, peer=remote, url="/pair/claim", headers=headers or {})
    return client_identifier(request)


class _NoopStore:
    def usage_rows(self, _day):
        return []

    def add_usage(self, _entries):
        return 0


# ── the rule itself ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("remote,forwarded,expected", [
    # Behind the front end: the header is the only thing that distinguishes callers.
    ("127.0.0.1", "203.0.113.7", "203.0.113.7"),
    # A single-hop front end appends, so the leftmost entry is the client.
    ("127.0.0.1", "203.0.113.7, 127.0.0.1", "203.0.113.7"),
    ("127.0.0.1", "  203.0.113.7 , 10.0.0.1", "203.0.113.7"),
    ("::1", "203.0.113.7", "203.0.113.7"),
    # No header: fall back to the peer, which is still the front end (one bucket).
    ("127.0.0.1", None, "127.0.0.1"),
    ("127.0.0.1", "", "127.0.0.1"),
    ("127.0.0.1", "   ", "127.0.0.1"),
    # A direct caller: the header is a lie and must be ignored outright.
    ("203.0.113.7", "10.0.0.1", "203.0.113.7"),
    ("203.0.113.7", "127.0.0.1", "203.0.113.7"),
    ("203.0.113.7", "1.2.3.4, 5.6.7.8", "203.0.113.7"),
    ("203.0.113.7", None, "203.0.113.7"),
    # An unidentifiable peer still gets its own bucket rather than a crash.
    (None, "203.0.113.7", "unknown"),
])
async def test_client_identifier(remote, forwarded, expected):
    headers = {"X-Forwarded-For": forwarded} if forwarded is not None else {}
    assert await identifier(remote, headers) == expected


async def test_a_forged_header_cannot_move_a_public_caller_into_someone_elses_bucket():
    """The security half: a direct caller naming a loopback peer buys nothing."""
    honest = await identifier("198.51.100.9")
    forged = await identifier("198.51.100.9", {"X-Forwarded-For": "127.0.0.1"})
    someone_else = await identifier("2001:db8::1")
    assert forged == honest != someone_else


async def test_two_callers_behind_the_front_end_get_different_buckets():
    """Without this, one attacker drains the budget for every other caller."""
    one = await identifier("127.0.0.1", {"X-Forwarded-For": "203.0.113.7"})
    two = await identifier("127.0.0.1", {"X-Forwarded-For": "203.0.113.8"})
    assert one != two


# ── end to end: the limiter actually buckets that way ───────────────────────

async def test_pair_claim_buckets_by_the_forwarded_client(client):
    """Six failures from one forwarded address must not spend another's budget.

    ``/pair/claim`` allows 10 failures per bucket, so six leaves the second
    caller a working budget while the first keeps its own count.
    """
    first = {"X-Forwarded-For": "203.0.113.7"}
    second = {"X-Forwarded-For": "203.0.113.8"}
    for _ in range(6):
        assert (await client.post("/pair/claim", json={"pairCode": "ZZZZ-ZZZZ"},
                                  headers=first)).status == 404
    # The other client is untouched by those six.
    assert (await client.post("/pair/claim", json={"pairCode": "ZZZZ-ZZZZ"},
                              headers=second)).status == 404
    # And the first still has budget left (6 < 10), proving they are two buckets.
    assert (await client.post("/pair/claim", json={"pairCode": "ZZZZ-ZZZZ"},
                              headers=first)).status == 404


async def test_enroll_rate_limit_has_a_client_dimension(client, store):
    """Failures are counted per client, not only per code.

    The per-code budget (5) cannot bound the walk on its own: invite codes are
    handed out publicly, so an attacker who spends one failed guess per code
    never fills any single code's bucket. The client bucket is what accumulates
    across codes — under the owner's ruling of 2026-09-25 it records rather than
    vetoes, so what is asserted here is the accumulation, and
    ``test_enroll_api`` asserts that a valid code still gets in through it.
    """
    for index in range(5):
        response = await client.post("/agents/enroll",
                                     json={"inviteCode": f"EEEE-FFFF-GGGG-HHH{index}"})
        assert response.status == 404, await response.text()
    limiter = client.app["enroll_limiter"]
    assert limiter.blocked("127.0.0.1") is True, "跨邀请码同 IP 的失败必须累计"
    assert limiter.failures_total == 5
    # Nothing was created along the way — guessing never admits anyone.
    assert store.list_accounts() == []


async def test_a_valid_enroll_from_a_walled_client_is_admitted(client, store):
    """A valid invite is sufficient: five failures do not veto the operator's call.

    Owner's ruling, 2026-09-25 — the same rule as
    ``test_enroll_api.test_a_valid_code_is_admitted_after_five_failures_from_the_same_client``,
    reached from this file so the accumulation and the exemption are pinned
    together.
    """
    for _ in range(5):
        await client.post("/agents/enroll", json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})
    assert client.app["enroll_limiter"].blocked("127.0.0.1") is True
    invite = store.mint_invite()
    ok = await client.post("/agents/enroll", json={"inviteCode": invite["code"], "name": "Sam"})
    assert ok.status == 200, await ok.text()
    assert store.agent_by_secret((await ok.json())["agentSecret"]) is not None


async def test_a_valid_enroll_from_another_client_is_not_caught_by_that_wall(client, store):
    """The limit is per client, so a different caller is unaffected."""
    for _ in range(5):
        await client.post("/agents/enroll", json={"inviteCode": "AAAA-BBBB-CCCC-DDDD"})
    invite = store.mint_invite()
    ok = await client.post("/agents/enroll", json={"inviteCode": invite["code"], "name": "Sam"},
                           headers={"X-Forwarded-For": "203.0.113.8"})
    assert ok.status == 200, await ok.text()


async def test_limiter_window_expires():
    """A bucket is a window, not a permanent ban."""
    limiter = ClaimLimiter(limit=2, window_s=60)
    limiter.record_failure("k")
    limiter.record_failure("k")
    assert limiter.blocked("k") is True
    limiter.reset("k")
    assert limiter.blocked("k") is False


async def test_limiter_counts_failures_across_buckets():
    """The tally outlives the buckets it was counted in.

    With the client bucket no longer able to veto a valid code, this counter is
    what still shows an operator how much guessing a source is doing; ``reset``
    clears a bucket without erasing the history.
    """
    limiter = ClaimLimiter(limit=5, window_s=60)
    limiter.record_failure("a")
    limiter.record_failure("b")
    limiter.record_failure("a")
    assert limiter.failures_total == 3
    limiter.reset("a")
    assert limiter.failures_total == 3
    assert limiter.blocked("a") is False
