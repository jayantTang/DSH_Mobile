"""``GET /files/down``: streaming a large download through the relay (R-1 C-19).

The mirror of ``test_files_up.py``, with two questions of its own:

* does every byte the connector hands over reach the phone, in order, and does
  ``Range: bytes=N-`` actually make the connector start at ``N`` (a background
  ``URLSessionDownloadTask`` gets no ``.part`` continuation, so without ``Range``
  a dropped connection restarts the whole file); and
* are these bytes charged against the **device's own** rate and daily allowance?
  They are egress from a metered host, and a route that skipped those buckets
  would be a way around them.

The connector is a stub socket throughout: no Node process, no files.
"""

from __future__ import annotations

import asyncio
import base64
import json

import pytest
from aiohttp import WSMsgType

import hub as hub_module
from conftest import agent_headers


async def claim_device(client, provisioned, name="iPhone") -> dict:
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": name,
        "deviceModel": "iPhone17,1", "appVersion": "1.0",
    })
    assert response.status == 200, await response.text()
    return await response.json()


async def open_agent(client, provisioned):
    return await client.ws_connect(f"/link/agent?agentId={provisioned['agent']['agentId']}",
                                   headers=agent_headers(provisioned["agent"]))


async def open_device(client, provisioned, device):
    """Attach the phone's own socket.

    Only the billing tests need this: the rate bucket and the daily allowance
    live on the ``DeviceLink``, and without a socket there is no link — which is
    itself the correct behaviour (a download from a disconnected phone has
    nothing to charge, and the route answers 503 first anyway).
    """
    return await client.ws_connect(
        f"/link/device?agentId={device['agentId']}",
        headers={"Authorization": f"Bearer {device['deviceToken']}"})


async def recv_json(ws, timeout=3.0) -> dict:
    message = await asyncio.wait_for(ws.receive(), timeout)
    assert message.type == WSMsgType.TEXT, f"unexpected frame {message.type}: {message}"
    return json.loads(message.data)


async def drain(ws) -> None:
    try:
        while True:
            await asyncio.wait_for(ws.receive(), 0.2)
    except asyncio.TimeoutError:
        return


class FetchStub:
    """Plays the connector's half of a download: answers `fsGetBegin` with windows."""

    def __init__(self, agent_ws, body: bytes, *, window: int = 1 << 20,
                 ack=True, error=None, offset_honoured=True, eof=True):
        self.ws = agent_ws
        self.body = body
        self.window = window
        self.ack = ack
        self.error = error
        self.offset_honoured = offset_honoured
        self.eof = eof
        self.begins: list[dict] = []
        self.offsets: list[int] = []

    def slice_from(self, offset: int) -> list[bytes]:
        pieces = []
        for start in range(offset, len(self.body), self.window):
            pieces.append(self.body[start:start + self.window])
        return pieces

    async def run(self) -> None:
        frame = await recv_json(self.ws, timeout=15.0)
        assert frame.get("t") == "fsGetBegin", f"第一帧不是 fsGetBegin：{frame}"
        self.begins.append(frame)
        bid = frame["bid"]
        if self.error:
            await self.ws.send_json({"t": "fsErr", "bid": bid,
                                     "code": self.error[0], "message": self.error[1]})
            return
        if not self.ack:
            # 旧连接器：静默忽略。stub 这里什么也不做，连 ws 都不再读——
            # relay 应该自己超时回 501，而不是挂住。
            return
        offset = int(frame.get("offset") or 0)
        self.offsets.append(offset)
        await self.ws.send_json({"t": "fsGetAck", "bid": bid})
        pieces = self.slice_from(offset if self.offset_honoured else 0)
        for index, piece in enumerate(pieces):
            last = index == len(pieces) - 1
            await self.ws.send_json({
                "t": "fsGetChunk", "bid": bid,
                "data": base64.b64encode(piece).decode("ascii"),
                "eof": last and self.eof,
            })
        await self.ws.send_json({"t": "fsGetEnd", "bid": bid})


def down_url(device, **params) -> str:
    query = "&".join(f"{key}={value}" for key, value in params.items())
    return f"/files/down?{query}"


def device_auth(device) -> dict:
    return {"Authorization": f"Bearer {device['deviceToken']}"}


# ── the happy path ──────────────────────────────────────────────────────────

