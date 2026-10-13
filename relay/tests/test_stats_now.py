"""`GET /stats` 的 `now` 字段（spec 020 / contracts/stats-now.md）。

诊断包要把中转日志、连接器流水与手机阶段对齐，而三侧时钟不同源。`now` 就是那次对齐的
参照点；它必须（1）在，（2）是整数毫秒，（3）与同一响应里的其它字段同源——所以取值只在
handler 里发生一次，这条用例用"两次采样必须能算出合理偏移"来钉住它。
"""

from __future__ import annotations

import time

import pytest


async def test_stats_carries_now_as_epoch_milliseconds(client):
    response = await client.get("/stats")
    assert response.status == 200
    body = await response.json()
    assert "now" in body, "静默丢掉 now 会让三侧时钟对不上，诊断包只能分节输出"
    assert isinstance(body["now"], int) and body["now"] > 0
    # 与客户端时钟的偏差应当在"一次请求"的量级内（服务器与本机在测试里是同一台）。
    assert abs(body["now"] - int(time.time() * 1000)) < 60_000


async def test_stats_keeps_every_pre_existing_field(client):
    """`now` 是**只增**字段：既有字段一个不少，取值域也不变。"""
    body = await (await client.get("/stats")).json()
    assert body["ok"] is True
    assert set(body) >= {"ok", "version", "now", "limits", "load", "traffic", "snapshot", "today"}
    assert set(body["load"]) == {"agents", "devices"}
    assert {"maxFrameBytes", "queueDepth", "agentQueueDepth", "maxDevicesPerAgent"} <= set(body["limits"])


async def test_now_is_sampled_once_per_response(client):
    """两次采样算出的偏移不应随采样顺序漂移（每字段各取一次就会出现这种漂移）。"""
    first = (await (await client.get("/stats")).json())["now"]
    before = int(time.time() * 1000)
    second = (await (await client.get("/stats")).json())["now"]
    after = int(time.time() * 1000)
    assert first <= second
    assert before - 1_000 <= second <= after + 1_000, "now 必须落在本次请求的窗口内"


@pytest.mark.parametrize("path", ["/stats"])
async def test_now_does_not_change_the_html_view(client, path):
    """HTML 视图复用同一份 payload，`now` 不该把它弄坏。"""
    response = await client.get(path, headers={"Accept": "text/html"})
    assert response.status == 200
    assert response.content_type.startswith("text/html")
