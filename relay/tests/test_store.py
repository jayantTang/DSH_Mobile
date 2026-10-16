"""SQLite store tests: hashing, one-time codes, rotation, revocation."""

from __future__ import annotations

import json
import time

import pytest

from store import (Conflict, InviteRejected, NotFound, PairCodeClaimRejected, Store,
                   hash_pair_code, normalize_pair_code, now_ms)


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


def test_pair_code_is_reusable_and_normalized(store: Store):
    """032：认领**不再**是一次性的；大小写与空格仍然照旧归一。"""
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    messy = f" {minted['code'][:4].lower()} {minted['code'][5:].lower()} "
    claimed = store.claim_pair_code(messy, device_name="iPhone", model="iPhone17,1", app_version="1.0")
    assert claimed["ok"] is True
    assert claimed["agentId"] == agent["agentId"]
    assert claimed["deviceToken"].startswith("dt_")
    assert claimed["reused"] is False

    # 同一张码再认领：**成功**，且是另一台设备（持久码的用例：重装、换机、加浏览器）。
    again = store.claim_pair_code(minted["code"], device_name="iPhone")
    assert again["deviceId"] != claimed["deviceId"]

    row = store._conn.execute(  # noqa: SLF001
        "SELECT useCount, usedAt, deviceId FROM pairCodes LIMIT 1").fetchone()
    assert row["useCount"] == 2
    # `usedAt`/`deviceId` 仍记**第一次**认领，作为审计信息。
    assert row["deviceId"] == claimed["deviceId"]
    assert row["usedAt"] is not None


def test_pair_code_expiry(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"], ttl_ms=-1)
    with pytest.raises(PairCodeClaimRejected) as rejection:
        store.claim_pair_code(minted["code"], device_name="iPhone")
    assert rejection.value.reason == "expired"
    assert rejection.value.details["expiresAt"] > 0


def test_a_code_nobody_minted_is_unknown(store: Store):
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    with pytest.raises(PairCodeClaimRejected) as rejection:
        store.claim_pair_code("ZZZZ-ZZZZ", device_name="iPhone")
    assert rejection.value.reason == "unknown"
    # 没有命中任何一行，就没有行上的时间戳可说。
    assert rejection.value.details == {}


def test_classification_only_looks_back_a_bounded_window(store: Store):
    """窗口之外的码一律报 unknown——判定本身不能变成 CPU 放大器。

    逐行 scrypt 是有意昂贵的，所以"已用/过期"的判定按创建时间与条数双重设限：
    更早的码与其花 CPU 去认，不如老老实实说"无效"。
    """
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    minted = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    row = store._conn.execute("SELECT createdAt, codeHash FROM pairCodes").fetchone()
    aged = int(row["createdAt"]) - 3 * 60 * 60 * 1000
    store._conn.execute("UPDATE pairCodes SET createdAt=?, expiresAt=? WHERE codeHash=?",
                        (aged, aged, row["codeHash"]))
    store._conn.commit()
    with pytest.raises(PairCodeClaimRejected) as rejection:
        store.claim_pair_code(minted["code"], device_name="iPhone")
    assert rejection.value.reason == "unknown"


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


def test_purge_expired_also_drops_long_revoked_codes(store: Store):
    """032：作废码自己不会过期，得由清理收走；但窗口内的要留着解释"被重新生成"。"""
    account = store.create_account("a")
    agent = store.register_agent(account["accountId"], "mac")
    store.regenerate_pair_code(agent["agentId"])      # 码 A（活）
    older = store.mint_pair_code(agent["agentId"])    # 码 B（活）
    store.regenerate_pair_code(agent["agentId"])      # A、B 作废，铸出 C

    # 刚作废：留在窗口里，`pair/revoked-code` 才解释得出来。
    assert store.purge_expired() == 0

    # 把"现在"推到查找窗口之外：作废码该被删掉，别让"每点一次重新生成就多一行"永远攒着。
    later = now_ms() + 3 * 60 * 60 * 1000
    assert store.purge_expired(at=later) >= 1
    hashed = hash_pair_code(normalize_pair_code(older["code"]))
    remaining = store._conn.execute(  # noqa: SLF001
        "SELECT COUNT(*) FROM pairCodes WHERE codeHash=?", (hashed,)).fetchone()[0]
    assert remaining == 0


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
