"""可靠性场景（L3 局部，纳入默认黑盒套件）。

覆盖三项可以在本机稳定构造的故障：

1. **kill -9 后重启同一临时库**：账户、设备、账户状态都还在，``/healthz`` 200，
   并确认库仍是 WAL 模式、``-wal`` 文件在崩溃后保留（最新提交靠它恢复）。
2. **连接风暴**：50 台设备同时连接，每台都收到 ``hostStatus``、都能 ping/pong，
   电脑侧收到 50 条 ``deviceAttach``，全程没有错误帧。
3. **数据库写锁**：另开一个 sqlite3 连接 ``BEGIN IMMEDIATE`` 持锁 2 秒，期间发一次
   账户状态写，只记录耗时与最终结果（不硬断言）；锁释放后新写入必须成功——
   这一条才是“中转没有永久损坏”的硬断言。

慢客户端/背压没有稳定构造方法（需要卡在内核发送缓冲或让读取方停住，时序不可控），
按设计文档的“不硬造”原则留给后续批次，见本目录 README 的未覆盖表。

只通过 HTTP/WS、子进程与数据库文件观察，不 import 中转内部模块。所有临时库在
``tmp_path`` 下、端口随机，不碰真实部署与真实设备。
"""

from __future__ import annotations

import asyncio
import pathlib
import signal
import sqlite3
import time

import aiohttp

from . import support
from .conftest import RelayProcess

#: 连接风暴的设备数。每台设备各带一台电脑（生产限额 ``max-paired-devices`` 是 8/账户，
#: 这样不必为了用例改被测进程的启动参数）。
STORM_DEVICES = 50


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ── kill -9 后重启同一临时库 ────────────────────────────────────────────────


async def test_kill_9_and_restart_keeps_the_account_device_and_account_state(
        tmp_path: pathlib.Path) -> None:
    """崩溃后从同一个库重启：数据不丢，库仍是 WAL，``-wal`` 文件留到了重启前。"""
    first = RelayProcess(tmp_path / "crash", label="kill9")
    first.start()
    first.wait_ready()
    db_path = first.db
    try:
        async with support.Client(first.base) as client:
            tenant = await support.enroll(client, first.admin, name="RELIABILITY-Mac")
            device = await support.pair_device(client, tenant, name="RELIABILITY-iPhone")
            stamp = int(time.time() * 1000)
            written = await client.put("/account/state", token=device.token, json_body={
                "entries": [{"key": "reliabilityProbe", "value": {"round": 1},
                             "updatedAt": stamp}]})
            assert written.status == 200, written.text
            listed = await client.get("/devices", token=device.token)
            assert listed.status == 200, listed.text
            assert listed.json()["pairedDevices"] == 1

        # SIGKILL：不给 SIGTERM 处理机会，未 checkpoint 的页只能留在 -wal 里。
        first.process.send_signal(signal.SIGKILL)
        first.process.wait(timeout=10)
        wal_path = db_path.with_name(db_path.name + "-wal")
        db_bytes = db_path.stat().st_size
        wal_bytes = wal_path.stat().st_size if wal_path.exists() else 0
        assert wal_path.exists(), "kill -9 之后没有 -wal 文件：WAL 恢复路径无从验证"
        assert wal_bytes > 0, "kill -9 之后 -wal 是空的：这次崩溃没有留下待恢复的提交"
    finally:
        first.stop()

    # 同一个工作目录（同一个 state.db）、新的随机端口。
    second = RelayProcess(first.workdir, label="kill9-restart")
    second.start()
    try:
        second.wait_ready()
        async with support.Client(second.base) as client:
            health = await client.get("/healthz")
            assert health.status == 200, health.text

            # 设备令牌与设备行都还在（令牌在库里只存哈希，能通过校验就说明行没丢）。
            listed = await client.get("/devices", token=device.token)
            assert listed.status == 200, listed.text
            rows = {row["deviceId"]: row for row in listed.json()["devices"]}
            assert device.device_id in rows
            assert rows[device.device_id]["name"] == "RELIABILITY-iPhone"
            assert rows[device.device_id]["revoked"] is False

            # 账户状态还在，写入者与时间戳都没被重置。
            state = await client.get("/account/state", token=device.token)
            assert state.status == 200, state.text
            entry = state.json()["entries"]["reliabilityProbe"]
            assert entry["value"] == {"round": 1}
            assert entry["updatedAt"] == stamp
            assert entry["updatedByDeviceId"] == device.device_id

            # 电脑凭据仍然有效（账户与 agent 行都活过来了）。
            minted = await client.post("/pair/code", json_body={}, token=tenant.agent_token)
            assert minted.status == 200, minted.text
            assert minted.json()["code"]

        # 库还是 WAL，且结构完整；用只读连接看，不打断正在跑的中转。
        with sqlite3.connect(f"{db_path.as_uri()}?mode=ro", uri=True, timeout=5) as probe:
            assert probe.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
            assert probe.execute("PRAGMA integrity_check").fetchone()[0] == "ok"

        support.PROBE_NOTES.append(
            f"kill -9 恢复：db {db_bytes} B + wal {wal_bytes} B，重启后账户/设备/状态保留，"
            f"journal_mode=wal、integrity_check=ok")
    finally:
        second.stop()