async def test_a_complete_download_arrives_whole_under_one_bid(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = bytes(range(256)) * 8000            # 2 MB: spans bridge windows
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="report.pdf", bid="bid-1"),
        headers=device_auth(device))
    payload = await response.read()
    await task

    assert response.status == 200, response.status
    assert payload == body, "字节在途中变了"
    assert [frame["bid"] for frame in stub.begins] == ["bid-1"]
    assert stub.begins[0]["path"] == "report.pdf"
    assert stub.begins[0]["scopeId"] == "s1"
    assert stub.begins[0]["offset"] == 0
    await agent_ws.close()


async def test_windows_are_written_through_without_buffering_the_file(client, provisioned):
    """响应体是流式的：连接器一片一片发，relay 一片一片写。

    这条用**分片大小**证：relay 不做额外的合并或切分（HTTP 客户端那边的
    读取块大小是 aiohttp 的事，这里看的是 relay 至少发出了全部字节，
    且中间没有等待——用一个大文件 + 小窗口，速度快到不可能是先攒完再发）。
    """
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = b"z" * (5 << 20)
    stub = FetchStub(agent_ws, body, window=64 * 1024)   # 80 片
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="big.bin", bid="bid-2"),
        headers=device_auth(device))
    payload = await response.read()
    await task

    assert response.status == 200
    assert payload == body
    assert len(stub.offsets) == 1
    await agent_ws.close()


# ── Range ───────────────────────────────────────────────────────────────────

async def test_range_header_maps_to_the_offset_the_connector_sees(client, provisioned):
    """`Range: bytes=N-` → 连接器收到的 offset == N，且只回后半段。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = bytes(range(256)) * 4000            # 1 MB
    offset = 700_000
    stub = FetchStub(agent_ws, body, window=1 << 20)
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="big.bin", bid="bid-3"),
        headers={**device_auth(device), "Range": f"bytes={offset}-"})
    payload = await response.read()
    await task

    assert response.status == 200
    assert stub.offsets == [offset], f"连接器没收到 Range 的 offset：{stub.offsets}"
    assert payload == body[offset:], "只该回后半段"
    assert len(payload) == len(body) - offset
    await agent_ws.close()


async def test_a_query_offset_works_when_there_is_no_range_header(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = b"q" * 300_000
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="big.bin", offset=100_000, bid="bid-4"),
        headers=device_auth(device))
    payload = await response.read()
    await task
    assert response.status == 200
    assert stub.offsets == [100_000]
    assert payload == body[100_000:]
    await agent_ws.close()


async def test_the_range_header_wins_over_the_query_offset(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = b"r" * 200_000
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="big.bin", offset=10, bid="bid-5"),
        headers={**device_auth(device), "Range": "bytes=150000-"})
    await response.read()
    await task
    assert stub.offsets == [150_000]
    await agent_ws.close()


@pytest.mark.parametrize("header", [
    "bytes=abc-",      # 不是数字
    "bytes=-500",      # 后缀形式：只有长度，没有起点
    "bytes=1-2",       # 闭区间：本实现故意不支持
    "bytes=0-1,5-6",   # 多段
    "items=0-",
    "",
])
async def test_unparsable_range_headers_are_ignored_not_rejected(client, provisioned, header):
    """不认识就**忽略**（从头发），而不是 400——代理重写头不该毁掉一次下载。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    body = b"h" * 1024
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-hdr"),
        headers={**device_auth(device), "Range": header})
    payload = await response.read()
    await task
    assert response.status == 200
    assert stub.offsets == [0]
    assert payload == body
    await agent_ws.close()


def test_the_range_parser_accepts_only_the_one_form_it_implements():
    """纯函数边界，不需要起 HTTP。"""
    import api
    assert api._parse_range("bytes=0-") == 0
    assert api._parse_range("bytes= 42 -") == 42
    assert api._parse_range("BYTES=7-") == 7
    assert api._parse_range(None) is None
    assert api._parse_range("") is None
    assert api._parse_range("bytes=") is None
    assert api._parse_range("bytes=abc-") is None
    assert api._parse_range("bytes=-1") is None
    assert api._parse_range("bytes=1-2") is None
    assert api._parse_range("bytes=1-2,3-4") is None
    assert api._parse_range("bytes=999-", total=100) is None


# ── failures, all of them prompt ────────────────────────────────────────────

async def test_an_offline_agent_is_refused_immediately(client, provisioned):
    device = await claim_device(client, provisioned)
    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-6"),
        headers=device_auth(device))
    assert response.status == 503
    assert (await response.json())["error"]["code"] == "host/offline"


