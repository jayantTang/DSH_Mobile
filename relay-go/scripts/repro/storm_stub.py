#!/usr/bin/env python3
"""重复连接风暴的桩连接器（M7 验收用）。

一个进程里跑两个 agent：

* **storm**：每秒开一条新的 `/link/agent` 连接，**不关旧连接**，也从不发 hostStatus。
  这正是 2026-10-23 两次回滚里那个异常连接器的可观察形态：中转每接受一条新连接
  就顶掉旧的（4001），连接器把会话结束当成「连接成功」并把退避归零，于是每秒重连。
* **healthy**：正常连接一次，立刻上报 connectorVersion/hostVersion，之后每秒发一个
  DLP ping 并等 pong，同时回答中转的 ping。用来验证「其他 agent 不受风暴影响」。

输出一份 JSON 摘要（--out），字段：
  attempts / accepted / refused / errors / statuses（storm）
  pongs / relayPings / closes / connectedSeconds（healthy）

用法（由 repro_reconnect_storm.sh 调起）：
  python3 storm_stub.py --base http://127.0.0.1:18887 \
      --storm-id agt_x --storm-secret s1 --healthy-id agt_y --healthy-secret s2 \
      --seconds 30 --out /tmp/summary.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from typing import Any

import aiohttp

#: 单条连接建立的上限；中转的准入等待默认 1.5 秒，10 秒足够区分「慢」与「挂死」。
CONNECT_TIMEOUT_S = 10.0
#: 健康 agent 的心跳间隔。
HEALTHY_PING_INTERVAL_S = 1.0
#: storm 的重连间隔（验收口径：每秒一次）。
STORM_RECONNECT_INTERVAL_S = 1.0


def agent_url(base: str, agent_id: str) -> str:
    return f"{base}/link/agent?agentId={agent_id}"


async def storm_agent(session: aiohttp.ClientSession, base: str, agent_id: str,
                      secret: str, seconds: float, summary: dict[str, Any]) -> None:
    """每秒开一条新连接并保留上一条，直到时间用完。"""
    deadline = time.monotonic() + seconds
    sockets: list[aiohttp.ClientWebSocketResponse] = []
    headers = {"Authorization": f"Bearer {secret}"}
    while time.monotonic() < deadline:
        summary["attempts"] += 1
        try:
            socket = await asyncio.wait_for(
                session.ws_connect(agent_url(base, agent_id), headers=headers,
                                   timeout=CONNECT_TIMEOUT_S),
                timeout=CONNECT_TIMEOUT_S,
            )
            sockets.append(socket)
            summary["accepted"] += 1
        except aiohttp.WSServerHandshakeError as error:  # 429：被准入策略拒绝
            summary["refused"] += 1
            key = str(error.status)
            summary["statuses"][key] = summary["statuses"].get(key, 0) + 1
        except Exception:  # 连接被重置/超时：也算一次被挡住的尝试
            summary["errors"] += 1
        await asyncio.sleep(STORM_RECONNECT_INTERVAL_S)
    for socket in sockets:
        try:
            await socket.close()
        except Exception:
            pass


async def healthy_agent(session: aiohttp.ClientSession, base: str, agent_id: str,
                        secret: str, seconds: float, summary: dict[str, Any]) -> None:
    """正常连接、上报版本、保持心跳；结束时报告 pong 与关闭次数。"""
    headers = {"Authorization": f"Bearer {secret}"}
    started = time.monotonic()
    try:
        socket = await asyncio.wait_for(
            session.ws_connect(agent_url(base, agent_id), headers=headers,
                               timeout=CONNECT_TIMEOUT_S),
            timeout=CONNECT_TIMEOUT_S,
        )
    except Exception:
        summary["healthyConnectFailed"] = True
        return
    await socket.send_json({
        "t": "hostStatus",
        "info": {"online": True, "agentId": agent_id,
                 "version": "repro-storm-stub", "hostVersion": "repro-1"},
    })

    async def reader() -> None:
        async for message in socket:
            if message.type == aiohttp.WSMsgType.TEXT:
                try:
                    frame = json.loads(message.data)
                except Exception:
                    continue
                kind = frame.get("t")
                if kind == "pong":
                    summary["pongs"] += 1
                elif kind == "ping":
                    summary["relayPings"] += 1
                    await socket.send_json({"t": "pong", "ts": frame.get("ts")})
            elif message.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.CLOSE,
                                  aiohttp.WSMsgType.ERROR):
                summary["closes"] += 1
                return

    reader_task = asyncio.create_task(reader())
    deadline = time.monotonic() + seconds
    sequence = 0
    while time.monotonic() < deadline and not reader_task.done():
        sequence += 1
        try:
            await socket.send_json({"t": "ping", "ts": sequence})
        except Exception:
            summary["closes"] += 1
            break
        await asyncio.sleep(HEALTHY_PING_INTERVAL_S)
    summary["connectedSeconds"] = round(time.monotonic() - started, 1)
    reader_task.cancel()
    await asyncio.gather(reader_task, return_exceptions=True)
    if not socket.closed:
        try:
            await socket.close()
        except Exception:
            pass


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="中转 HTTP 根地址")
    parser.add_argument("--storm-id", required=True)
    parser.add_argument("--storm-secret", required=True)
    parser.add_argument("--healthy-id", required=True)
    parser.add_argument("--healthy-secret", required=True)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    storm: dict[str, Any] = {"attempts": 0, "accepted": 0, "refused": 0,
                             "errors": 0, "statuses": {}}
    healthy: dict[str, Any] = {"pongs": 0, "relayPings": 0, "closes": 0,
                               "connectedSeconds": 0.0}
    async with aiohttp.ClientSession() as session:
        await asyncio.gather(
            storm_agent(session, args.base, args.storm_id, args.storm_secret,
                        args.seconds, storm),
            healthy_agent(session, args.base, args.healthy_id, args.healthy_secret,
                          args.seconds, healthy),
        )
    payload = {"storm": storm, "healthy": healthy}
    text = json.dumps(payload, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
