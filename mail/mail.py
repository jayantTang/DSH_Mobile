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
import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

from aiohttp import web

import attachments as attachment_files
from api import LIMITS, cors_preflight, register_mail_routes
from internal import (DEFAULT_RELAY_INTERNAL_URL, AccountStateNotifier,
                      RelayIdentityResolver)
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


#: 部署构建号 `yyyyMMdd.HHmm`（北京时间），由 `deploy/deploy.sh` 写进同一目录的
#: `build.json`。与中转的版本口径相同：没有注册表就用构建号，
#: 一眼能看出发布先后；读不到就报 `0.0.0`（= 这不是一次部署）。
_BUILD_FILE = Path(__file__).with_name("build.json")
UNVERSIONED = "0.0.0"


def deployed_version() -> str:
    try:
        payload = json.loads(_BUILD_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return UNVERSIONED
    if not isinstance(payload, dict):
        return UNVERSIONED
    value = payload.get("version")
    return value.strip() if isinstance(value, str) and value.strip() else UNVERSIONED


#: 附件回滚开关的环境变量名：`0` = 关停（v2 不下发 `limits.attachments`，
#: `begin`/`upload`/`discard` 一律 404；已绑定的历史附件仍可 `fetch`）。
ATTACHMENT_MAX_PER_MESSAGE_ENV = "MAIL_ATTACHMENT_MAX_PER_MESSAGE"

#: 附件**角色**（预览 / 原图配对）的回滚开关：`0` = 关停（v2 不下发
#: `limits.attachments.roles`，`begin` 收到 `role != original` 回 400；已存在的配对信件
#: 仍按 slot 投影成一个对象，见设计 §6.2）。
ATTACHMENT_ROLES_ENV = "MAIL_ATTACHMENT_ROLES"

#: 附件清扫的默认周期（生产 1 小时；测试传 0 = 不起后台任务，用例不泄漏任务）。
DEFAULT_SWEEP_INTERVAL_S = 3600.0
#: 三类残留的过期时长：`pending` 行 1 小时、`tmp/*.part` 1 小时、
#: 已传完但没提交的**草稿** 7 天（设计 §3.3 / §9-11，owner 裁定的默认值）。
PENDING_TTL_S = 3600.0
TEMP_TTL_S = 3600.0
DRAFT_TTL_S = 7 * 24 * 3600.0


#: 清扫翻页的大小：`known` 必须覆盖**全部**已存行，不能只取一页（F4）。
SWEEP_PAGE_SIZE = 500


def parse_attachment_roles(raw: str | int) -> bool:
    """解析角色回滚开关：`0` = 关停，`1` = 开着；其余值启动即失败（不静默回退）。"""
    text = str(raw).strip()
    if text not in ("0", "1"):
        raise ValueError(f"{ATTACHMENT_ROLES_ENV} must be 0 or 1, got {text!r}")
    return text == "1"


def parse_attachment_max_per_message(raw: str | int) -> int:
    """解析附件回滚开关：必须是**非负整数**，否则启动即失败（不静默回退）。

    0 = 关停附件（见 :func:`create_app`）；正整数 = 单封附件个数上限。
    """
    text = str(raw).strip()
    try:
        value = int(text)
    except (TypeError, ValueError):
        raise ValueError(
            f"{ATTACHMENT_MAX_PER_MESSAGE_ENV} must be a non-negative integer, got {text!r}")
    if value < 0:
        raise ValueError(
            f"{ATTACHMENT_MAX_PER_MESSAGE_ENV} must be a non-negative integer, got {value}")
    return value


async def sweep_attachments_once(store: Store, root: str, *, now: int | None = None,
                                 pending_ttl_s: float = PENDING_TTL_S,
                                 temp_ttl_s: float = TEMP_TTL_S,
                                 draft_ttl_s: float = DRAFT_TTL_S,
                                 page_size: int = SWEEP_PAGE_SIZE) -> dict[str, int]:
    """一次清扫：过期草稿、过期 `pending` 行、过期 `tmp/*.part`、孤儿文件、丢掉字节的行。

    `now` 是毫秒（与库里 `createdAt` 同单位）；文件系统那边按秒折算。
    四件事都是幂等的：重复清扫只会让残留更少，不会把正常行标坏。

    "哪些文件有行"按 `page_size` **翻页取全**（F4）：早先的一次性
    `list_attachments(limit=100_000)` 会在超过十万条已存行时漏掉后面的行，把它们的
    文件当孤儿删掉。翻页后 `known` 与库里的已存行一一对应；标 `lost` 留到全部页取完
    再做（否则会边翻页边改行，行序变化漏行）。
    """
    stamp = int(time.time() * 1000) if now is None else int(now)
    # 先清过期草稿（行 + 字节）：后面的 `known` 就不会把它们再算一遍。
    # 已绑定的行永远不受这一步影响（store 只删 `messageId IS NULL` 的行）。
    draft_paths = await asyncio.to_thread(
        store.expire_draft_attachments, stamp - int(draft_ttl_s * 1000))
    for relative in draft_paths:
        try:
            attachment_files.delete(attachment_files.path_for(root, relative))
        except attachment_files.AttachmentPathError:
            LOGGER.warning("mail: expired draft has a storedPath outside the root")
    drafts = len(draft_paths)
    expired = await asyncio.to_thread(store.expire_pending_attachments,
                                      stamp - int(pending_ttl_s * 1000))
    seconds = stamp / 1000
    removed_temp = await asyncio.to_thread(attachment_files.sweep_temp, root, temp_ttl_s,
                                           now=seconds)
    known: set[str] = set()
    missing: list[str] = []
    offset = 0
    while True:
        page = await asyncio.to_thread(store.list_attachments, state="stored",
                                       limit=page_size, offset=offset)
        if not page:
            break
        for row in page:
            known.add(row["attachmentId"])
            relative = row["storedPath"]
            # "不可用"有三个判据：没有相对路径、文件不在、大小与登记不符（F9）。
            # 路径越界（库值被改坏）也只影响这一行：捕获后并入 missing，绝不让异常
            # 冒出去——否则整次清扫中断，标 lost 与清孤儿都不执行，下一小时还撞同一行（F10）。
            if not relative:
                missing.append(row["attachmentId"])
                continue
            try:
                path = attachment_files.path_for(root, relative)
            except attachment_files.AttachmentPathError:
                LOGGER.warning("mail: attachment %s has a storedPath outside the root;"
                               " marking it lost", row["attachmentId"])
                missing.append(row["attachmentId"])
                continue
            if not os.path.isfile(path) or os.path.getsize(path) != int(row["byteSize"]):
                missing.append(row["attachmentId"])
        if len(page) < page_size:
            break
        offset += len(page)
    lost = await asyncio.to_thread(store.mark_attachments_lost, missing) if missing else 0
    # `known` 保留全部已存行（含"文件丢了"的那些）：宁可少删一个孤儿，也不许删掉
    # 一个有行的文件——两者代价不对称（F4 的破口正是后者）。
    orphans = await asyncio.to_thread(attachment_files.sweep_orphans, root, known,
                                      min_age_s=temp_ttl_s, now=seconds)
    return {"drafts": drafts, "expired": expired, "temp": removed_temp,
            "lost": lost, "orphans": orphans}


async def healthz(_request: web.Request) -> web.Response:
    # `service` 仍是"这个响应来自哪个服务"的判据（036 拆分时定的），版本只增不改。
    return web.json_response({"ok": True, "service": "dsh-mail", "version": deployed_version()})


def create_app(*, store: Store, resolve_device: ResolveDevice | None = None,
               base_path: str = "", team_account: str = "",
               notify_account_state: Any | None = None,
               attachments_root: str | None = None,
               attachment_limits: dict[str, Any] | None = None,
               attachment_max_per_message: int | None = None,
               attachment_roles: bool = True,
               sweep_interval_s: float = 0.0) -> web.Application:
    """组装 mail 的 aiohttp 应用。

    ``resolve_device`` 不给就用 :class:`RelayIdentityResolver`（生产默认）；
    测试注入假实现。每条路由都注册带前缀与去前缀两种形式——与中转同一条约定：
    前端可能剥前缀（Caddy 的 ``uri strip_prefix``）也可能原样转发。

    ``notify_account_state``（032）：已读之后用它告诉中转"这个账户的信件状态变了"，
    让同账户的其他在线设备跟着刷新。不给就用 :class:`AccountStateNotifier`；测试注入假实现。

    附件（2026-11-02，M4）：``attachments_root`` 缺省是数据库同级的 `attachments/`
    （生产 `/var/lib/dsh-mail/attachments/`，已在单元的 `ReadWritePaths` 之内）；
    ``attachment_limits`` 只覆盖 `LIMITS["attachments"]` 里的值（测试用小值复现
    413/507，生产用默认值——默认数只有 :data:`api.LIMITS` 一处）；
    ``sweep_interval_s`` > 0 时起每小时一次的清扫，0（测试默认）就一个任务都不起。
    """
    base_path = normalize_base_path(base_path)
    app = web.Application(client_max_size=64 * 1024, middlewares=[cors_preflight])
    app["store"] = store
    resolver = resolve_device if resolve_device is not None else RelayIdentityResolver()
    app["resolve_device"] = resolver
    notifier = notify_account_state if notify_account_state is not None else AccountStateNotifier()
    app["notify_account_state"] = notifier
    app["base_path"] = base_path
    # 团队收件箱（2026-10-15）：团队账号 = owner 的开发者账号；空 = 功能关闭。
    app["team_account"] = str(team_account or "").strip()
    root = attachments_root or attachment_files.root_for(store.path)
    attachment_files.ensure_dirs(root)
    app["attachments_root"] = root
    limits = {**LIMITS["attachments"], **(attachment_limits or {})}
    if attachment_max_per_message is not None:
        limits["maxPerMessage"] = int(attachment_max_per_message)
    if not attachment_roles:
        # 回滚开关：不下发 `roles`，`begin` 拒绝非 original 的角色（api 只读这一份名单）。
        limits["roles"] = []
    app["attachment_limits"] = limits
    app["attachment_sweep_interval_s"] = float(sweep_interval_s)

    def route(method: str, path: str, handler: Any) -> None:
        app.router.add_route(method, path, handler)
        if base_path:
            app.router.add_route(method, f"{base_path}{path}", handler)

    route("GET", "/healthz", healthz)
    register_mail_routes(app, route)

    async def _sweep_loop(interval: float) -> None:
        while True:
            try:
                await sweep_attachments_once(store, root)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 —— 清扫失败不许把服务带下去
                LOGGER.exception("mail: attachment sweep failed")
            await asyncio.sleep(interval)

    async def _startup(_app: web.Application) -> None:
        interval = float(_app["attachment_sweep_interval_s"])
        if interval > 0:
            _app["attachment_sweeper"] = asyncio.create_task(_sweep_loop(interval))

    async def _cleanup(_app: web.Application) -> None:
        sweeper = _app.get("attachment_sweeper")
        if sweeper is not None:
            sweeper.cancel()
            try:
                await sweeper
            except asyncio.CancelledError:
                LOGGER.debug("mail: attachment sweeper cancelled at shutdown")
        for target in (resolver, notifier):
            aclose = getattr(target, "aclose", None)
            if aclose is not None:
                await aclose()

    app.on_startup.append(_startup)
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
    parser.add_argument("--team-account", default=os.environ.get("MAIL_TEAM_ACCOUNT", ""),
                        help="the account id that acts as the DSH Mobile team inbox "
                             "(empty = team inbox off)")
    parser.add_argument("--base-path", default=os.environ.get("MAIL_BASE_PATH", ""),
                        help="optional mount prefix, e.g. /dsh-link; both forms are served")
    parser.add_argument("--attachments-dir", default=os.environ.get("MAIL_ATTACHMENTS_DIR", ""),
                        help="where attachment bytes live (default: <db dir>/attachments)")
    parser.add_argument("--attachment-max-per-message",
                        type=parse_attachment_max_per_message,
                        default=os.environ.get(ATTACHMENT_MAX_PER_MESSAGE_ENV,
                                               str(LIMITS["attachments"]["maxPerMessage"])),
                        help="attachment rollback switch: 0 disables attachments "
                             f"(env {ATTACHMENT_MAX_PER_MESSAGE_ENV})")
    parser.add_argument("--attachment-roles", type=parse_attachment_roles,
                        default=os.environ.get(ATTACHMENT_ROLES_ENV, "1"),
                        help="attachment role rollback switch: 0 disables the "
                             f"preview/original pairing (env {ATTACHMENT_ROLES_ENV})")
    parser.add_argument("--attachment-sweep-s", type=float,
                        default=float(os.environ.get("MAIL_ATTACHMENT_SWEEP_S", "3600")),
                        help="seconds between attachment sweeps; 0 = no sweeper")
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
                     notify_account_state=AccountStateNotifier(args.relay_internal_url,
                                                               args.relay_timeout_s),
                     base_path=args.base_path, team_account=args.team_account,
                     attachments_root=args.attachments_dir or None,
                     attachment_max_per_message=args.attachment_max_per_message,
                     attachment_roles=args.attachment_roles,
                     sweep_interval_s=args.attachment_sweep_s)
    LOGGER.info("mail: serving on %s:%d (db=%s, relay=%s, team_inbox=%s, attachments=%s)",
                args.host, args.port, args.db, args.relay_internal_url,
                args.team_account or "off",
                "off" if args.attachment_max_per_message == 0
                else f"up to {args.attachment_max_per_message}/letter")
    web.run_app(app, host=args.host, port=args.port, print=None)
    store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
