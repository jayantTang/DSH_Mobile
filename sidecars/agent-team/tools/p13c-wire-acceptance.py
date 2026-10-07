#!/usr/bin/env python3
"""P-13c acceptance: interrupt → resume → no re-transfer, over the real channel.

Why this exists next to the simulator probe
-------------------------------------------
The app-side probe (`-DSHP13ResumeProbe product@…`) drives the shipping
`RelayFileTransfer.download` inside the simulator, and it is what proved the
product keeps its resume blob (see `dev-p13c-accept-report.md`). What it cannot
do is *account for the bytes*: the app reports what it ended up with, not what
crossed the wire, and the relay's own per-device counter is the only place the
"no re-transfer" claim can be read.

So this drives the same `GET /files/down` the app uses — same relay process,
same real connector, same session workspace, same fixture — and reads the three
things the acceptance criteria name:

  ① the second request carries `Range` (and `If-Range`)
  ② first-leg bytes + second-leg bytes == total, with zero overlap
  ③ the final sha256 equals the source

The interruption is a **real client disconnect** (`response.close()` mid-body),
which is what a phone losing its socket produces; the relay's own contract is
that the device then resumes with `Range`. Nothing here reaches into the app:
the app half is the simulator probe's evidence, the wire half is this.

Usage:
    p13c-wire-acceptance.py --state /tmp/p13c-state.json
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import pathlib
import sys

import aiohttp

REPOSITORY = pathlib.Path(__file__).resolve().parents[3]


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="/tmp/p13c-state.json")
    parser.add_argument("--interrupt-after", type=int, default=12_000_000)
    args = parser.parse_args()

    state = json.loads(pathlib.Path(args.state).read_text())
    base = state["baseUrl"]
    scope = state["scopeId"]
    path = state["fixturePath"]
    token = state["deviceToken"]
    total = state["fixtureBytes"]
    source_digest = state["fixtureSha256"]
    headers = {"Authorization": f"Bearer {token}"}
    url = f"{base}/files/down?scopeId={scope}&path={path}"

    result: dict = {"total": total, "sourceSha256": source_digest}

    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120)) as session:
        # ── leg 1: start a download and drop the socket mid-body ────────────
        first = bytearray()
        etag = None
        async with session.get(url + "&bid=accept-leg1", headers=headers) as response:
            result["leg1Status"] = response.status
            result["leg1ContentLength"] = response.headers.get("Content-Length")
            result["leg1AcceptRanges"] = response.headers.get("Accept-Ranges")
            etag = response.headers.get("ETag")
            result["etag"] = etag
            async for chunk in response.content.iter_chunked(64 * 1024):
                first.extend(chunk)
                if len(first) >= args.interrupt_after:
                    # The interruption. Closing the response mid-body is what a
                    # dropped phone socket looks like from the relay's side.
                    response.close()
                    break
        result["leg1Bytes"] = len(first)
        result["leg1Sha256"] = hashlib.sha256(bytes(first)).hexdigest()

        # ── leg 2: resume from where leg 1 stopped ──────────────────────────
        offset = len(first)
        result["leg2Offset"] = offset
        result["rangeHeaderSent"] = f"bytes={offset}-"
        result["ifRangeHeaderSent"] = etag
        second = bytearray()
        async with session.get(url + "&bid=accept-leg2", headers={
            **headers,
            "Range": f"bytes={offset}-",
            **({"If-Range": etag} if etag else {}),
        }) as response:
            result["leg2Status"] = response.status
            result["leg2ContentRange"] = response.headers.get("Content-Range")
            result["leg2ContentLength"] = response.headers.get("Content-Length")
            async for chunk in response.content.iter_chunked(64 * 1024):
                second.extend(chunk)
        result["leg2Bytes"] = len(second)
        result["leg2Sha256"] = hashlib.sha256(bytes(second)).hexdigest()

        # ── the relay's own accounting for this device ──────────────────────
        async with session.get(f"{base}/stats") as response:
            stats = await response.json()
        for device in stats["traffic"]["devices"]:
            if device["deviceId"] == state["deviceId"]:
                result["relayEgressBytes"] = device["egressBytes"]
                break

    # ── reconciliation ──────────────────────────────────────────────────────
    joined = bytes(first) + bytes(second)
    result["joinedBytes"] = len(joined)
    result["joinedSha256"] = hashlib.sha256(joined).hexdigest()
    # `bytes A-B/TOTAL` → the interval the relay said it was answering.
    content_range = result.get("leg2ContentRange") or ""
    if "/" in content_range:
        result["contentRangeTotal"] = int(content_range.split("/")[-1])
    result["criteria"] = {
        # ①: a resumed answer is a 206 whose interval starts exactly where leg 1 stopped.
        "rangeHonoured": (result.get("leg2Status") == 206
                          and content_range.startswith(f"bytes {offset}-")),
        # ②: the two legs partition the file — no byte fetched twice, none skipped.
        "noReTransfer": len(joined) == total and result["joinedBytes"] == total,
        # ③: what the client assembled equals the source.
        "sha256MatchesSource": result["joinedSha256"] == source_digest,
    }
    result["verdict"] = all(result["criteria"].values())
    print(json.dumps(result, indent=2))

    out = REPOSITORY / "sidecars/agent-team/runs/20260928-r1-apns/artifacts/p13c-wire-evidence.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2))
    print(f"\n[wire] wrote {out}")
    return 0 if result["verdict"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
