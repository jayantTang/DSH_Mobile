"""032 阶段 1：持久配对码、账户级 8 台上限、deviceKey 复用。

断言消息用英文（与 relay 其它用例一致）；注释写"为什么"。
"""
import sqlite3

import pytest

import relay as relay_module
from conftest import agent_headers, device_headers
from hub import Limits
from store import DEFAULT_MAX_PAIRED_DEVICES, SCHEMA_VERSION, Store, now_ms


@pytest.fixture
async def capped_client(aiohttp_client, store: Store):
    """同一套 fixture，但把账户级上限压到 2，免得用例里配 8 台。"""
    app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                  pair_ttl_ms=60_000, max_paired_devices=2)
    return await aiohttp_client(app)


async def _claim(client, code: str, **fields):
    payload = {"pairCode": code, "deviceName": fields.pop("deviceName", "iPhone"), **fields}
    return await client.post("/pair/claim", json=payload)


# ── 持久码本身 ──────────────────────────────────────────────────────────────

async def test_the_mint_response_carries_the_paired_device_budget(client, provisioned, store):
    # 连接器面板要显示「已配对 N/8」，两个数都必须来自中转（它才知道库里的实数）。
    response = await client.post("/pair/code", json={},
                                 headers=agent_headers(provisioned["agent"]))
    body = await response.json()
    from store import DEFAULT_MAX_PAIRED_DEVICES
    assert body["maxPairedDevices"] == DEFAULT_MAX_PAIRED_DEVICES
    assert body["pairedDevices"] == 0

    await _claim(client, body["code"])
    again = await (await client.post("/pair/code/regenerate", json={},
                                     headers=agent_headers(provisioned["agent"]))).json()
    assert again["pairedDevices"] == 1


async def test_a_code_without_ttl_is_persistent(client, provisioned, store):
    # 不带 ttlMs 的请求 = 持久码（032 的默认）：没有 expiresAt。
    response = await client.post("/pair/code", json={},
                                 headers=agent_headers(provisioned["agent"]))
    body = await response.json()
    assert body["persistent"] is True
    assert body["expiresAt"] is None

    claimed = await _claim(client, body["code"])
    assert claimed.status == 200

    # 再认领一次仍然成功（持久码不是一次性的）。
    assert (await _claim(client, body["code"])).status == 200


async def test_an_explicit_null_ttl_is_persistent_too(client, provisioned, store):
    # 032 之后的连接器在持久码这条路上发的是显式 `ttlMs: null`
    # （plugins/mobile-link/lib/pairing.js）。只认"键不存在"会让它落回默认 10 分钟，
    # 面板于是显示出倒计时——owner 2026-10-17 报的就是这个。
    response = await client.post("/pair/code", json={"ttlMs": None},
                                 headers=agent_headers(provisioned["agent"]))
    body = await response.json()
    assert body["persistent"] is True
    assert body["expiresAt"] is None
    # 仍然是可反复认领的持久码，不是一次性的。
    assert (await _claim(client, body["code"])).status == 200
    assert (await _claim(client, body["code"])).status == 200


async def test_a_code_with_ttl_keeps_the_old_one_shot_behaviour(client, provisioned):
    # 老连接器每次都带 ttlMs：这条路必须与今天完全一致（FR-005/FR-012）。
    response = await client.post("/pair/code", json={"ttlMs": 60_000},
                                 headers=agent_headers(provisioned["agent"]))
    body = await response.json()
    assert body["persistent"] is False
    assert body["expiresAt"] > now_ms()


async def test_ttl_is_still_capped_at_an_hour(client, provisioned):
    response = await client.post("/pair/code", json={"ttlMs": 30 * 24 * 3600 * 1000},
                                 headers=agent_headers(provisioned["agent"]))
    body = await response.json()
    assert body["ttlMs"] <= 60 * 60 * 1000


# ── 账户级上限 ──────────────────────────────────────────────────────────────

async def test_the_account_cap_refuses_the_next_device_without_minting_a_token(capped_client,
                                                                               provisioned, store):
    code = provisioned["code"]["code"]
    assert (await _claim(capped_client, code, deviceName="one")).status == 200
    assert (await _claim(capped_client, code, deviceName="two")).status == 200

    third = await _claim(capped_client, code, deviceName="three")
    assert third.status == 409
    body = await third.json()
    assert body["error"]["code"] == "limit/devices"
    assert body["error"]["details"]["maxPairedDevices"] == 2
    assert body["error"]["details"]["pairedDevices"] == 2
    # 被拒绝的一次不许留下设备（否则重试就会自己把自己挤满）。
    live = store._conn.execute(  # noqa: SLF001
        "SELECT COUNT(*) FROM devices WHERE revokedAt IS NULL").fetchone()[0]
    assert live == 2


