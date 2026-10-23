#!/usr/bin/env python3
"""M7.5 诊断面黑盒探针：/debug/conns 的快照、脱敏与拆除。

用法（中转已经由调用方起好，且 --db 指向同一个库）：

    .venv/bin/python scripts/repro/observability_smoke.py \
        --base http://127.0.0.1:18087 --db /tmp/relay/state.db --relay ./bin/dsh-relay

它做四件事：
  1. 经 admin 子命令建账户/电脑/配对码，再走 HTTP 配对拿设备令牌；
  2. 连一条 agent WS 并在 hostStatus 里上报两段版本；
  3. GET /debug/conns，断言 agent/device 行的 remote、版本、时间、队列字段；
  4. 断开后断言快照清空；全程断言响应里没有令牌/密钥。

退出码：0 = 全部断言通过；1 = 断言失败（打印差在哪）。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys

import aiohttp


def admin(relay: str, db: str, *args: str) -> dict:
    result = subprocess.run(
        [relay, "admin", "--db", db, *args],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"admin {' '.join(args)} 失败：{result.stderr or result.stdout}")
    return json.loads(result.stdout)


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--relay", required=True)
    options = parser.parse_args()
    base = options.base.rstrip("/")

    account = admin(options.relay, options.db, "account-create", "--name", "observability")
    agent = admin(options.relay, options.db, "agent-register",
                  "--account", account["accountId"], "--name", "DSH-Obs")
    minted = admin(options.relay, options.db, "code-mint", "--agent", agent["agentId"])

    async with aiohttp.ClientSession() as session:
        async with session.post(f"{base}/pair/claim", json={
            "pairCode": minted["code"], "deviceName": "DSH-Obs-Phone",
        }) as response:
            assert response.status == 200, await response.text()
            claimed = await response.json()

        ws_agent = f"{base.replace('http', 'ws')}/link/agent?agentId={agent['agentId']}"
        ws_device = f"{base.replace('http', 'ws')}/link/device?agentId={agent['agentId']}"
        headers_agent = {"Authorization": f"Bearer {agent['agentSecret']}"}
        headers_device = {"Authorization": f"Bearer {claimed['deviceToken']}"}

        async with session.ws_connect(ws_agent, headers=headers_agent) as agent_socket:
            await agent_socket.send_json({
                "t": "hostStatus",
                "info": {"version": "0.6.6", "hostVersion": "9.9.9"},
            })
            await asyncio.sleep(0.05)

            async with session.ws_connect(ws_device, headers=headers_device) as device_socket:
                await asyncio.sleep(0.05)
                async with session.get(f"{base}/debug/conns") as response:
                    assert response.status == 200, await response.text()
                    snapshot = await response.json()
                    raw = json.dumps(snapshot, ensure_ascii=False)
                    for forbidden in ("as_", "dsh.device.", "secret", "token"):
                        assert forbidden not in raw.lower(), (
                            f"/debug/conns 泄露了 {forbidden!r}：{raw}")
                    assert len(snapshot["agents"]) == 1, snapshot
                    assert len(snapshot["devices"]) == 1, snapshot
                    agent_row = snapshot["agents"][0]
                    device_row = snapshot["devices"][0]
                    assert agent_row["agentId"] == agent["agentId"], agent_row
                    assert agent_row["connectorVersion"] == "0.6.6", agent_row
                    assert agent_row["hostVersion"] == "9.9.9", agent_row
                    assert agent_row["remote"].startswith("127.0.0.1:"), agent_row
                    assert agent_row["connectedAt"] > 0, agent_row
                    for key in ("lastInbound", "queueDepth", "controlDrops", "lastError"):
                        assert key in agent_row, (key, agent_row)
                    assert device_row["deviceId"] == claimed["deviceId"], device_row
                    assert device_row["agentId"] == agent["agentId"], device_row
                    assert device_row["remote"].startswith("127.0.0.1:"), device_row
                    print("snapshot:", json.dumps(snapshot, ensure_ascii=False))

                # 设备断开后，快照里不再有设备行。
                await device_socket.close()
            await asyncio.sleep(0.15)
            async with session.get(f"{base}/debug/conns") as response:
                after = await response.json()
                assert len(after["devices"]) == 0, after
                assert len(after["agents"]) == 1, after

        await asyncio.sleep(0.15)
        async with session.get(f"{base}/debug/conns") as response:
            final = await response.json()
            assert len(final["agents"]) == 0, final
            assert len(final["devices"]) == 0, final
            print("after disconnect:", json.dumps(final, ensure_ascii=False))

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
