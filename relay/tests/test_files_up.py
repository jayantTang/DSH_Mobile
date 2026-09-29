"""``PUT /files/up``: streaming a large upload through the relay (R-1 C-17).

The relay is the HTTP endpoint but not a storage hop — it reads the request body
and pumps it over the connector's WebSocket, keeping nothing. So the tests ask
two different questions:

* does the byte stream arrive complete, in order, under the right ``bid``; and
* does every way it can go wrong answer **promptly** with something the phone can
  act on (503 / 501 / 409), rather than hanging?

The connector is a stub socket throughout: no Node process, no disk.
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


class ConnectorStub:
    """Plays the connector's half: collects chunks and replies like the real one."""

    def __init__(self, agent_ws, *, ack=True, done=True, error=None,
                 done_path="/home/u/.dsh/inbox/s1/big.bin"):
        self.ws = agent_ws
        self.ack = ack
        self.done = done
        self.error = error
        self.done_path = done_path
        self.begins: list[dict] = []
        self.chunks: list[bytes] = []
        self.ends: list[dict] = []
        self.other: list[dict] = []

    async def run(self, *, until_end=True) -> None:
        while True:
            frame = await recv_json(self.ws, timeout=15.0)
            kind = frame.get("t")
            if kind == "fsPutBegin":
                self.begins.append(frame)
                if self.error:
                    # 连接器在 begin 就拒绝：不会再有 chunk 了，这里必须返回，
                    # 否则 stub 会一直等一个永远不来的帧。
                    await self.ws.send_json({"t": "fsErr", "bid": frame["bid"],
                                             "code": self.error[0], "message": self.error[1]})
                    return
                if self.ack:
                    await self.ws.send_json({"t": "fsPutAck", "bid": frame["bid"], "received": 0})
            elif kind == "fsPutChunk":
                self.chunks.append(base64.b64decode(frame["data"]))
            elif kind == "fsPutEnd":
                self.ends.append(frame)
                if self.error:
                    await self.ws.send_json({"t": "fsErr", "bid": frame["bid"],
                                             "code": self.error[0], "message": self.error[1]})
                elif self.done:
                    await self.ws.send_json({
                        "t": "fsPutDone", "bid": frame["bid"],
                        "path": self.done_path, "bytes": sum(len(p) for p in self.chunks),
                    })
                if until_end:
                    return
            else:
                self.other.append(frame)


def upload_url(device, **params) -> str:
    query = "&".join(f"{key}={value}" for key, value in params.items())
    return f"/files/up?{query}"


async def test_a_complete_upload_arrives_whole_under_one_bid(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws)

    body = bytes(range(256)) * 5000          # 1.28 MB: spans bridge chunks
    task = asyncio.create_task(stub.run())
    response = await client.put(
        upload_url(device, sessionId="s1", name="big.bin", bytes=len(body), bid="bid-1"),
        data=body, headers={"Authorization": f"Bearer {device['deviceToken']}"})
    await task

    assert response.status == 200, await response.text()
    payload = await response.json()
    assert payload["ok"] is True
    assert payload["bytes"] == len(body)

    # 一次 begin、一路 chunk、一次 end，**bid 一致**。
    assert [frame["bid"] for frame in stub.begins] == ["bid-1"]
    assert [frame["bid"] for frame in stub.ends] == ["bid-1"]
    assert stub.begins[0]["sessionId"] == "s1" and stub.begins[0]["name"] == "big.bin"
    assert stub.begins[0]["bytes"] == len(body)
    # 拼起来与原文件逐字节相同，且 seq 连续。
    assert b"".join(stub.chunks) == body
    await agent_ws.close()


