"""SQLite store tests: hashing, one-time codes, rotation, revocation."""

from __future__ import annotations

import pytest

from store import Conflict, NotFound, Store, normalize_pair_code


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