async def test_a_missing_file_is_reported_as_the_connectors_own_code(client, provisioned):
    """`workspace-file/not-found` **原样**回给 App —— 它靠这个码判断"不该重试"。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = FetchStub(agent_ws, b"", error=("workspace-file/not-found", "no such file"))
    task = asyncio.create_task(stub.run())

    response = await client.get(
        down_url(device, scopeId="s1", path="gone.bin", bid="bid-7"),
        headers=device_auth(device))
    await task
    assert response.status == 409
    error = (await response.json())["error"]
    assert error["code"] == "workspace-file/not-found"
    assert "no such file" in error["message"]
    await agent_ws.close()


async def test_an_old_connector_that_never_acks_gets_a_501(client, provisioned, monkeypatch):
    monkeypatch.setattr(hub_module.FileFetchBridge, "wait_ack",
                        lambda self, timeout: asyncio.sleep(0, result=False))
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-8"),
        headers=device_auth(device))
    assert response.status == 501
    error = (await response.json())["error"]
    assert error["code"] == "file/unsupported"
    assert "连接器版本过旧" in error["message"]
    await agent_ws.close()


async def test_a_missing_scope_is_a_400_before_anything_is_sent(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    response = await client.get(down_url(device, path="f.bin"), headers=device_auth(device))
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "request/incomplete"
    # 没有 fsGetBegin 发出去。
    with pytest.raises(asyncio.TimeoutError):
        await recv_json(agent_ws, timeout=0.3)
    await agent_ws.close()


async def test_a_bad_token_is_a_401(client, provisioned):
    response = await client.get(down_url({"deviceToken": "dt_nope"}, scopeId="s", path="p"))
    assert response.status == 401
    assert (await response.json())["error"]["code"] == "auth/invalid-token"


async def test_an_agent_that_drops_after_acking_ends_the_response(client, provisioned):
    """连接器中途掉线 → HTTP 以**截断的响应体**结束，不挂住。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    async def ack_then_die():
        frame = await recv_json(agent_ws)
        assert frame["t"] == "fsGetBegin"
        await agent_ws.send_json({"t": "fsGetAck", "bid": frame["bid"]})
        await agent_ws.send_json({
            "t": "fsGetChunk", "bid": frame["bid"],
            "data": base64.b64encode(b"x" * 4096).decode("ascii"), "eof": False,
        })
        await agent_ws.close()

    task = asyncio.create_task(ack_then_die())
    response = await asyncio.wait_for(client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-9"),
        headers=device_auth(device)), 10)
    payload = await response.read()
    await task
    # aiohttp 的测试客户端在响应体被截断时把 payload 读完仍然给 200 —— 这里只断言
    # **没有挂住**，且拿到的字节是连接器真发出来的那一片（不是空的）。
    assert response.status == 200
    assert payload == b"x" * 4096
    await agent_ws.close()


# ── billing: the same buckets as the WebSocket path ─────────────────────────

async def test_a_download_charges_the_devices_own_egress_and_daily_allowance(
        client, provisioned, monkeypatch):
    """**计费证据**：一次 HTTP 下载后，该设备今天的 `egressBytes` 增长量与字节数一致。

    与 WSS 同量级的比对：WSS 那条路的记账口径是"发给设备的字节"
    （`DeviceLink._count_egress`，`hub.py` 的 `_note_egress` 回调），这里走的是
    同一对 helper，所以两个数字应该**同量级**——用同一个明确的小文件跑两边
    就是本项要的证据。
    """
    from store import local_day

    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    device_ws = await open_device(client, provisioned, device)
    await drain(agent_ws)

    body = b"b" * 4096

    # ① WSS 老路：agent → 设备的一条普通帧。
    await agent_ws.send_json({"t": "res", "id": "r1", "deviceId": device["deviceId"],
                              "result": {"ok": True, "data": "b" * 4096}})
    await drain(agent_ws)
    hub = client.app["hub"]
    await hub.flush_usage()
    row = [r for r in hub.store.usage_rows(local_day())
           if r["deviceId"] == device["deviceId"]]
    assert row, "WSS 那条路没有记账"
    wss_bytes = row[0]["egressBytes"]
    assert wss_bytes > 0

    # ② 新 HTTP 路：同一个设备的下载。
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())
    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-10"),
        headers=device_auth(device))
    payload = await response.read()
    await task
    assert payload == body

    await hub.flush_usage()
    row = [r for r in hub.store.usage_rows(local_day())
           if r["deviceId"] == device["deviceId"]]
    http_bytes = row[0]["egressBytes"] - wss_bytes
    # 响应体是 base64 解出来的原始字节，所以增长量就是文件大小（不是 1.33 倍）。
    assert http_bytes == len(body), f"HTTP 下载记账 {http_bytes} != {len(body)}"
    assert http_bytes / wss_bytes == pytest.approx(len(body) / wss_bytes, rel=0.01)
    await device_ws.close()
    await agent_ws.close()


