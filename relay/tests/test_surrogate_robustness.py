"""落单代理项（被切开的 emoji）不许打断转发——2026-10-17 生产事故的回归测试。

事故经过：连接器送来的一帧里含一个落单的 UTF-16 代理项（流式输出把 emoji 切成了
两半），中转 `text.encode("utf-8")` 抛 `UnicodeEncodeError`，整个 agent 链路断开；
手机重连后连接器重放同一帧，再崩一次。用户侧表现为一直"连接中"，24 小时 143 次。

这里锁住四件事：

1. `dlp.prepare_outbound` 修好坏字符、按修好后的字节计数，且干净文本走零开销快路径。
2. 转发链路遇到坏帧照常送达（坏字符变 U+FFFD），之后连接仍然可用。
3. 设备写入器的分片路径（> `_CHUNK_CHARS`）同样不抛，按真正发出的字节记账。
4. 坏字符会被记进监控（`trailingChars` 就是定位上游根因的线索）。
"""

from __future__ import annotations

import asyncio
import json
import logging

import pytest

import dlp
import hub as hub_module
import monitor as monitor_module
from hub import Limits

#: 一个落单的高代理项：真实来源是被切开的一半 emoji（😀 = \ud83d\ude00）。
LONE_HIGH = "\ud83d"
LONE_LOW = "\ude00"


# ── 单元：dlp.prepare_outbound ──────────────────────────────────────────────

def test_prepare_outbound_repairs_a_lone_surrogate_and_counts_what_is_sent():
    text = '{"t":"item","payload":{"text":"一半的 emoji ' + LONE_HIGH + '"}}'
    clean, size, damage = dlp.prepare_outbound(text)

    assert LONE_HIGH not in clean
    assert dlp.REPLACEMENT_CHARACTER in clean
    assert size == len(clean.encode("utf-8")), "计费必须等于真正发出去的字节"
    assert damage is not None
    assert (damage.count, damage.kinds) == (1, "high")
    assert clean[damage.first_index] == dlp.REPLACEMENT_CHARACTER
    # 位置口径：坏字符是帧里第几个字符、后面还剩多少——排障要的就是这两个数。
    assert damage.first_index + damage.trailing_chars + 1 == len(clean)
    assert dlp.SURROGATE_PATTERN.search(damage.context) is None


def test_low_surrogate_and_mixed_kinds_are_reported():
    _clean, _size, damage = dlp.prepare_outbound(f"a{LONE_LOW}b{LONE_HIGH}c{LONE_LOW}")
    assert damage is not None
    assert (damage.count, damage.kinds) == (3, "mixed")
    assert damage.first_index == 1


def test_clean_text_takes_the_fast_path_and_keeps_its_byte_count():
    text = '{"t":"item","payload":{"text":"普通中文 + 😀 完整 emoji"}}'
    clean, size, damage = dlp.prepare_outbound(text)
    assert clean is text, "干净文本应该原样返回，不多一次分配"
    assert damage is None
    assert size == len(text.encode("utf-8"))


def test_utf8_len_never_raises_on_broken_text():
    assert dlp.utf8_len("ok") == 2
    assert dlp.utf8_len("x" + LONE_HIGH) == len("x\ufffd".encode("utf-8"))


def test_parse_frame_keeps_the_damage_visible():
    """上游确实会送来这种 JSON：`\\ud83d` 这种没有配对的转义是合法 JSON。"""
    frame = dlp.parse_frame('{"t":"item","id":"1","payload":{"text":"a\\ud83d"}}')
    assert dlp.SURROGATE_PATTERN.search(dlp.encode_frame(frame)) is not None


# ── 端到端：经由中转转发 ────────────────────────────────────────────────────

async def _open_pair(client, provisioned):
    response = await client.post("/pair/claim", json={
        "pairCode": provisioned["code"]["code"], "deviceName": "iPhone",
        "deviceModel": "iPhone17,1", "appVersion": "1.0",
    })
    assert response.status == 200, await response.text()
    device = await response.json()
    device_ws = await client.ws_connect(f"/link/device?agentId={device['agentId']}",
                                        headers={"Authorization": f"Bearer {device['deviceToken']}"})
    agent_ws = await client.ws_connect(f"/link/agent?agentId={provisioned['agent']['agentId']}",
                                       headers={"Authorization": f"Bearer {provisioned['agent']['agentSecret']}"})
    return device_ws, device, agent_ws


async def _recv_json(ws, timeout=3.0) -> dict:
    message = await asyncio.wait_for(ws.receive(), timeout)
    assert message.type.name == "TEXT", f"unexpected frame: {message}"
    return json.loads(message.data)


async def test_a_frame_with_a_split_emoji_is_delivered_repaired(client, provisioned):
    device_ws, device, agent_ws = await _open_pair(client, provisioned)
    await _recv_json(device_ws)                       # offline 状态
    await _recv_json(agent_ws)                        # deviceAttach
    await _recv_json(device_ws)                       # 中转发的 online 状态

    broken = {"t": "item", "id": "m1", "deviceId": device["deviceId"],
              "payload": {"text": "答案一半就断了 " + LONE_HIGH}}
    # 用 ensure_ascii=True 才发得出去：落单代理项作为 `\ud83d` 转义上线路。
    await agent_ws.send_str(json.dumps(broken))

    forwarded = await _recv_json(device_ws)
    assert forwarded["id"] == "m1"
    assert forwarded["payload"]["text"] == "答案一半就断了 " + dlp.REPLACEMENT_CHARACTER
    assert "deviceId" not in forwarded, "中转自己的寻址键不该到设备"

    await agent_ws.close()
    await device_ws.close()


