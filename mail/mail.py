"""DSH mail service — 信件（反馈线程 + 通知收件箱）的独立服务。

从中转拆出来的那一半（DESIGN-20261015）：只有 HTTP，没有 WebSocket、没有配对、
没有用量记账。公网契约不变——仍是 ``POST /feedback/{submit,inbox,append,read}``，
App 端点跟随中转基址，由 Caddy 把 ``/dsh-link/feedback/*`` 分流到这里。

对中转的唯一运行时依赖是 ``app["resolve_device"]``（默认实现：loopback 调中转的
``POST /internal/tokens/resolve``，见 :mod:`internal`）；解析不到就按匿名，
匿名凭据（`fk_` ticket）的校验完全在本地库，中转不在也照常工作。
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
from typing import Any, Awaitable, Callable

from aiohttp import web

from api import cors_preflight, register_mail_routes
from internal import DEFAULT_RELAY_INTERNAL_URL, RelayIdentityResolver
from store import Store

LOGGER = logging.getLogger("mail")

#: `resolve_device` 的类型：设备令牌 → 设备归属（`None` = 匿名）。
ResolveDevice = Callable[[str], Awaitable[dict[str, Any] | None]]


def normalize_base_path(raw: str | None) -> str:
    """Normalise a mount prefix to ``""`` or ``"/prefix"``（与 relay.py 同一口径）。"""
    text = str(raw or "").strip()
    if not text or text == "/":
        return ""
    if not text.startswith("/"):
        text = f"/{text}"
    return text.rstrip("/")


async def healthz(_request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "service": "dsh-mail"})


def create_app(*, store: Store, resolve_device: ResolveDevice | None = None,
               base_path: str = "") -> web.Application:
    """组装 mail 的 aiohttp 应用。

    ``resolve_device`` 不给就用 :class:`RelayIdentityResolver`（生产默认）；
    测试注入假实现。每条路由都注册带前缀与去前缀两种形式——与中转同一条约定：
    前端可能剥前缀（Caddy 的 ``uri strip_prefix``）也可能原样转发。
    """
    base_path = normalize_base_path(base_path)
    app = web.Application(client_max_size=64 * 1024, middlewares=[cors_preflight])
    app["store"] = store
    resolver = resolve_device if resolve_device is not None else RelayIdentityResolver()
    app["resolve_device"] = resolver
    app["base_path"] = base_path

    def route(method: str, path: str, handler: Any) -> None:
        app.router.add_route(method, path, handler)
        if base_path:
            app.router.add_route(method, f"{base_path}{path}", handler)

    route("GET", "/healthz", healthz)
    register_mail_routes(app, route)

    async def _cleanup(_app: web.Application) -> None:
        aclose = getattr(resolver, "aclose", None)
        if aclose is not None:
            await aclose()

    app.on_cleanup.append(_cleanup)
    return app


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="mail.py", description="DSH mail service (letters + notices)")
    parser.add_argument("--host", default=os.environ.get("MAIL_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MAIL_PORT", "8788")))
    # 默认落在 .local/ 下：源码目录只放源码。生产由 systemd 单元显式传
    # --db /var/lib/dsh-mail/mail.db（见 deploy/dsh-mail.service）。
    parser.add_argument("--db", default=os.environ.get("MAIL_DB", os.path.join(os.path.dirname(
        os.path.abspath(__file__)), ".local", "mail.db")))
    parser.add_argument("--relay-internal-url",
                        default=os.environ.get("MAIL_RELAY_INTERNAL_URL", DEFAULT_RELAY_INTERNAL_URL),
                        help="loopback URL of the relay for /internal/tokens/resolve")
    parser.add_argument("--relay-timeout-s", type=float,
                        default=float(os.environ.get("MAIL_RELAY_TIMEOUT_S", "2.0")))
    parser.add_argument("--base-path", default=os.environ.get("MAIL_BASE_PATH", ""),
                        help="optional mount prefix, e.g. /dsh-link; both forms are served")
    parser.add_argument("--log-level", default=os.environ.get("MAIL_LOG_LEVEL", "INFO"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    store = Store(args.db)
    app = create_app(store=store,
                     resolve_device=RelayIdentityResolver(args.relay_internal_url,
                                                          args.relay_timeout_s),
                     base_path=args.base_path)
    LOGGER.info("mail: serving on %s:%d (db=%s, relay=%s)",
                args.host, args.port, args.db, args.relay_internal_url)
    web.run_app(app, host=args.host, port=args.port, print=None)
    store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
