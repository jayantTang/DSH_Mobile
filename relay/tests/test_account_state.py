"""032 阶段 2：账户级状态（accountState）与轻量推送。

覆盖：读写、`updatedAt` 单调（旧写不许盖新）、跨账户隔离、推送只给同账户且排除写入者、
未知帧不影响老客户端、信件服务用的环回通知端点、限制（条数/大小/格式）。
"""
import json

import pytest

import relay as relay_module
from conftest import agent_headers, device_headers
from hub import Limits
from store import Store, now_ms


@pytest.fixture
async def client(aiohttp_client, store: Store):
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8), pair_ttl_ms=60_000)
    return await aiohttp_client(app)


async def _pair(client, store, agent, name="iPhone", device_key=None):
    """走真实认领路径造一台设备，返回 (deviceId, token)。"""
    minted = store.mint_pair_code(agent["agentId"])
    payload = {"pairCode": minted["code"], "deviceName": name}
    if device_key:
        payload["deviceKey"] = device_key
    body = await (await client.post("/pair/claim", json=payload)).json()
    return body["deviceId"], body["deviceToken"]


async def _put(client, token, entries):
    return await client.put("/account/state", json={"entries": entries},
                            headers=device_headers(token))


async def _get(client, token, keys=None):
    url = "/account/state" + (f"?keys={keys}" if keys else "")
    return await client.get(url, headers=device_headers(token))


# ── 基本读写 ────────────────────────────────────────────────────────────────

