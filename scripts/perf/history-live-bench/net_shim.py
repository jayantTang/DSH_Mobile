"""Local WebSocket shim between a test client and the real relay.

It forwards DLP frames unchanged and applies a simple network profile:
one-way latency (RTT/2 + jitter) and a token-bucket-free serial bandwidth
delay proportional to frame size. Sizes and timestamps are logged as JSONL
so the caller can attribute bytes to each page.

Server side is plain ws://127.0.0.1:<port> so a command-line client needs no
certificate trust; the upstream hop is real TLS to the relay.
"""
import argparse, asyncio, json, random, time, sys, os
from aiohttp import web, ClientSession, WSMsgType

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--upstream", required=True, help="https://relay.example/prefix")
ap.add_argument("--rtt-ms", type=float, default=0)
ap.add_argument("--jitter-ms", type=float, default=0)
ap.add_argument("--down-kbps", type=float, default=0)
ap.add_argument("--up-kbps", type=float, default=0)
ap.add_argument("--log", required=True)
args = ap.parse_args()

logf = open(args.log, "a", buffering=1)
t_start = time.time()

def log(rec):
    rec["t"] = round((time.time() - t_start) * 1000, 1)
    logf.write(json.dumps(rec, separators=(",", ":")) + "\n")

def one_way_s(nbytes, up):
    base = (args.rtt_ms / 2.0) / 1000.0
    if args.jitter_ms:
        base += random.uniform(-args.jitter_ms, args.jitter_ms) / 2000.0
    base = max(0.0, base)
    kbps = args.up_kbps if up else args.down_kbps
    if kbps and kbps > 0:
        base += nbytes / (kbps * 1000 / 8.0)
    return base

async def handle(request):
    ws = web.WebSocketResponse(max_msg_size=0, heartbeat=None, autoping=True, compress=False)
    await ws.prepare(request)
    url = args.upstream.rstrip("/") + request.path_qs
    headers = {}
    auth = request.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    log({"ev": "open", "path": request.path_qs})
    try:
        async with ClientSession() as sess:
            async with sess.ws_connect(url, headers=headers, max_msg_size=0, heartbeat=None,
                                       autoping=True, compress=0) as up:
                async def pump(src, dst, is_up):
                    try:
                        async for msg in src:
                            if msg.type == WSMsgType.TEXT:
                                data = msg.data
                                await asyncio.sleep(one_way_s(len(data), is_up))
                                log({"ev": "frame", "dir": "up" if is_up else "down", "bytes": len(data)})
                                if is_up: await dst.send_str(data)
                                else: await dst.send_str(data)
                            elif msg.type == WSMsgType.BINARY:
                                data = msg.data
                                await asyncio.sleep(one_way_s(len(data), is_up))
                                log({"ev": "frame", "dir": "up" if is_up else "down", "bytes": len(data)})
                                if is_up: await dst.send_bytes(data)
                                else: await dst.send_bytes(data)
                            elif msg.type == WSMsgType.PING:
                                pass
                            elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED, WSMsgType.ERROR):
                                break
                    except Exception as e:
                        log({"ev": "pump-error", "dir": "up" if is_up else "down", "error": repr(e)})

                t1 = asyncio.create_task(pump(ws, up, True))
                t2 = asyncio.create_task(pump(up, ws, False))
                done, pending = await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
                for t in pending: t.cancel()
    except Exception as e:
        log({"ev": "upstream-error", "error": repr(e)})
    finally:
        log({"ev": "close"})
        try: await ws.close()
        except Exception: pass
    return ws

app = web.Application()
app.router.add_get("/{tail:.*}", handle)
web.run_app(app, host="127.0.0.1", port=args.port, print=None, access_log=None)