# ── 连接风暴 ────────────────────────────────────────────────────────────────


async def _provision_storm(client: support.Client, relay: RelayProcess,
                           count: int) -> list[tuple[support.Tenant, support.Device]]:
    """一次铸够邀请码；每台设备各登记一台电脑、各配一台手机。

    这里**串行**准备数据：``/pair/code`` 里的 ``count_paired_devices`` 与
    ``/account/state`` 的 GET 共用一条没加锁的 SQLite 连接，并发调用会偶发 500
    （已知缺陷，见基线报告）。本用例要测的是“连接风暴”本身，不该被准备阶段
    的已知缺陷打断。50 台顺序准备约 1.5 秒，仍在单条 10 秒预算内。
    """
    invites = relay.admin("invite-mint", "--ttl-seconds", "600",
                          "--note", "reliability", "--count", str(count))
    if isinstance(invites, dict):
        invites = [invites]
    assert isinstance(invites, list) and len(invites) >= count, "邀请码数量不足"

    pairs: list[tuple[support.Tenant, support.Device]] = []
    for index in range(count):
        response = await client.post("/agents/enroll", json_body={
            "inviteCode": invites[index]["code"],
            "name": f"STORM-Mac-{index:02d}",
        })
        assert response.status == 200, f"登记失败：{response.status} {response.text[:200]}"
        body = response.json()
        tenant = support.Tenant(account_id=body["accountId"],
                                agent_id=body["agentId"],
                                agent_secret=body["agentSecret"],
                                name=body["agentName"])
        device = await support.pair_device(client, tenant,
                                          name=f"STORM-iPhone-{index:02d}")
        pairs.append((tenant, device))
    return pairs


async def test_fifty_devices_connecting_together_all_receive_host_status(
        client: support.Client, relay: RelayProcess) -> None:
    """50 台设备同时连：每台首帧 hostStatus、电脑侧 50 条 deviceAttach、无错误。"""
    pairs = await _provision_storm(client, relay, STORM_DEVICES)

    # 50 台设备 + 50 条 agent = 100 条 WS，超过 aiohttp 默认连接池上限（100）；
    # 这里用独立 session 并放开池上限，避免第 101 条连接被客户端自己卡住。
    async with aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=0),
            timeout=aiohttp.ClientTimeout(total=20)) as session:
        def open_ws(path: str, token: str):
            return session.ws_connect(client.base_url + path, headers=_auth(token))

        agent_sockets = list(await asyncio.gather(*(
            open_ws(support.agent_socket_path(tenant), tenant.agent_token)
            for tenant, _ in pairs)))
        device_sockets = list(await asyncio.gather(*(
            open_ws(support.device_socket_path(device), device.token)
            for _, device in pairs)))
        try:
            # 设备首帧：全部是 hostStatus，且认的是自己那台电脑。
            hosts = await asyncio.gather(*(
                support.read_frame(ws, what="设备首帧") for ws in device_sockets))
            for (tenant, _), frame in zip(pairs, hosts):
                assert frame["t"] == "hostStatus", frame
                assert frame["info"]["online"] is True, frame
                assert frame["info"]["agentId"] == tenant.agent_id, frame

            # 电脑侧对应收到 deviceAttach，设备号一一对上。
            attaches = await asyncio.gather(*(
                support.read_frame(ws, what="deviceAttach") for ws in agent_sockets))
            for (_, device), frame in zip(pairs, attaches):
                assert frame["t"] == "deviceAttach", frame
                assert frame["deviceId"] == device.device_id, frame

            # 每条连接都还能正常收发：pong 是真帧，没有 error 帧插进来。
            await asyncio.gather(*(ws.send_str('{"t":"ping","ts":77}')
                                   for ws in device_sockets))
            pongs = await asyncio.gather(*(
                support.read_frame(ws, what="pong") for ws in device_sockets))
            for frame in pongs:
                assert frame == {"t": "pong", "ts": 77}, frame

            health = await client.get("/healthz")
            assert health.status == 200, health.text
        finally:
            await asyncio.gather(*(ws.close() for ws in device_sockets),
                                 return_exceptions=True)
            await asyncio.gather(*(ws.close() for ws in agent_sockets),
                                 return_exceptions=True)

    support.PROBE_NOTES.append(
        f"连接风暴：{STORM_DEVICES} 台设备同时连接，全部 hostStatus + pong，"
        f"{STORM_DEVICES} 条 deviceAttach，无错误帧")