async def test_state_round_trips(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    stamp = now_ms()
    written = await _put(client, token, [
        {"key": "alertPrefs", "value": {"turnEnd": False, "attention": True}, "updatedAt": stamp},
    ])
    assert written.status == 200
    assert (await written.json())["applied"] == ["alertPrefs"]

    read = await _get(client, token)
    entries = (await read.json())["entries"]
    assert entries["alertPrefs"]["value"] == {"turnEnd": False, "attention": True}
    assert entries["alertPrefs"]["updatedAt"] == stamp


async def test_reading_a_subset_of_keys(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    stamp = now_ms()
    await _put(client, token, [
        {"key": "alertPrefs", "value": {"turnEnd": True}, "updatedAt": stamp},
        {"key": "badgeWatermark", "value": {"at": stamp}, "updatedAt": stamp},
    ])
    body = await (await _get(client, token, keys="badgeWatermark")).json()
    assert list(body["entries"]) == ["badgeWatermark"]


async def test_state_needs_a_device_token(client, store, provisioned):
    assert (await client.get("/account/state")).status == 401
    assert (await client.put("/account/state", json={"entries": []})).status == 401


# ── 单调：旧写不许盖新 ──────────────────────────────────────────────────────

async def test_an_older_write_cannot_overwrite_a_newer_one(client, store, provisioned):
    """两台设备同时改一项：晚到的那台如果带着旧时间戳，不能把新值盖回去。"""
    _, token = await _pair(client, store, provisioned["agent"])
    newer = now_ms() + 10_000
    older = now_ms()
    first = await _put(client, token, [
        {"key": "sessionRead.s1", "value": {"abc": 10}, "updatedAt": newer}])
    assert (await first.json())["applied"] == ["sessionRead.s1"]

    stale = await _put(client, token, [
        {"key": "sessionRead.s1", "value": {"abc": 1}, "updatedAt": older}])
    body = await stale.json()
    assert body["applied"] == []
    assert body["entries"]["sessionRead.s1"]["value"] == {"abc": 10}

    read = await (await _get(client, token)).json()
    assert read["entries"]["sessionRead.s1"]["value"] == {"abc": 10}


async def test_an_equal_timestamp_is_idempotent(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    stamp = now_ms()
    entry = {"key": "alertPrefs", "value": {"turnEnd": True}, "updatedAt": stamp}
    assert (await (await _put(client, token, [entry])).json())["applied"] == ["alertPrefs"]
    # 同一次写的重试（同一个时间戳）不该被当成冲突，也不该重复通知。
    again = await (await _put(client, token, [entry])).json()
    assert again["applied"] == []
    assert again["entries"]["alertPrefs"]["value"] == {"turnEnd": True}


# ── 账户隔离 ────────────────────────────────────────────────────────────────

async def test_another_account_cannot_see_or_touch_the_state(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    stamp = now_ms()
    await _put(client, token, [{"key": "alertPrefs", "value": {"turnEnd": False}, "updatedAt": stamp}])

    other = store.create_account("someone else")
    other_agent = store.register_agent(other["accountId"], "other mac")
    _, other_token = await _pair(client, store, other_agent, name="Other iPhone")

    body = await (await _get(client, other_token)).json()
    assert body["entries"] == {}
    # 同一个 key 在另一个账户里是独立的一份，互不覆盖。
    written = await _put(client, other_token, [
        {"key": "alertPrefs", "value": {"turnEnd": True}, "updatedAt": stamp + 1}])
    assert (await written.json())["applied"] == ["alertPrefs"]
    mine = await (await _get(client, token)).json()
    assert mine["entries"]["alertPrefs"]["value"] == {"turnEnd": False}


# ── 限制 ────────────────────────────────────────────────────────────────────

async def test_bad_entries_are_refused(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    assert (await _put(client, token, [])).status == 400
    assert (await _put(client, token, [{"value": 1, "updatedAt": now_ms()}])).status == 400
    assert (await _put(client, token, [{"key": "k", "value": 1}])).status == 400
    assert (await _put(client, token, [{"key": "k", "value": 1, "updatedAt": "now"}])).status == 400
    too_many = [{"key": f"k{i}", "value": 1, "updatedAt": now_ms()} for i in range(100)]
    assert (await _put(client, token, too_many)).status == 400


async def test_a_huge_value_is_refused(client, store, provisioned):
    _, token = await _pair(client, store, provisioned["agent"])
    huge = {"payload": "x" * (9 * 1024)}
    response = await _put(client, token, [{"key": "k", "value": huge, "updatedAt": now_ms()}])
    assert response.status == 413


# ── 扇出 ────────────────────────────────────────────────────────────────────

async def test_a_write_notifies_the_other_devices_of_the_account(client, store, provisioned):
    """写入方自己不发；同账户另一台在线设备收到一帧 `accountState`。"""
    hub = client.server.app["hub"]
    _, first_token = await _pair(client, store, provisioned["agent"], name="one")
    _, second_token = await _pair(client, store, provisioned["agent"], name="two")

    sent: list[tuple[str, str]] = []

    class FakeLink:
        def __init__(self, device_id, account_id):
            self.device_id = device_id
            self.account_id = account_id
            self.closed = False

        def enqueue_text(self, text):
            sent.append((self.device_id, text))
            return True

    devices = store._conn.execute(  # noqa: SLF001
        "SELECT deviceId, accountId FROM devices WHERE revokedAt IS NULL").fetchall()
    account_id = devices[0]["accountId"]
    writer_id = devices[0]["deviceId"]
    hub._devices = {row["deviceId"]: FakeLink(row["deviceId"], row["accountId"])  # noqa: SLF001
                    for row in devices}
    try:
        # 用第一台的 token 写；它自己不该收到通知，第二台该收到。
        response = await _put(client, first_token, [
            {"key": "badgeWatermark", "value": {"at": 1}, "updatedAt": now_ms()}])
        assert response.status == 200
    finally:
        hub._devices = {}  # noqa: SLF001

    assert len(sent) == 1
    receiver, frame = sent[0]
    assert receiver != writer_id
    assert frame == json.dumps({"t": "accountState", "keys": ["badgeWatermark"]},
                               ensure_ascii=False)
    assert account_id == devices[1]["accountId"]


async def test_another_account_is_not_notified(client, store, provisioned):
    hub = client.server.app["hub"]
    _, token = await _pair(client, store, provisioned["agent"])
    other = store.create_account("someone else")
    other_agent = store.register_agent(other["accountId"], "other mac")
    _, other_token = await _pair(client, store, other_agent, name="Other iPhone")

    sent: list[str] = []

    class FakeLink:
        def __init__(self, device_id, account_id):
            self.device_id = device_id
            self.account_id = account_id
            self.closed = False

        def enqueue_text(self, text):
            sent.append(self.device_id)
            return True

    rows = store._conn.execute(  # noqa: SLF001
        "SELECT deviceId, accountId FROM devices WHERE revokedAt IS NULL").fetchall()
    hub._devices = {row["deviceId"]: FakeLink(row["deviceId"], row["accountId"])  # noqa: SLF001
                    for row in rows}
    mine = [row for row in rows if row["accountId"] == provisioned["account"]["accountId"]]
    theirs = [row for row in rows if row["accountId"] != provisioned["account"]["accountId"]]
    try:
        await _put(client, token, [{"key": "k", "value": 1, "updatedAt": now_ms()}])
    finally:
        hub._devices = {}  # noqa: SLF001

    assert sent == [], "the same account has only the writer, so nobody is notified"
    assert [row["deviceId"] for row in theirs] == [r["deviceId"] for r in theirs]
    assert mine and theirs


# ── 信件服务的环回通知 ──────────────────────────────────────────────────────

async def test_the_mail_touch_endpoint_notifies_the_account(client, store, provisioned):
    hub = client.server.app["hub"]
    sent: list[str] = []

    class FakeLink:
        def __init__(self, device_id, account_id):
            self.device_id = device_id
            self.account_id = account_id
            self.closed = False

        def enqueue_text(self, text):
            sent.append(text)
            return True

    account_id = provisioned["account"]["accountId"]
    hub._devices = {"dev_other": FakeLink("dev_other", account_id)}  # noqa: SLF001
    try:
        response = await client.post("/internal/account-state/touch",
                                     json={"accountId": account_id, "keys": ["feedback"]})
        assert response.status == 200
        assert (await response.json())["notified"] == 1
    finally:
        hub._devices = {}  # noqa: SLF001
    assert json.loads(sent[0]) == {"t": "accountState", "keys": ["feedback"]}


async def test_the_mail_touch_endpoint_rejects_a_bad_body(client):
    # aiohttp 的测试客户端来源是环回，所以这里能走到 body 校验那一步。
    assert (await client.post("/internal/account-state/touch", json={})).status == 400


# ── store 层：解析坏值不炸 ──────────────────────────────────────────────────

def test_a_corrupt_stored_value_reads_as_a_string(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    try:
        account = store.create_account("t")
        store.put_account_state(account["accountId"], "k", {"a": 1}, updated_at=now_ms())
        store._conn.execute("UPDATE accountState SET value=? WHERE key='k'", ("{not json",))  # noqa: SLF001
        store._conn.commit()  # noqa: SLF001
        entries = store.account_state(account["accountId"])
        assert entries["k"]["value"] == "{not json"
    finally:
        store.close()


async def test_agent_auth_cannot_reach_account_state(client, provisioned):
    # 账户状态只认设备 token：agent secret 是电脑侧凭据，不该能读手机的状态。
    response = await client.get("/account/state", headers=agent_headers(provisioned["agent"]))
    assert response.status == 401