async def test_the_bridge_chunks_at_one_megabyte(client, provisioned):
    """1 MB 原始字节／片（base64 后 ~1.33 MB，远低于 32 MB 帧上限）。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws, done_path="/tmp/x")

    sizes: list[int] = []

    async def watch():
        while True:
            frame = await recv_json(agent_ws, timeout=15.0)
            if frame.get("t") == "fsPutBegin":
                await agent_ws.send_json({"t": "fsPutAck", "bid": frame["bid"], "received": 0})
            elif frame.get("t") == "fsPutChunk":
                sizes.append(len(base64.b64decode(frame["data"])))
            elif frame.get("t") == "fsPutEnd":
                await agent_ws.send_json({"t": "fsPutDone", "bid": frame["bid"], "path": "/tmp/x",
                                          "bytes": sum(sizes)})
                return

    task = asyncio.create_task(watch())
    body = b"x" * (3 * 1024 * 1024 + 7)
    response = await client.put(
        upload_url(device, sessionId="s1", name="big.bin", bytes=len(body), bid="bid-2"),
        data=body, headers={"Authorization": f"Bearer {device['deviceToken']}"})
    await task

    assert response.status == 200, await response.text()
    assert sizes[:-1] == [1 << 20, 1 << 20, 1 << 20], f"分片大小不对：{sizes}"
    assert sizes[-1] == 7
    assert sum(sizes) == len(body)
    await agent_ws.close()


async def test_an_offline_agent_is_refused_immediately(client, provisioned):
    """不在线立刻 503——不排队、不落盘。"""
    device = await claim_device(client, provisioned)
    response = await client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=4, bid="bid-3"),
        data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"})
    assert response.status == 503
    assert (await response.json())["error"]["code"] == "host/offline"


async def test_an_old_connector_that_never_acks_gets_a_501(client, provisioned, monkeypatch):
    """旧连接器静默忽略新帧：限时等 ack，超时回 501「连接器版本过旧」。

    测试注入一个很短的超时，不真等 5 秒。
    """
    monkeypatch.setattr(hub_module.FileBridge, "wait_ack",
                        lambda self, timeout: asyncio.sleep(0, result=False))
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    response = await client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=4, bid="bid-4"),
        data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"})
    assert response.status == 501
    error = (await response.json())["error"]
    assert error["code"] == "file/unsupported"
    assert "连接器版本过旧" in error["message"]
    await agent_ws.close()


async def test_a_connector_that_refuses_the_begin_is_reported_not_hung(client, provisioned):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws, error=("file/rejected", "sessionId is required"))
    task = asyncio.create_task(stub.run(until_end=False))

    response = await asyncio.wait_for(client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=4, bid="bid-5"),
        data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"}), 10)
    await task
    assert response.status == 409
    error = (await response.json())["error"]
    assert error["code"] == "file/rejected" and "sessionId" in error["message"]
    await agent_ws.close()


async def test_an_agent_that_drops_mid_upload_ends_the_request_instead_of_hanging(client, provisioned):
    """连接器中途掉线 → HTTP 立刻以错误结束，**不挂住**。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    async def ack_then_die():
        frame = await recv_json(agent_ws)
        assert frame["t"] == "fsPutBegin"
        await agent_ws.send_json({"t": "fsPutAck", "bid": frame["bid"], "received": 0})
        # 传了一片之后把连接器整条链路拉掉。
        await recv_json(agent_ws)
        await agent_ws.close()

    task = asyncio.create_task(ack_then_die())
    body = b"y" * (2 << 20)
    response = await asyncio.wait_for(client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=len(body), bid="bid-6"),
        data=body, headers={"Authorization": f"Bearer {device['deviceToken']}"}), 15)
    await task
    assert response.status == 409
    assert (await response.json())["error"]["code"] == "host/offline"