# ── 数据库写锁 ──────────────────────────────────────────────────────────────


async def test_a_held_write_lock_is_recorded_and_the_relay_recovers(
        client: support.Client, device: support.Device,
        relay: RelayProcess) -> None:
    """另一连接持写锁 2 秒：记录这次写的耗时与结果；锁释放后必须恢复正常。

    “持锁期间那次写是成功还是报错”取决于 SQLite busy 超时与实现选择，
    **只记录不判定**；判定的是“锁没了之后还能写、还能读、还健康”。
    """
    lock = sqlite3.connect(str(relay.db), timeout=5.0, isolation_level=None)
    outcome: dict[str, object] = {}
    lock.execute("BEGIN IMMEDIATE")
    stamp = int(time.time() * 1000)
    request_started = time.perf_counter()
    request = asyncio.create_task(client.put("/account/state", token=device.token, json_body={
        "entries": [{"key": "lockProbe", "value": {"held": 2}, "updatedAt": stamp}]},
        timeout=15.0))
    # 记下请求真正完成的时刻：请求可能在锁释放前就因为 busy 超时报错，
    # 不能拿“等满 2 秒之后”的墙钟冒充它的耗时。
    resolved_at: list[float] = []
    request.add_done_callback(lambda _task: resolved_at.append(time.perf_counter()))
    try:
        # 锁必须真的持有 2 秒，然后在请求还挂着的时候释放——否则测的是
        # “锁一直不放”，不是“释放后能否恢复”。
        await asyncio.sleep(2.0)
    finally:
        lock.execute("COMMIT")
        lock.close()

    try:
        response = await asyncio.wait_for(request, timeout=10.0)
    except Exception as error:  # noqa: BLE001 - 客户端异常也是要记录的结果
        outcome = {"elapsedMs": round((resolved_at[0] - request_started) * 1000, 1)
                   if resolved_at else None,
                   "result": f"exception:{type(error).__name__}",
                   "status": None, "errorCode": None}
    else:
        outcome = {"elapsedMs": round((resolved_at[0] - request_started) * 1000, 1)
                   if resolved_at else None,
                   "result": "ok" if response.status == 200 else "error",
                   "status": response.status,
                   "errorCode": response.error_code}

    summary = (f"写锁探针：另开连接 BEGIN IMMEDIATE 持锁 2.0 秒，"
               f"PUT /account/state 在 {outcome['elapsedMs']} ms 后 {outcome['result']}"
               f"（status={outcome['status']}, code={outcome['errorCode']}）")
    support.PROBE_NOTES.append(summary)
    print(summary)

    # 硬断言只落在“恢复”上：锁释放后一次新的写入必须 200，并且读得回来。
    recovery_stamp = int(time.time() * 1000) + 1
    recovered = await client.put("/account/state", token=device.token, json_body={
        "entries": [{"key": "lockRecovered", "value": {"after": "release"},
                     "updatedAt": recovery_stamp}]})
    assert recovered.status == 200, recovered.text
    assert recovered.json()["applied"] == ["lockRecovered"]

    read = await client.get("/account/state", token=device.token)
    assert read.status == 200, read.text
    assert read.json()["entries"]["lockRecovered"]["value"] == {"after": "release"}

    health = await client.get("/healthz")
    assert health.status == 200, health.text