async def test_revoking_a_device_frees_the_slot(capped_client, provisioned, store):
    code = provisioned["code"]["code"]
    first = await (await _claim(capped_client, code, deviceName="one")).json()
    assert (await _claim(capped_client, code, deviceName="two")).status == 200
    assert (await _claim(capped_client, code, deviceName="three")).status == 409

    revoked = await capped_client.post("/devices/revoke", json={"deviceId": first["deviceId"]},
                                       headers=device_headers(first["deviceToken"]))
    assert revoked.status == 200

    assert (await _claim(capped_client, code, deviceName="three")).status == 200


# ── deviceKey：重装复用同一台 ────────────────────────────────────────────────

async def test_the_same_device_key_reuses_the_same_device(capped_client, provisioned, store):
    code = provisioned["code"]["code"]
    first = await (await _claim(capped_client, code, deviceName="iPhone",
                                deviceKey="key-aaaaaaaa")).json()
    second = await (await _claim(capped_client, code, deviceName="iPhone",
                                 deviceKey="key-aaaaaaaa")).json()

    assert second["deviceId"] == first["deviceId"], "reinstall must reuse the same device"
    assert second["reused"] is True
    assert second["deviceToken"] != first["deviceToken"], "the token is rotated"
    live = store._conn.execute(  # noqa: SLF001
        "SELECT COUNT(*) FROM devices WHERE revokedAt IS NULL").fetchone()[0]
    assert live == 1, "a reused device must not consume a second slot"

    # 旧 token 被换掉了：旧的那枚不再认证（换钥匙不换身份）。
    listed = await capped_client.get("/devices", headers=device_headers(second["deviceToken"]))
    assert listed.status == 200
    stale = await capped_client.get("/devices", headers=device_headers(first["deviceToken"]))
    assert stale.status == 401


async def test_a_reused_device_does_not_trip_the_cap(capped_client, provisioned):
    code = provisioned["code"]["code"]
    await _claim(capped_client, code, deviceName="one", deviceKey="key-11111111")
    await _claim(capped_client, code, deviceName="two", deviceKey="key-22222222")
    # 上限是 2，第三台**新**设备该被拒；但已在这两台里的一台重装不受影响。
    assert (await _claim(capped_client, code, deviceName="three",
                         deviceKey="key-33333333")).status == 409
    assert (await _claim(capped_client, code, deviceName="one",
                         deviceKey="key-11111111")).status == 200


async def test_a_revoked_device_key_is_treated_as_a_new_device(capped_client, provisioned):
    code = provisioned["code"]["code"]
    first = await (await _claim(capped_client, code, deviceName="iPhone",
                                deviceKey="key-aaaaaaaa")).json()
    await capped_client.post("/devices/revoke", json={"deviceId": first["deviceId"]},
                             headers=device_headers(first["deviceToken"]))
    again = await (await _claim(capped_client, code, deviceName="iPhone",
                                deviceKey="key-aaaaaaaa")).json()
    assert again["deviceId"] != first["deviceId"], "a revoked device is not reused"
    assert again["reused"] is False


async def test_a_malformed_device_key_falls_back_to_a_new_device(client, provisioned):
    # 坏字段不该让整次认领失败：按"没带 key"处理。
    response = await _claim(client, provisioned["code"]["code"], deviceKey="x")
    assert response.status == 200
    assert (await response.json())["reused"] is False


# ── 重新生成：只作废码，不碰设备 ────────────────────────────────────────────

async def test_regenerating_keeps_the_already_paired_devices(client, provisioned, store):
    code = provisioned["code"]["code"]
    device = await (await _claim(client, code, deviceName="iPhone")).json()

    regenerated = await client.post("/pair/code/regenerate", json={},
                                    headers=agent_headers(provisioned["agent"]))
    body = await regenerated.json()
    assert body["revoked"] >= 1

    # 设备一条没少：它靠自己的 token 活着，换码不该把它踢下线。
    listed = await client.get("/devices", headers=device_headers(device["deviceToken"]))
    assert listed.status == 200
    ids = [item["deviceId"] for item in (await listed.json())["devices"]]
    assert device["deviceId"] in ids
    live = store._conn.execute(  # noqa: SLF001
        "SELECT COUNT(*) FROM devices WHERE revokedAt IS NULL").fetchone()[0]
    assert live == 1


async def test_regenerating_twice_leaves_only_the_newest_code_live(client, provisioned, store):
    first = await (await client.post("/pair/code", json={},
                                     headers=agent_headers(provisioned["agent"]))).json()
    second = await (await client.post("/pair/code/regenerate", json={},
                                      headers=agent_headers(provisioned["agent"]))).json()
    third = await (await client.post("/pair/code/regenerate", json={},
                                     headers=agent_headers(provisioned["agent"]))).json()

    for dead in (first["code"], second["code"]):
        response = await _claim(client, dead)
        assert response.status == 404
        assert (await response.json())["error"]["code"] == "pair/revoked-code"
    assert (await _claim(client, third["code"])).status == 200


