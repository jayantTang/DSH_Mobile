"""下载途中断开是客户端行为，不是中转故障（24 小时告警降噪）。

2026-10-17 的 24 小时统计里，231 条 `Error handling request` 中有 4 条是
`ClientConnectionResetError @ api.py: files_down`：手机在下载途中关掉 App、切网或被系统
杀掉，aiohttp 在写正文时抛 `Cannot write to closing transport`，于是 aiohttp 记一条
ERROR + traceback，和真正的异常混在一起。这里锁住两件事：

1. 写正文时对端已经走了 → 不抛到 aiohttp（只记 DEBUG）；
2. 整条下载请求照常收尾（桥被放弃、连接器收到 cancel），不留下 ERROR 记录。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

import pytest
from aiohttp import web

import api as api_module
from test_files_down import FetchStub, claim_device, device_auth, down_url, drain, open_agent


class FakeResponse:
    """只有 ``write`` 一个关注的假响应。"""

    def __init__(self, error: BaseException | None = None) -> None:
        self.error = error
        self.written: list[bytes] = []

    async def write(self, data: bytes) -> None:
        if self.error is not None:
            raise self.error
        self.written.append(data)


async def test_write_piece_sends_the_bytes():
    response = FakeResponse()
    assert await api_module._write_piece(response, b"abc", "bid-1") is True
    assert response.written == [b"abc"]


@pytest.mark.parametrize("error", [ConnectionResetError("gone"), BrokenPipeError("gone")])
async def test_write_piece_treats_a_departed_client_as_debug(error, caplog):
    response = FakeResponse(error)
    with caplog.at_level(logging.DEBUG, logger="relay"):
        assert await api_module._write_piece(response, b"abc", "bid-1") is False
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING], \
        "客户端断开不该产生 WARNING/ERROR"
    assert any("bid-1" in record.getMessage() for record in caplog.records)


async def test_a_client_that_vanishes_mid_body_leaves_no_error(client, provisioned,
                                                               monkeypatch, caplog):
    agent_ws = await open_agent(client, provisioned)
    device = await claim_device(client, provisioned)
    await drain(agent_ws)

    body = b"y" * (2 << 20)                      # 2 MB，跨多个桥窗口
    stub = FetchStub(agent_ws, body, window=64 * 1024)
    run = asyncio.create_task(stub.run())

    writes = {"count": 0}
    original = web.StreamResponse.write

    async def flaky_write(self, data):            # noqa: ANN001 - 签名跟 aiohttp 一致
        writes["count"] += 1
        if writes["count"] >= 2:
            raise ConnectionResetError("Cannot write to closing transport")
        return await original(self, data)

    monkeypatch.setattr(web.StreamResponse, "write", flaky_write)

    with caplog.at_level(logging.DEBUG, logger="relay"):
        response = await client.get(
            down_url(device, scopeId="s1", path="gone.bin", bid="bid-gone"),
            headers=device_auth(device))
        with contextlib.suppress(Exception):
            # 声明的总长没写完：客户端读到短包是预期的（和真断线同一个形态）。
            await asyncio.wait_for(response.read(), 5)
        await asyncio.wait_for(run, 5)
        await asyncio.sleep(0)

    assert writes["count"] >= 2, "用例没打到写着写着断开那一刻"
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR], \
        f"客户端断开不该留下 ERROR：{[r.getMessage() for r in caplog.records if r.levelno >= logging.ERROR]}"
    # 收尾照旧：桥必须被放弃（否则连接器会一直往一个没人读的 run 里送窗口）。
    assert not client.app["hub"]._bridges, "对端走了之后桥还挂着"  # noqa: SLF001
    await agent_ws.close()
