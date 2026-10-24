"""功能场景：账户级状态（读写、单调、隔离、跨设备通知、并发探针）。

并发探针是**已知缺陷**的固定观察点（``maintainers/design/DESIGN-20261023-go-migration-testbed.md``
§4）：当前 Python 实现的 ``/account/state`` 共享一条 SQLite 连接，并发读会撞上
"读写交错"，线上三天出现过 8 次 500。这里用 ``xfail(strict=False)`` 钉住它：

* 缺陷还在 → xfail，套件保持绿，错误数照实打印；
* 缺陷修好（或 Go 版替换）→ XPASS，同样不红，等于提醒"该把这条标记摘掉了"。

因此这条用例**永远不会**因为缺陷本身让套件失败。
"""

from __future__ import annotations

import asyncio
import time

import pytest

from . import support


async def _put(client: support.Client, token: str, entries: list[dict]) -> support.HttpResponse:
    return await client.put("/account/state", token=token, json_body={"entries": entries})


async def test_an_older_write_does_not_overwrite_a_newer_one(
        client: support.Client, tenant: support.Tenant) -> None:
    """``updatedAt`` 只前进：晚到的旧写被拒收，读回来仍是最新那份。"""
    first = await support.pair_device(client, tenant, name="BLACKBOX-first")
    second = await support.pair_device(client, tenant, name="BLACKBOX-second")
    stamp = int(time.time() * 1000)

    newer = await _put(client, second.token,
                       [{"key": "readWatermark", "value": 2, "updatedAt": stamp + 1000}])
    assert newer.status == 200, newer.text
    assert newer.json()["applied"] == ["readWatermark"]

    older = await _put(client, first.token,
                       [{"key": "readWatermark", "value": 1, "updatedAt": stamp}])
    assert older.status == 200, older.text
    assert older.json()["applied"] == []
    assert older.json()["entries"]["readWatermark"]["value"] == 2

    read = await client.get("/account/state", token=first.token)
    assert read.status == 200, read.text
    entry = read.json()["entries"]["readWatermark"]
    assert entry["value"] == 2
    assert entry["updatedAt"] == stamp + 1000
    assert entry["updatedByDeviceId"] == second.device_id


async def test_state_does_not_leak_across_accounts(
        client: support.Client, relay, device: support.Device) -> None:
    """账户状态按账户隔离：另一个账户读不到、也改不动这一份。"""
    stamp = int(time.time() * 1000)
    written = await _put(client, device.token,
                         [{"key": "privateKey", "value": "account-a", "updatedAt": stamp}])
    assert written.status == 200, written.text

    other = await support.enroll(client, relay.admin, name="BLACKBOX-other-mac")
    other_device = await support.pair_device(client, other, name="BLACKBOX-other-phone")
    read = await client.get("/account/state", token=other_device.token)
    assert read.status == 200, read.text
    assert read.json()["accountId"] == other.account_id
    assert read.json()["entries"] == {}

    own = await client.get("/account/state", token=device.token)
    assert own.json()["entries"]["privateKey"]["value"] == "account-a"


async def test_a_write_notifies_the_other_device_but_not_the_writer(
        client: support.Client, tenant: support.Tenant) -> None:
    """同账户的两台在线设备：写入方之外的设备收到 ``accountState`` 帧。"""
    writer = await support.pair_device(client, tenant, name="BLACKBOX-writer")
    listener = await support.pair_device(client, tenant, name="BLACKBOX-listener")

    writer_ws = await client.ws(support.device_socket_path(writer), token=writer.token)
    listener_ws = await client.ws(support.device_socket_path(listener), token=listener.token)
    try:
        assert (await support.read_frame(writer_ws))["t"] == "hostStatus"
        assert (await support.read_frame(listener_ws))["t"] == "hostStatus"

        written = await _put(client, writer.token,
                             [{"key": "alertPrefs", "value": {"turnEnd": False},
                               "updatedAt": int(time.time() * 1000)}])
        assert written.status == 200, written.text

        notification = await support.read_frame(listener_ws, what="accountState 通知帧")
        assert notification["t"] == "accountState", notification
        assert notification["keys"] == ["alertPrefs"]

        await support.expect_silence(writer_ws, seconds=1.0)
    finally:
        await writer_ws.close()
        await listener_ws.close()


@pytest.mark.xfail(
    strict=False,
    reason="已知缺陷：/account/state 并发读写会 500（共享 SQLite 连接，DESIGN-20261023 §4）")
async def test_concurrent_account_state_traffic_is_answered_without_5xx(
        client: support.Client, device: support.Device) -> None:
    """16 个并发任务同时 GET/PUT：记录 5xx 与异常，任何一次都算缺陷复现。"""
    failures: list[str] = []
    statuses: dict[int, int] = {}
    tasks = 16
    rounds = 12
    stamp = int(time.time() * 1000)

    def record(status: int) -> None:
        statuses[status] = statuses.get(status, 0) + 1

    async def worker(index: int) -> None:
        for attempt in range(rounds):
            try:
                read = await client.get("/account/state", token=device.token)
                record(read.status)
                if read.status >= 500:
                    failures.append(f"GET {read.status}: {read.text[:120]}")
                written = await _put(client, device.token, [{
                    "key": f"probe{index % 4}",
                    "value": {"worker": index, "attempt": attempt},
                    "updatedAt": stamp + attempt,
                }])
                record(written.status)
                if written.status >= 500:
                    failures.append(f"PUT {written.status}: {written.text[:120]}")
            except Exception as error:  # noqa: BLE001 - 这里的异常本身就是被测现象
                failures.append(f"异常: {type(error).__name__}: {error}")

    await asyncio.gather(*(worker(index) for index in range(tasks)))

    summary = (f"16 并发任务 × {rounds} 轮：状态码 {dict(sorted(statuses.items()))}，"
               f"5xx/异常 {len(failures)} 次")
    support.PROBE_NOTES.append(summary)
    print(summary)
    for line in failures[:5]:
        print(f"  - {line}")

    # 探针结束后中转必须还能正常服务（缺陷是并发读写，不是永久损坏）。
    after = await _put(client, device.token,
                       [{"key": "afterProbe", "value": 1, "updatedAt": stamp + 10_000}])
    assert after.status == 200, after.text

    assert not failures, f"并发探针撞到 {len(failures)} 次失败：{failures[:5]}"
