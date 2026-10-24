"""文件通道契约（R-1 C-17/C-19）：上传、下载、Range 续传与中断重试。

中转不存字节：``PUT /files/up`` 把请求体按 1 MB 切片，经连接器的 WebSocket
（``fsPutBegin`` / ``fsPutChunk`` / ``fsPutEnd``）推给「电脑」；``GET /files/down``
反方向把连接器送来的 ``fsGetChunk`` 直接写进 HTTP 正文。这些帧不是 DLP，手机两端
都看不到，所以黑盒用例必须**自己扮演连接器**：开一条真 agent WebSocket，按现有
帧协议收、回执，然后断言 HTTP 侧的结果与连接器看到的帧序列。

`client_max_size` 在 ``/files/up`` 上**不生效**（handler 自己 ``readany()`` 消费请求体，
不走 aiohttp 的整段读取）。所以这里钉的是实测行为：超过 32 MB 的 body 仍然 200，
不是 413；真正的 413 在反馈接口的 16 KB 上限上（见 ``test_contract_feedback.py``）。
"""

from __future__ import annotations

import asyncio
import base64
import json

import aiohttp
import pytest

from . import support

#: 连接器帧的等待上限。HTTP 侧自己也有超时，两者都不许无限等。
FRAME_TIMEOUT_S = 10.0
#: 中转等连接器 ack 的上限是 5 秒；用例等 HTTP 应答要留出余量。
ACK_TIMEOUT_S = 15.0


def up_path(*, size: int, session: str = "s1", name: str = "big.bin",
            bid: str = "app-bid-1") -> str:
    return f"/files/up?sessionId={session}&name={name}&bid={bid}&bytes={size}"


def down_path(*, scope: str = "s1", path: str = "big.bin", bid: str = "app-bid-1",
              offset: int | None = None) -> str:
    query = f"scopeId={scope}&path={path}&bid={bid}"
    if offset is not None:
        query += f"&offset={offset}"
    return f"/files/down?{query}"


