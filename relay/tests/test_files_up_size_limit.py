"""U10：单文件超过 32 MB 会怎样（R-1 C-17）。

架构师把这标成**不确定点**：`relay.py:229` 把 `client_max_size` 设成了
`max_frame_bytes`（32 MB），那是给 WebSocket 帧定的上限，担心"大文件会被 413"。

**实测结论（2026-09-28，本机 aiohttp 3.14.3）：不会被 413。**
`PUT /files/up` 自己 `await request.content.readany()` 消费请求体，走的不是 aiohttp
那条"整段读进内存再交给 handler"的路，所以 `client_max_size` 在这条路上不生效——
32 MB + 64 KB 的 body 上传成功（HTTP 200），连接器收到全部字节、字节数一致。

所以阶段 3 甲第 4 条的 413 回落**在这条路上不会被触发**；回落仍然保留，因为它对
"老连接器"（501）与"agent 不在线"（503）有用，那两个分支在 `test_files_up.py` 里验过。

这条用例是钉住**今天实测到的行为**，不是钉住"我们以为的行为"：将来若改成让 aiohttp
预读 body，这里会变红，那时 App 侧的回落策略要跟着重新评估。
"""

from __future__ import annotations

import asyncio
import base64
import json

from aiohttp import WSMsgType

from conftest import agent_headers


async def claim_device(client, provisioned) -> dict:
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone",
        "deviceModel": "iPhone17,1", "appVersion": "1.0",
    })
    return await response.json()


async def drain(ws) -> None:
    try:
        while True:
            await asyncio.wait_for(ws.receive(), 0.2)
    except asyncio.TimeoutError:
        return


async def test_a_body_over_the_frame_limit_is_not_413(client, provisioned):
    """超过 32 MB 的 body 照常上传成功——`client_max_size` 在这条路上不生效。"""
    agent_ws = await client.ws_connect(f"/link/agent?agentId={provisioned['agent']['agentId']}",
                                       headers=agent_headers(provisioned["agent"]))
    await drain(agent_ws)
    device = await claim_device(client, provisioned)

    limit = client.app["limits"].max_frame_bytes
    over = limit + (64 << 10)          # 32 MB + 64 KB
    chunks: list[int] = []

    async def stub():
        while True:
            message = await asyncio.wait_for(agent_ws.receive(), 60)
            if message.type != WSMsgType.TEXT:
                continue
            frame = json.loads(message.data)
            kind = frame.get("t")
            if kind == "fsPutBegin":
                await agent_ws.send_json({"t": "fsPutAck", "bid": frame["bid"], "received": 0})
            elif kind == "fsPutChunk":
                chunks.append(len(base64.b64decode(frame["data"])))
            elif kind == "fsPutEnd":
                await agent_ws.send_json({"t": "fsPutDone", "bid": frame["bid"],
                                          "path": "/tmp/over", "bytes": sum(chunks)})
                return

    task = asyncio.create_task(stub())
    response = await asyncio.wait_for(client.put(
        f"/files/up?sessionId=s1&name=big.bin&bytes={over}&bid=bid-over",
        data=b"\0" * over,
        headers={"Authorization": f"Bearer {device['deviceToken']}"}), 90)
    await task

    assert response.status == 200, (
        f"超过 {limit} 字节的 body 得到 {response.status}（若这是 413，说明 aiohttp 的 "
        "client_max_size 重新生效了，App 侧的回落需要重新评估）")
    assert sum(chunks) == over, "桥接过去的字节数不对"
    await agent_ws.close()