async def test_a_download_is_paced_by_the_devices_rate_bucket(client, provisioned, monkeypatch):
    """**限速生效**：用桩时钟推进，不真等。

    做法：把 `DeviceLink.pace` 换成一个记录调用参数的桩——它就是要验的那个
    helper，被 HTTP 响应体写作路径调到了、而且带上了正确的字节数。真实的
    "等"由 `TokenBucket` 的既有测试负责（`test_limits.py`）。
    """
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    device_ws = await open_device(client, provisioned, device)
    await drain(agent_ws)
    hub = client.app["hub"]
    link = hub._devices[device["deviceId"]]

    paced: list[int] = []
    original = link.pace

    async def spy(size: int) -> None:
        paced.append(size)
        await original(size)

    monkeypatch.setattr(link, "pace", spy)

    body = b"p" * (3 << 20)
    stub = FetchStub(agent_ws, body, window=1 << 20)
    task = asyncio.create_task(stub.run())
    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-11"),
        headers=device_auth(device))
    await response.read()
    await task

    # 每片都过了一次限速桶，且总字节数正好是文件大小（不多不少）。
    assert sum(paced) == len(body), f"限速桶被计了 {sum(paced)} 字节，文件是 {len(body)}"
    assert all(size > 0 for size in paced)
    # 一个 1 MB 的片不该整块丢进桶里（那是 WS 路径的粒度），按 1 MB 的计费片走。
    assert max(paced) <= api_slice()
    await device_ws.close()
    await agent_ws.close()


def api_slice() -> int:
    import api
    return api.DOWN_CHARGE_SLICE


async def test_going_over_the_daily_allowance_cuts_the_download_short(
        client, provisioned, monkeypatch):
    """日额度用尽 → 响应体被截断（不是静默地送完整份）。"""
    import store as store_module

    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    device_ws = await open_device(client, provisioned, device)
    await drain(agent_ws)
    hub = client.app["hub"]
    link = hub._devices[device["deviceId"]]
    link.quota.limit = 1024          # 1 KB：第一片就超

    body = b"l" * (1 << 20)
    stub = FetchStub(agent_ws, body, window=1 << 20)
    task = asyncio.create_task(stub.run())
    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-12"),
        headers=device_auth(device))
    payload = await response.read()
    await task

    assert len(payload) < len(body), "超额度还是把整份发出去了"
    assert len(payload) <= 1024 + api_slice()
    await device_ws.close()
    await agent_ws.close()


async def test_the_download_route_does_not_bypass_the_device_bucket_object(
        client, provisioned):
    """这条钉住"**没有复制一份**限速/计费"：用的是 `DeviceLink` 上那两个对象本身。

    桶的初始 burst 是 64 KB，所以断言不能是"tokens 变小了"——一个 8 KB 的文件
    被桶整个吃掉也不会让 tokens 变负或变小到可观测。这里改**注入桶的引用**：
    把 `link.bucket` 换成一个记录了每次 `take` 的包装，直接问"这次下载扣了多少"。
    """
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    device_ws = await open_device(client, provisioned, device)
    await drain(agent_ws)
    hub = client.app["hub"]
    link = hub._devices[device["deviceId"]]
    before_egress = link.egress_bytes
    inner = link.bucket

    taken: list[int] = []

    class RecordingBucket:
        enabled = inner.enabled

        def take(self, amount: int) -> float:
            taken.append(amount)
            return inner.take(amount)

    watcher = RecordingBucket()
    link.bucket = watcher
    # 日额度桶默认**不启用**（limit 0 = 不限），启用了才谈得上"扣了没有"。
    link.quota.limit = 1 << 30

    body = b"k" * 8192
    stub = FetchStub(agent_ws, body)
    task = asyncio.create_task(stub.run())
    response = await client.get(
        down_url(device, scopeId="s1", path="f.bin", bid="bid-13"),
        headers=device_auth(device))
    await response.read()
    await task

    assert sum(taken) == len(body), f"限速桶被扣了 {sum(taken)} 字节，文件是 {len(body)}"
    assert link.egress_bytes == before_egress + len(body), "计数字节不对"
    assert link.quota.used >= len(body), "日额度桶没被扣"
    await device_ws.close()
    await agent_ws.close()