class FakeConnector:
    """一条 agent WebSocket + 收发帧的帮手。"""

    def __init__(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        self.ws = ws
        self.seen: list[dict] = []

    async def next(self, *, timeout: float = FRAME_TIMEOUT_S) -> dict:
        frame = await support.read_frame(self.ws, timeout=timeout, what="连接器帧")
        self.seen.append(frame)
        return frame

    async def send(self, frame: dict) -> None:
        await self.ws.send_str(json.dumps(frame, ensure_ascii=False))

    async def next_begin(self) -> dict:
        """读下一帧，跳过 ``fsGetCancel``（它可能插在两个 begin 之间）。"""
        while True:
            frame = await self.next(timeout=ACK_TIMEOUT_S)
            if frame.get("t") != "fsGetCancel":
                return frame


class UploadStub:
    """扮演连接器的上传半边：收 begin/chunk/end，回 ack/done（或拒绝）。"""

    def __init__(self, connector: FakeConnector, *,
                 error: tuple[str, str] | None = None) -> None:
        self.connector = connector
        self.error = error
        self.begin: dict | None = None
        self.end: dict | None = None
        self.chunks: list[bytes] = []
        self.seqs: list[int] = []

    async def run(self) -> None:
        while True:
            frame = await self.connector.next(timeout=ACK_TIMEOUT_S)
            kind = frame["t"]
            if kind == "fsPutBegin":
                self.begin = frame
                if self.error:
                    await self.connector.send({"t": "fsErr", "bid": frame["bid"],
                                               "code": self.error[0],
                                               "message": self.error[1]})
                    return
                await self.connector.send({"t": "fsPutAck", "bid": frame["bid"],
                                           "received": 0})
            elif kind == "fsPutChunk":
                self.seqs.append(frame["seq"])
                self.chunks.append(base64.b64decode(frame["data"]))
            elif kind == "fsPutEnd":
                self.end = frame
                if self.error:
                    await self.connector.send({"t": "fsErr", "bid": frame["bid"],
                                               "code": self.error[0],
                                               "message": self.error[1]})
                else:
                    await self.connector.send({
                        "t": "fsPutDone", "bid": frame["bid"],
                        "path": "/home/u/.dsh/inbox/s1/big.bin",
                        "bytes": sum(len(piece) for piece in self.chunks)})
                return
            else:
                # 设备生命周期帧不属于这条通道；留着不影响断言。
                continue


class DownloadStub:
    """扮演连接器的下载半边：回 ack，按窗口送 chunk/end（或中途报错）。"""

    def __init__(self, connector: FakeConnector, body: bytes, *, window: int = 256 * 1024,
                 announce: bool = True, version: str = "v1",
                 fail_after_chunks: int | None = None,
                 error: tuple[str, str] | None = None) -> None:
        self.connector = connector
        self.body = body
        self.window = window
        self.announce = announce
        self.version = version
        self.fail_after_chunks = fail_after_chunks
        self.error = error
        self.begin: dict | None = None
        self.cancels: list[str] = []

    def pieces_from(self, offset: int) -> list[bytes]:
        return [self.body[start:start + self.window]
                for start in range(offset, len(self.body), self.window)]

    async def run(self) -> None:
        begin = await self.connector.next_begin()
        assert begin.get("t") == "fsGetBegin", f"连接器第一帧不是 fsGetBegin：{begin}"
        self.begin = begin
        bid = begin["bid"]
        if self.error:
            await self.connector.send({"t": "fsErr", "bid": bid,
                                       "code": self.error[0], "message": self.error[1]})
            return
        ack: dict = {"t": "fsGetAck", "bid": bid}
        if self.announce:
            ack["size"] = len(self.body)
            ack["version"] = self.version
        await self.connector.send(ack)

        offset = int(begin.get("offset") or 0)
        pieces = self.pieces_from(offset)
        for index, piece in enumerate(pieces):
            last = index == len(pieces) - 1
            await self.connector.send({
                "t": "fsGetChunk", "bid": bid,
                "data": base64.b64encode(piece).decode("ascii"),
                "eof": last,
            })
            if self.fail_after_chunks is not None and index + 1 >= self.fail_after_chunks:
                # 传输中途断掉：HTTP 侧已经拿到 200 与总长，只能以短正文收场。
                await self.connector.send({
                    "t": "fsErr", "bid": bid,
                    "code": "workspace-file/read-failed",
                    "message": "the connector lost the file mid-stream"})
                return
        await self.connector.send({"t": "fsGetEnd", "bid": bid})


async def open_agent(client: support.Client, tenant: support.Tenant) -> FakeConnector:
    ws = await client.ws(support.agent_socket_path(tenant), token=tenant.agent_token)
    return FakeConnector(ws)


async def ack_and_wait(connector: FakeConnector) -> None:
    """只回一个 ack：用于「正文比声明的短」这类连接器不会再收到 end 的路径。"""
    begin = await connector.next(timeout=ACK_TIMEOUT_S)
    assert begin["t"] == "fsPutBegin", begin
    await connector.send({"t": "fsPutAck", "bid": begin["bid"], "received": 0})
    try:
        await connector.next(timeout=1.0)
    except support.FrameTimeout:
        return


# ── 上传 ────────────────────────────────────────────────────────────────────


async def test_upload_streams_the_file_through_the_connector(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """正文按 1 MB 切片、同一 bid、seq 连续；HTTP 200 带回连接器算出的路径与字节数。"""
    connector = await open_agent(client, tenant)
    try:
        body = bytes(range(256)) * 5000          # 1.28 MB，跨两个桥接分片
        stub = UploadStub(connector)
        task = asyncio.create_task(stub.run())
        response = await client.put(up_path(size=len(body)), data=body,
                                    token=device.token, timeout=20)
        await task

        assert response.status == 200, response.text
        payload = response.json()
        assert payload["ok"] is True
        assert payload["bytes"] == len(body)
        assert payload["path"] == "/home/u/.dsh/inbox/s1/big.bin"

        assert stub.begin is not None and stub.end is not None
        assert stub.begin["sessionId"] == "s1" and stub.begin["name"] == "big.bin"
        assert stub.begin["bytes"] == len(body)
        assert stub.begin["bid"] == stub.end["bid"] == "app-bid-1"
        assert stub.seqs == [0, 1], f"分片序号必须从 0 连续：{stub.seqs}"
        assert b"".join(stub.chunks) == body, "拼起来必须与原文件逐字节相同"
    finally:
        await connector.ws.close()


async def test_upload_requires_a_device_token(client: support.Client) -> None:
    response = await client.put(up_path(size=3), data=b"abc")
    support.assert_error_envelope(response, status=401, code="auth/invalid-token")

    bad = await client.put(up_path(size=3), data=b"abc", token="dt_not-a-real-token")
    support.assert_error_envelope(bad, status=401, code="auth/invalid-token")


async def test_upload_validates_the_query_before_talking_to_the_connector(
        client: support.Client, device: support.Device) -> None:
    missing = await client.put("/files/up?sessionId=s1", data=b"",
                               token=device.token)
    support.assert_error_envelope(missing, status=400, code="request/incomplete")

    bad_bytes = await client.put("/files/up?sessionId=s1&name=n&bid=b&bytes=abc",
                                 data=b"", token=device.token)
    support.assert_error_envelope(bad_bytes, status=400, code="request/bytes")

    negative = await client.put("/files/up?sessionId=s1&name=n&bid=b&bytes=-1",
                                data=b"", token=device.token)
    support.assert_error_envelope(negative, status=400, code="request/bytes")


async def test_a_body_shorter_than_declared_is_rejected(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    connector = await open_agent(client, tenant)
    try:
        task = asyncio.create_task(ack_and_wait(connector))
        response = await client.put(up_path(size=10, bid="short-body"), data=b"12345",
                                    token=device.token, timeout=20)
        await task
        support.assert_error_envelope(response, status=400, code="request/bytes")
    finally:
        await connector.ws.close()


async def test_upload_without_a_connected_connector_answers_503(
        client: support.Client, device: support.Device) -> None:
    response = await client.put(up_path(size=3), data=b"abc", token=device.token)
    support.assert_error_envelope(response, status=503, code="host/offline")


async def test_a_connector_that_rejects_the_upload_carries_its_own_error(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    connector = await open_agent(client, tenant)
    try:
        stub = UploadStub(connector, error=("workspace-file/too-large",
                                            "the connector will not write this file"))
        task = asyncio.create_task(stub.run())
        response = await client.put(up_path(size=3, bid="rejected"), data=b"abc",
                                    token=device.token, timeout=20)
        await task
        support.assert_error_envelope(response, status=409,
                                      code="workspace-file/too-large")
    finally:
        await connector.ws.close()


async def test_a_body_over_the_frame_limit_is_not_413(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """实测：``/files/up`` 自己消费请求体，``client_max_size`` 在这条路上不生效。

    32 MB + 64 KB 的 body 照常上传成功（200），连接器收到全部字节。若哪天这里
    变成 413，说明 aiohttp 重新开始预读 body，App 侧的回落策略要重新评估；
    Go 版也应当保持「文件通道不受 WebSocket 帧上限约束」。
    """
    over = 32 * 1024 * 1024 + (64 << 10)
    connector = await open_agent(client, tenant)
    try:
        stub = UploadStub(connector)
        task = asyncio.create_task(stub.run())
        response = await client.put(up_path(size=over, bid="over-frame-limit"),
                                    data=b"\0" * over, token=device.token, timeout=90)
        await task

        assert response.status == 200, (
            f"超过 32 MB 的 body 得到 {response.status}；若是 413，说明 "
            "client_max_size 在 /files/up 上重新生效了")
        assert response.json()["bytes"] == over
        assert sum(len(piece) for piece in stub.chunks) == over
    finally:
        await connector.ws.close()


async def test_an_old_connector_gets_501_after_the_ack_deadline(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """老连接器不认识 ``fsPutBegin``（未知帧被静默忽略）：5 秒后回 501，不是挂死。"""
    connector = await open_agent(client, tenant)
    try:
        request = asyncio.create_task(
            client.put(up_path(size=3, bid="old-connector"), data=b"abc",
                       token=device.token, timeout=15))
        try:
            begin = await connector.next(timeout=ACK_TIMEOUT_S)
            assert begin["t"] == "fsPutBegin", begin
            # 不 ack，也不回任何帧：中转应在 5 秒后自己放弃。
            response = await request
        finally:
            if not request.done():
                request.cancel()
        support.assert_error_envelope(response, status=501, code="file/unsupported")
    finally:
        await connector.ws.close()


# ── 下载 ────────────────────────────────────────────────────────────────────


async def test_download_streams_the_file_and_mints_its_own_bridge_id(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """``fsGetBegin`` 的 bid 由中转生成；App 的 bid 只作为 ``replaces`` 带过去。"""
    connector = await open_agent(client, tenant)
    try:
        body = bytes(range(256)) * 5000          # 1.28 MB
        stub = DownloadStub(connector, body)
        task = asyncio.create_task(stub.run())
        response = await client.get(down_path(bid="app-bid-down"), token=device.token,
                                    timeout=20)
        await task

        assert response.status == 200, response.text
        assert response.raw == body
        assert support.header(response, "Content-Length") == str(len(body))
        assert support.header(response, "Accept-Ranges") == "bytes"
        assert support.header(response, "ETag") == f'"dsh-v1-{len(body)}"'
        assert support.header(response, "Content-Range") is None
        assert support.header(response, "Cache-Control") == "no-store"

        assert stub.begin is not None
        assert stub.begin["scopeId"] == "s1" and stub.begin["path"] == "big.bin"
        assert stub.begin["offset"] == 0
        assert stub.begin["deviceId"] == device.device_id
        assert stub.begin["bid"] != "app-bid-down", "bid 必须由中转现铸，不能沿用 App 的"
        assert stub.begin["replaces"] == "app-bid-down"
    finally:
        await connector.ws.close()


async def test_range_header_resumes_at_the_offset_the_connector_sees(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    connector = await open_agent(client, tenant)
    try:
        body = bytes(range(256)) * 4000          # 1 MB
        offset = 700_000
        stub = DownloadStub(connector, body, version="v-abc")
        task = asyncio.create_task(stub.run())
        response = await client.get(down_path(), token=device.token,
                                    headers={"Range": f"bytes={offset}-"}, timeout=20)
        await task

        assert response.status == 206, response.text
        assert response.raw == body[offset:]
        assert stub.begin is not None and stub.begin["offset"] == offset
        assert support.header(response, "Content-Length") == str(len(body) - offset)
        assert support.header(response, "Content-Range") == \
            f"bytes {offset}-{len(body) - 1}/{len(body)}"
        assert support.header(response, "X-DSH-Offset") == str(offset)
        assert support.header(response, "ETag") == f'"dsh-v-abc-{len(body)}"'
    finally:
        await connector.ws.close()


async def test_a_query_offset_works_without_a_range_header(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    connector = await open_agent(client, tenant)
    try:
        body = b"q" * 100_000
        stub = DownloadStub(connector, body, window=30_000)
        task = asyncio.create_task(stub.run())
        response = await client.get(down_path(offset=40_000), token=device.token,
                                    timeout=20)
        await task
        assert response.status == 206, response.text
        assert response.raw == body[40_000:]
        assert stub.begin is not None and stub.begin["offset"] == 40_000
    finally:
        await connector.ws.close()


async def test_an_offset_past_the_end_answers_416(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """``offset >= total`` 是 416，不是「200 + 空正文」（后者会被当成完整文件）。"""
    connector = await open_agent(client, tenant)
    try:
        body = b"z" * 1000
        stub = DownloadStub(connector, body)
        task = asyncio.create_task(stub.run())
        response = await client.get(down_path(), token=device.token,
                                    headers={"Range": "bytes=1000-"}, timeout=20)
        await task
        support.assert_error_envelope(response, status=416, code="request/offset")
    finally:
        await connector.ws.close()


async def test_download_without_a_connected_connector_answers_503(
        client: support.Client, device: support.Device) -> None:
    response = await client.get(down_path(), token=device.token)
    support.assert_error_envelope(response, status=503, code="host/offline")


async def test_a_missing_file_carries_the_connectors_error_code(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    connector = await open_agent(client, tenant)
    try:
        stub = DownloadStub(connector, b"",
                            error=("workspace-file/not-found",
                                   "no such file in this workspace"))
        task = asyncio.create_task(stub.run())
        response = await client.get(down_path(path="nope.bin"), token=device.token,
                                    timeout=20)
        await task
        support.assert_error_envelope(response, status=409,
                                      code="workspace-file/not-found")
    finally:
        await connector.ws.close()


async def test_a_download_interrupted_mid_stream_can_resume_with_range(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """连接器中途报错：正文短于总长；带 Range 重试从中断处补齐。

    第一次的 HTTP 状态已经发出去（200 + 完整 Content-Length），唯一诚实的收场是
    停下来写正文；客户端拿到短包（与真断线同形），下一次从已收字节处续传。
    """
    body = bytes(range(256)) * 20                # 5120 字节，两片 2560
    connector = await open_agent(client, tenant)
    try:
        first = DownloadStub(connector, body, window=2560, fail_after_chunks=1)
        task = asyncio.create_task(first.run())
        received = bytearray()
        status = 0
        interrupted = False
        # 这一版的实测行为：中途报错后正文停下，但连接不会被主动关闭，客户端要等
        # 自己的超时才结束（`write_eof` 对已声明 Content-Length 的短包不关连接）。
        # 客户端提前断开也同样是"中断"，两种收场都接受。
        try:
            async with client.session.get(
                    client.base_url + down_path(bid="first-run"),
                    headers={"Authorization": f"Bearer {device.token}"},
                    timeout=aiohttp.ClientTimeout(total=1.0)) as response:
                status = response.status
                async for chunk in response.content.iter_any():
                    received.extend(chunk)
        except (TimeoutError, asyncio.TimeoutError, aiohttp.ClientPayloadError):
            interrupted = True
        await task

        assert interrupted is True, "中断必须让客户端侧拿到不完整的正文"
        assert status == 200
        assert len(received) == 2560, f"应当只收到第一片：{len(received)}"
        # 中断之后中转必须叫停连接器那一次 run（否则它会为没人读的正文读到底）。
        cancel = await connector.next(timeout=5.0)
        while cancel.get("t") != "fsGetCancel":
            cancel = await connector.next(timeout=5.0)
        assert cancel["bid"] == first.begin["bid"]

        second = DownloadStub(connector, body, window=2560)
        task = asyncio.create_task(second.run())
        resumed = await client.get(down_path(bid="second-run"), token=device.token,
                                   headers={"Range": f"bytes={len(received)}-"},
                                   timeout=20)
        await task

        assert resumed.status == 206, resumed.text
        assert resumed.raw == body[len(received):]
        assert second.begin is not None and second.begin["offset"] == len(received)
    finally:
        await connector.ws.close()


async def test_an_old_connector_gets_501_on_download(
        client: support.Client, tenant: support.Tenant, device: support.Device) -> None:
    """连接器不认 ``fsGetBegin``：5 秒 ack 期限后回 501，而不是让手机一直等。"""
    connector = await open_agent(client, tenant)
    try:
        request = asyncio.create_task(
            client.get(down_path(bid="old-download"), token=device.token, timeout=15))
        try:
            begin = await connector.next(timeout=ACK_TIMEOUT_S)
            assert begin["t"] == "fsGetBegin", begin
            # 不 ack，也不回任何帧：中转应在 5 秒后自己放弃。
            response = await request
        finally:
            if not request.done():
                request.cancel()
        support.assert_error_envelope(response, status=501, code="file/unsupported")
    finally:
        await connector.ws.close()