async def test_a_body_shorter_than_declared_is_refused(client, provisioned):
    """声明的字节数收不满 → 400，且**不会**发 fsPutEnd（连接器不该去落一个半截文件）。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    seen: list[str] = []

    async def watch():
        # relay 在读不满时会直接回 400，不会再发 end；这里读到 begin 就够，
        # 剩下的用超时收尾（不是"等一个永远不来的帧"）。
        try:
            while True:
                frame = await recv_json(agent_ws, timeout=1.0)
                seen.append(frame["t"])
                if frame.get("t") == "fsPutBegin":
                    await agent_ws.send_json({"t": "fsPutAck", "bid": frame["bid"], "received": 0})
        except asyncio.TimeoutError:
            return

    task = asyncio.create_task(watch())
    response = await client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=100, bid="bid-7"),
        data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"})
    await task
    assert response.status == 400
    assert (await response.json())["error"]["code"] == "request/bytes"
    assert "fsPutEnd" not in seen, f"字节数没对齐却发了结束帧：{seen}"
    await agent_ws.close()


@pytest.mark.parametrize("missing", ["sessionId", "name", "bid"])
async def test_incomplete_parameters_are_refused(client, provisioned, missing):
    device = await claim_device(client, provisioned)
    params = {"sessionId": "s1", "name": "b.bin", "bid": "bid-8", "bytes": 4}
    params.pop(missing)
    response = await client.put(upload_url(device, **params), data=b"abcd",
                                headers={"Authorization": f"Bearer {device['deviceToken']}"})
    assert response.status == 400


async def test_a_bad_byte_count_is_refused(client, provisioned):
    device = await claim_device(client, provisioned)
    for value in ("", "lots", "-1"):
        response = await client.put(
            upload_url(device, sessionId="s1", name="b.bin", bytes=value, bid="bid-9"),
            data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"})
        assert response.status == 400, f"bytes={value!r} 应该被拒"


async def test_upload_needs_a_valid_device_token(client, provisioned):
    for headers in ({}, {"Authorization": "Bearer dt_nope"}):
        response = await client.put(
            upload_url({"deviceId": "x"}, sessionId="s1", name="b.bin", bytes=4, bid="b"),
            data=b"abcd", headers=headers)
        assert response.status == 401


async def test_the_same_bid_twice_is_accepted_and_overwrites(client, provisioned):
    """同一个文件重试复用同一个 bid：连接器按 bid 覆盖写，天然幂等。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws, done_path="/tmp/same")

    for body in (b"first", b"second-longer"):
        task = asyncio.create_task(stub.run())
        response = await client.put(
            upload_url(device, sessionId="s1", name="b.bin", bytes=len(body), bid="same"),
            data=body, headers={"Authorization": f"Bearer {device['deviceToken']}"})
        await task
        assert response.status == 200, await response.text()

    assert [frame["bid"] for frame in stub.begins] == ["same", "same"]
    await agent_ws.close()


async def test_the_bridge_table_is_cleaned_up_after_every_upload(client, provisioned):
    """请求结束就把相关性表里的那条删掉，不留垃圾。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws, done_path="/tmp/x")
    task = asyncio.create_task(stub.run())
    response = await client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=4, bid="bid-clean"),
        data=b"abcd", headers={"Authorization": f"Bearer {device['deviceToken']}"})
    await task
    assert response.status == 200
    assert client.app["hub"]._bridges == {}
    await agent_ws.close()


async def test_other_requests_still_work_while_an_upload_streams(client, provisioned):
    """上传在跑的时候，relay 的其它面照常应答（读请求体不阻塞事件循环）。"""
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)
    stub = ConnectorStub(agent_ws, done_path="/tmp/x")
    task = asyncio.create_task(stub.run())

    body = b"z" * (4 << 20)
    upload = asyncio.create_task(client.put(
        upload_url(device, sessionId="s1", name="b.bin", bytes=len(body), bid="bid-live"),
        data=body, headers={"Authorization": f"Bearer {device['deviceToken']}"}))
    await asyncio.sleep(0.05)
    health = await client.get("/healthz")
    assert health.status == 200
    assert (await upload).status == 200
    await task
    await agent_ws.close()