async def test_regenerating_requires_agent_auth(client):
    assert (await client.post("/pair/code/regenerate", json={})).status == 401


# ── 迁移 ────────────────────────────────────────────────────────────────────

def test_migration_adds_the_new_columns_to_an_old_database(tmp_path):
    """按 SCHEMA_VERSION=5 的老库打开后，新列与新表都要在。

    这是生产库会走的路径：老库 + 新代码 = 启动时迁移，而不是等第一次写入报
    `no such column`。
    """
    path = tmp_path / "old.db"
    legacy = Store(str(path))
    legacy.close()

    # 手工把库降级成 v5 的样子：删掉本次新增的列与表。
    #
    # **必须写完整的建表语句**，不能用 `CREATE TABLE … AS SELECT`：后者会把
    # `expiresAt` 的 NOT NULL 一起丢掉，于是"持久码要写 NULL"这条约束在测试里消失——
    # 2026-10-16 生产上就是这么挂的（v6 只加了列，没改约束）。照抄当时线上那份 DDL。
    conn = sqlite3.connect(path)
    conn.executescript("""
        PRAGMA foreign_keys=OFF;
        DROP TABLE pairCodes;
        CREATE TABLE pairCodes (
          codeHash  TEXT PRIMARY KEY,
          agentId   TEXT NOT NULL,
          accountId TEXT NOT NULL,
          createdAt INTEGER NOT NULL,
          expiresAt INTEGER NOT NULL,
          usedAt    INTEGER,
          deviceId  TEXT
        );
        CREATE INDEX pair_codes_agent ON pairCodes(agentId);
        DROP TABLE devices;
        CREATE TABLE devices (
          deviceId        TEXT PRIMARY KEY,
          deviceTokenHash TEXT NOT NULL UNIQUE,
          agentId         TEXT NOT NULL,
          accountId       TEXT NOT NULL,
          name            TEXT NOT NULL,
          model           TEXT,
          appVersion      TEXT,
          createdAt       INTEGER NOT NULL,
          expiresAt       INTEGER NOT NULL,
          lastSeenAt      INTEGER,
          revokedAt       INTEGER,
          apnsToken       TEXT,
          apnsEnv         TEXT,
          pushTurnEnd     INTEGER NOT NULL DEFAULT 1,
          pushAttention   INTEGER NOT NULL DEFAULT 1,
          pushUpdatedAt   INTEGER
        );
        CREATE INDEX devices_agent ON devices(agentId);
        PRAGMA user_version=5;
    """)
    conn.commit()
    conn.close()

    upgraded = Store(str(path))
    try:
        version = upgraded._conn.execute("PRAGMA user_version").fetchone()[0]  # noqa: SLF001
        assert version == SCHEMA_VERSION
        pair_columns = {row[1] for row in
                        upgraded._conn.execute("PRAGMA table_info(pairCodes)")}  # noqa: SLF001
        assert {"revokedAt", "lastUsedAt", "useCount"} <= pair_columns
        device_columns = {row[1] for row in
                          upgraded._conn.execute("PRAGMA table_info(devices)")}  # noqa: SLF001
        assert "deviceKey" in device_columns
        # 关键：`expiresAt` 必须真的可空——生产上就是这里挂了（v6 只加列没改约束）。
        notnull = {row[1]: bool(row[3]) for row in
                   upgraded._conn.execute("PRAGMA table_info(pairCodes)")}  # noqa: SLF001
        assert notnull["expiresAt"] is False, "persistent codes need a nullable expiresAt"
        upgraded._conn.execute(  # noqa: SLF001
            "INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt)"
            " VALUES('h', 'a', 'acc', 1, NULL)")
        upgraded._conn.commit()  # noqa: SLF001
    finally:
        upgraded.close()


def test_a_migrated_database_can_mint_and_claim(tmp_path):
    """迁移之后再走一遍真路径：铸持久码 → 认领成功（老行没有新列也不影响）。"""
    store = Store(str(tmp_path / "state.db"))
    try:
        account = store.create_account("t")
        agent = store.register_agent(account["accountId"], "mac")
        minted = store.mint_pair_code(agent["agentId"])
        assert minted["persistent"] is True
        claimed = store.claim_pair_code(minted["code"], device_name="iPhone",
                                       device_key="key-abcdefgh")
        assert claimed["reused"] is False
        again = store.claim_pair_code(minted["code"], device_name="iPhone",
                                      device_key="key-abcdefgh")
        assert again["deviceId"] == claimed["deviceId"]
    finally:
        store.close()


def test_the_default_cap_is_eight():
    # owner 2026-10-16 定的数：写死在这里，改它要连着文档与 App 文案一起改。
    assert DEFAULT_MAX_PAIRED_DEVICES == 8