async def test_the_link_keeps_working_after_bad_frames(client, provisioned):
    """一次坏帧不能让这条链路死掉：事故里就是"断一次、重连、再断一次"的循环。"""
    device_ws, device, agent_ws = await _open_pair(client, provisioned)
    await _recv_json(device_ws)                       # offline 状态
    await _recv_json(agent_ws)                        # deviceAttach
    await _recv_json(device_ws)                       # online 状态

    for index in range(5):
        await agent_ws.send_str(json.dumps({
            "t": "item", "id": f"bad{index}", "deviceId": device["deviceId"],
            "payload": {"text": f"第 {index} 条 " + LONE_HIGH},
        }))
        assert (await _recv_json(device_ws))["id"] == f"bad{index}"

    await agent_ws.send_str(json.dumps({"t": "end", "id": "done", "deviceId": device["deviceId"]}))
    assert (await _recv_json(device_ws))["t"] == "end", "坏帧之后链路必须仍然可用"

    await agent_ws.close()
    await device_ws.close()


async def test_the_broken_frame_is_reported_to_the_monitor(client, provisioned, tmp_path):
    """坏字符必须留下可排障的记录：帧类型、位置、帧尾还剩多少。"""
    app_monitor = monitor_module.IncidentMonitor(alert_dir=tmp_path / "alerts")
    import relay as relay_module
    from store import Store

    store = Store(str(tmp_path / "state.db"))
    try:
        account = store.create_account("monitored")
        agent = store.register_agent(account["accountId"], "mac")
        code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
        # 这里要自己建 app，才能把监控换成指到 tmp_path 的那个。
        app = relay_module.create_app(store=store, limits=Limits(queue_depth=8),
                                      pair_ttl_ms=60_000, monitor=app_monitor)
        from aiohttp.test_utils import TestClient, TestServer
        async with TestClient(TestServer(app)) as monitor_client:
            response = await monitor_client.post("/pair/claim", json={
                "pairCode": code["code"], "deviceName": "iPhone",
                "deviceModel": "iPhone17,1", "appVersion": "1.0",
            })
            device = await response.json()
            device_ws = await monitor_client.ws_connect(
                f"/link/device?agentId={device['agentId']}",
                headers={"Authorization": f"Bearer {device['deviceToken']}"})
            agent_ws = await monitor_client.ws_connect(
                f"/link/agent?agentId={agent['agentId']}",
                headers={"Authorization": f"Bearer {agent['agentSecret']}"})
            await _recv_json(device_ws)
            await _recv_json(agent_ws)
            await _recv_json(device_ws)

            await agent_ws.send_str(json.dumps({
                "t": "item", "id": "m1", "deviceId": device["deviceId"],
                "payload": {"text": "尾巴断了 " + LONE_HIGH},
            }))
            await _recv_json(device_ws)

            queue = (tmp_path / "alerts" / "alerts.jsonl").read_text(encoding="utf-8")
            records = [json.loads(line) for line in queue.splitlines() if line.strip()]
            assert len(records) == 1
            record = records[0]
            assert record["key"] == "surrogate:unpaired"
            assert record["details"]["frameType"] == "item"
            assert record["details"]["kinds"] == "high"
            # 帧尾只剩 JSON 收尾（`"}}`）——也就是坏字符卡在正文最后，正是"被分片
            # 截断"的形态。深在中间（trailingChars 以千计）则更像上游自己拼错了。
            assert record["details"]["trailingChars"] <= 4
            await agent_ws.close()
            await device_ws.close()
    finally:
        store.close()


# ── 写入器：分片路径与记账 ──────────────────────────────────────────────────

class FakeSocket:
    """只拦住 ``send_str`` 的假 socket（写入器只需要这一个方法）。"""

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send_str(self, text: str) -> None:
        self.sent.append(text)

    async def close(self, code: int = 1000, message: bytes = b"") -> None:
        return None


def _device_link(limits: Limits | None = None) -> tuple[hub_module.DeviceLink, FakeSocket]:
    socket = FakeSocket()
    link = hub_module.DeviceLink(socket, device={
        "deviceId": "dev_x", "agentId": "agt_x", "name": "iPhone", "model": "iPhone17,1",
        "appVersion": "1.0", "accountId": "acc_x",
    }, logger=logging.getLogger("test.hub"), limits=limits or Limits())
    return link, socket


async def test_the_writer_repairs_a_surrogate_in_the_chunked_path():
    """分片路径上坏字符同样不能抛：一次性发大帧时它正好落在某个分片里。"""
    link, socket = _device_link()
    size = hub_module._CHUNK_CHARS  # noqa: SLF001 - 测试要看的就是这个边界
    text = "a" * (size - 1) + LONE_HIGH + "b" * 10
    await link._send(text)  # noqa: SLF001

    joined = "".join(socket.sent)
    assert dlp.SURROGATE_PATTERN.search(joined) is None
    assert dlp.REPLACEMENT_CHARACTER in joined
    assert len(socket.sent) > 1, "超过 _CHUNK_CHARS 的帧必须分片发出"
    expected = len(joined.encode("utf-8"))
    assert link.egress_bytes == expected, "记账口径必须等于真正发出去的字节"


async def test_the_writer_does_not_raise_on_a_lone_low_surrogate():
    link, socket = _device_link()
    await link._send("x" + LONE_LOW)  # noqa: SLF001
    assert socket.sent == ["x" + dlp.REPLACEMENT_CHARACTER]
