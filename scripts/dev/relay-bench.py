"""Offline throughput probe for the relay hot path — no network, no real DB.

Feeds realistic DLP frames through ``RelayHub.route_from_*`` with loopback fake
sockets, so it measures exactly what a relayed frame costs in CPU: JSON decode,
validation, addressing, JSON re-encode. Run it against a candidate host to size
the relay:

    relay/.venv/bin/python scripts/dev/relay-bench.py
    relay/.venv/bin/python scripts/dev/relay-bench.py --images
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "relay"))

import dlp  # noqa: E402
from hub import Limits, RelayHub  # noqa: E402


class FakeStore:
    def touch_agent(self, *_a, **_k):
        return None


class FakeWS:
    """Counts bytes instead of writing them: the relay's own send cost stays out."""

    def __init__(self):
        self.bytes = 0
        self.frames = 0

    async def send_str(self, text):
        self.bytes += len(text.encode("utf-8"))
        self.frames += 1

    async def close(self, code=1000, message=b""):
        return None


async def bench(name, frames, *, rounds):
    hub = RelayHub(FakeStore(), limits=Limits())
    agent = await hub.attach_agent({"agentId": "a1", "accountId": "ac", "name": "pc"}, FakeWS())
    device = await hub.attach_device(
        {"deviceId": "d1", "agentId": "a1", "name": "iPhone", "model": "iPhone17,1"}, FakeWS())
    agent.start()
    device.start()
    # Settle the attach frames so the queues start empty.
    await asyncio.sleep(0)

    start = time.perf_counter()
    for _ in range(rounds):
        for frame in frames:
            await hub.route_from_device(device, frame)
            await hub.route_from_agent(agent, frame)
    elapsed = time.perf_counter() - start
    per_round = 2 * len(frames)          # both directions
    total = per_round * rounds
    payload = sum(len(dlp.encode_frame(f)) for f in frames) * rounds
    await hub.shutdown()
    print(f"{name:22s} {total / elapsed:>12,.0f} frames/s   "
          f"{payload / elapsed / 1e6:>8.1f} MB/s payload   ({total:,} frames)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=20_000)
    parser.add_argument("--images", action="store_true", help="also bench 2 MB base64 image frames")
    args = parser.parse_args()

    small = [{"t": "req", "id": "r1", "method": "session.follow", "args": {}, "deviceId": "d1"}]
    delta = [{"t": "item", "id": "s1", "deviceId": "d1",
              "value": {"type": "text-delta", "text": "adding the retry guard to the fetch loop "}}]
    snapshot = [{"t": "item", "id": "s1", "deviceId": "d1",
                 "value": {"type": "snapshot", "messages": [
                     {"role": "assistant", "content": "x" * 4000} for _ in range(10)]}}]

    asyncio.run(bench("unary req (small)", small, rounds=args.rounds))
    asyncio.run(bench("stream text delta", delta, rounds=args.rounds))
    asyncio.run(bench("40 KB snapshot item", snapshot, rounds=max(args.rounds // 20, 100)))
    if args.images:
        blob = base64.b64encode(os.urandom(2 * 1024 * 1024)).decode()
        image = [{"t": "res", "id": "i1", "deviceId": "d1", "value": {"data": blob}}]
        asyncio.run(bench("2 MB image (2.7 MB b64)", image, rounds=50))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
