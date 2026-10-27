"""mail 的管理 CLI：信件线程与通知的 owner 侧命令。

从中转 admin.py 抽出的 feedback-* 子命令（DESIGN-20261015 M2）。与中转版的差异：

- 没有 `--all` 群发：mail 没有账号表，账号名单的真值在中转。全量群发由
  owner 工具（feedback.mjs，M4）从中转取账号清单后逐个点名——两服务之间
  没有"取全部账号"的接口（DESIGN-20261015 I-4：人做桥）。
- 点名 `--account` 不做存在性校验（没有可查的表）；投给不存在的账号只是
  一行永远没人取的投递，owner 工具在更上层对中转校验名单。

退出码与中转的管理命令对齐：0 成功 / 1 业务失败 / 2 用法或存储错误。
"""

from __future__ import annotations

import argparse
import asyncio
import datetime
import json
import os
import sys
import time
from typing import Any, Iterable

from internal import AccountStateNotifier
from store import DEFAULT_FEEDBACK_FORMAT, Store, StoreError

#: `feedback-reply --template` 的默认署名（契约：署名默认 `DSH Mobile 团队`）。
DEFAULT_SIGNATURE = "DSH Mobile 团队"

#: 与中转管理命令同一份口径（feedback-stats 的剔除规则）：
#: 测试台来源的机型认不出来源，只能按机型判；`DSH-` 前缀的调试设备 id 由
#: owner 工具从中转的 device-list 取来传进来（--debug-device）。
TEST_DEVICE_MODELS = {"arm64", "x86_64", "deploy-check", "Node", "simulator", "test-harness"}
REPORT_THREAD_LIMIT = 1000


def _emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def now_ms() -> int:
    return int(time.time() * 1000)


def local_day(stamp: float | None = None) -> int:
    return int(time.strftime("%Y%m%d", time.localtime(time.time() if stamp is None else stamp)))


def _read_body(args: argparse.Namespace) -> str:
    """`--body` 与 `--body-file` 二选一的正文，**原样**返回（不裁剪、不加工）。"""
    if bool(args.body) == bool(args.body_file):
        raise StoreError("pass exactly one of --body or --body-file")
    if args.body_file:
        try:
            with open(args.body_file, encoding="utf-8") as handle:
                body = handle.read()
        except OSError as error:
            raise StoreError(f"cannot read --body-file: {error}") from error
    else:
        body = args.body
    if not body.strip():
        raise StoreError("正文去掉首尾空白后为空，服务端会拒收这条")
    return body


def _show_thread(store: Store, thread_id: str, team: str = "") -> dict[str, Any] | None:
    """一条线程的全部留言；顺手把 `ownerReadAt` 推到最新一条用户消息（只前进）。

    `team` 只影响这一行携带的 `userLetter`（"这封会不会进团队收件箱"）——与服务的
    判定同一份谓词，排查 P2-7 那类线程时 CLI 与 App 看到的是同一个事实。
    """
    head = store.feedback_thread(thread_id, None, messages_per_thread=0, team=team)
    if head is None:
        return None
    thread = store.feedback_thread(thread_id, None, team=team,
                                   messages_per_thread=max(1, int(head["messageCount"])))
    latest_user = max((int(message["createdAt"]) for message in thread["messages"]
                       if message["author"] == "user"), default=None)
    if latest_user is not None and (head["ownerReadAt"] is None
                                    or latest_user > int(head["ownerReadAt"])):
        store.touch_owner_read(thread_id, at=latest_user)
        thread["ownerReadAt"] = latest_user
    thread["ticketHash"] = thread["ticketHash"][:12] + "…"
    return thread


def _require_team(team: str, command: str) -> None:
    """这些命令要靠团队账号判"哪条线程算用户来信"，team 为空时必须报错而不是猜。

    静默降级的样子：`is_user_letter(account, model, "")` 把所有非空账号都判成来信，
    于是团队自己的提交也被算进清单与未读。宁可退非零让调用方补参数
    （`feedback.mjs` 会自动传 `.env.local` 的 DSH_ACCOUNT_ID）。
    """
    if team:
        return
    raise StoreError(f"{command} 需要团队账号：显式给 --team-account <accountId>，"
                     "或在环境里设 MAIL_TEAM_ACCOUNT。没有它无法判定哪条线程算用户来信"
                     "（不会把所有账号都判成来信）")


def _in_scope(row: dict[str, Any], scope: str) -> bool:
    """清单口径：`user` = 命中归属谓词（能进团队收件箱的），`test` = 命不中的。

    判定本身不在这里重写：`list_feedback_threads(team=…)` 已经把
    `store.is_user_letter` 的结果放进每一行的 `userLetter`。
    """
    if scope == "user":
        return bool(row.get("userLetter"))
    if scope == "test":
        return not row.get("userLetter")
    return True


def _feedback_rows(store: Store, *, status: str | None, since_ms: int | None,
                   limit: int, scope: str = "all", team: str = "") -> list[dict[str, Any]]:
    """owner 清单的每一行（与中转管理命令的同名输出同形——日报与工具解同一份 JSON）。

    `team` 决定"哪条算用户来信"；未读只对 `user` 口径计数（测试机型与团队自己的
    提交不再在清单里留一条清不掉的未读）。
    """
    unread = store.owner_unread_counts(team)
    rows = [row for row in store.list_feedback_threads(
        status=status, since_ms=since_ms, limit=limit, team=team) if _in_scope(row, scope)]
    digest = store.feedback_digest([row["threadId"] for row in rows])
    return [
        {
            "threadId": row["threadId"],
            "subject": row["subject"],
            "createdAt": int(row["createdAt"]),
            "lastMessageAt": int(row["lastMessageAt"]),
            "status": row["status"],
            "ownerUnread": unread.get(row["threadId"], 0),
            "source": {
                "kind": "device" if (row["deviceId"] or row["accountId"]) else "anonymous",
                "deviceId": row["deviceId"],
                "accountId": row["accountId"],
                "deviceModel": row["deviceModel"],
                "appVersion": row["appVersion"],
                "systemVersion": row["systemVersion"],
            },
            "excerpt": digest.get(row["threadId"], {}).get("excerpt", ""),
            "format": digest.get(row["threadId"], {}).get("format", DEFAULT_FEEDBACK_FORMAT),
            "messages": int(row["messageCount"]),
        }
        for row in rows
    ]


def _reply_template(signature: str) -> str:
    """官方回信骨架：称呼 / 正文 / 署名 / 日期四部分（打印，不写库）。"""
    day = str(local_day(now_ms() / 1000))
    return (
        "<对用户的称呼>：\n"
        "\n"
        "<回信正文：先说结论，再说下一步>\n"
        "\n"
        f"{signature}\n"
        f"{day[:4]}-{day[4:6]}-{day[6:]}\n"
    )


# ── feedback-stats：给日报的反馈板块（与中转同形，M4 在本机合并） ─────

def _day_start_ms(day: int) -> int:
    text = str(day)
    parsed = datetime.datetime(int(text[:4]), int(text[4:6]), int(text[6:]))
    return int(parsed.timestamp() * 1000)


def _resolve_as_of(value: str | None, *, now: int | None = None) -> int | None:
    """`--as-of` → 锚点毫秒（None = 此刻）。规则与中转管理命令逐字一致。"""
    text = str(value if value is not None else "now").strip()
    if text in ("", "now"):
        return None
    if text == "yesterday":
        at = now_ms() if now is None else int(now)
        return _day_start_ms(local_day(at / 1000)) - 1
    try:
        day = int(datetime.datetime.strptime(text, "%Y-%m-%d").strftime("%Y%m%d"))
    except ValueError:
        raise StoreError(f"--as-of 只能是 now / yesterday / YYYY-MM-DD，收到 {value!r}") from None
    return _day_start_ms(day) + 86_400_000 - 1


def _is_test_thread(row: dict[str, Any], debug_ids: set[str]) -> bool:
    """测试提交：调试设备提的，或来自模拟器/测试台（机型认得出来）。

    与中转管理命令的同名函数同规则；`debug_ids` 不在 mail 里查（没有设备表），
    由 owner 工具从中转取 `DSH-` 前缀的设备 id 传进来。
    """
    device = row.get("deviceId") or (row.get("source") or {}).get("deviceId")
    if device and device in debug_ids:
        return True
    model = str((row.get("source") or {}).get("deviceModel") or "")
    return model in TEST_DEVICE_MODELS


def _feedback_report(store: Store, threads: list[dict[str, Any]],
                     test_count: int = 0) -> dict[str, Any]:
    """反馈板块：窗口内的新增/待回复/已回复、首复中位小时数、线程清单（与中转同形）。"""
    digest = store.feedback_digest([row["threadId"] for row in threads])
    spans = sorted((digest[row["threadId"]]["firstReplyAt"] - row["createdAt"]) / 3_600_000.0
                   for row in threads
                   if digest.get(row["threadId"], {}).get("firstReplyAt") is not None)
    median = None
    if spans:
        middle = len(spans) // 2
        median = round(spans[middle] if len(spans) % 2
                       else (spans[middle - 1] + spans[middle]) / 2, 1)
    return {
        "new": len(threads),
        "open": len([row for row in threads if row["status"] == "open"]),
        "replied": len([row for row in threads if row["status"] == "replied"]),
        "medianFirstReplyHours": median,
        "test": test_count,
        "threads": threads,
    }


def _feedback_stats(store: Store, days: int, *, as_of: int | None = None,
                    debug_ids: set[str] | None = None, team: str = "") -> dict[str, Any]:
    """日报的两个反馈板块（`feedback` + `today.feedback`），形状与中转的 ops-report 一致。

    owner 工具把这份 JSON 与中转的 ops-report 在本机合并（DESIGN-20261015 I-3）——
    服务之间没有调用，合并发生在人这一侧。
    """
    debug_ids = debug_ids or set()
    stamp = now_ms() if as_of is None else int(as_of)
    listed = _feedback_rows(store, status=None, since_ms=stamp - days * 86_400_000,
                            limit=REPORT_THREAD_LIMIT, team=team)
    # 锚点之后新建的线程不属于这份报告（00:00 跑、报刚过去那一天的那一刀）。
    listed = [row for row in listed if int(row["createdAt"]) <= stamp]
    threads = [row for row in listed if not _is_test_thread(row, debug_ids)]
    today_day = local_day(stamp / 1000)
    todays = [row for row in threads if local_day(int(row["createdAt"]) / 1000) == today_day]
    return {
        "ok": True,
        "generatedAt": now_ms(),
        "asOf": stamp,
        "days": days,
        "feedback": _feedback_report(store, threads, test_count=len(listed) - len(threads)),
        "today": {
            "new": len(todays),
            "open": len([row for row in todays if row["status"] == "open"]),
            "replied": len([row for row in todays if row["status"] == "replied"]),
            "threads": todays,
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="admin.py", description="DSH mail administration")
    parser.add_argument("--db", default="mail.db", help="path to the mail SQLite database")
    #: 团队账号与服务同一份配置来源（`MAIL_TEAM_ACCOUNT`）：归属谓词要靠它判"用户来信"。
    parser.add_argument("--team-account", default=os.environ.get("MAIL_TEAM_ACCOUNT", ""),
                        help="the account id that acts as the DSH Mobile team inbox "
                             "(default: $MAIL_TEAM_ACCOUNT)")
    subs = parser.add_subparsers(dest="command", required=True)

    feedback_list = subs.add_parser("feedback-list", help="list feedback threads (owner inbox)")
    feedback_list.add_argument("--status", choices=["open", "replied", "all"], default="all")
    feedback_list.add_argument("--limit", type=int, default=50)
    feedback_list.add_argument("--since", type=int, help="only threads from the last N days")
    feedback_list.add_argument("--scope", choices=["user", "test", "all"], default=None,
                               help="user = 能进团队收件箱的用户来信（命中归属谓词）；"
                                    "test = 命不中归属谓词的行，包含测试机型与团队自己的提交"
                                    "（两者都永远进不了团队收件箱）；all = 全部。"
                                    "给了 --scope 就必须有团队账号（--team-account 或 "
                                    "MAIL_TEAM_ACCOUNT），否则拒绝执行而不是把所有账号判成来信")

    feedback_show = subs.add_parser("feedback-show", help="one thread with its full trail")
    feedback_show.add_argument("--thread", required=True)

    feedback_reply = subs.add_parser("feedback-reply", help="reply to a thread as the owner")
    feedback_reply.add_argument("--thread")
    feedback_reply.add_argument("--body", help="the letter, stored verbatim")
    feedback_reply.add_argument("--body-file", help="read the letter from a file instead")
    feedback_reply.add_argument("--subject", help="replace the thread's subject")
    feedback_reply.add_argument("--format", choices=["text", "html"], default="text")
    feedback_reply.add_argument("--template", action="store_true",
                                help="print the official letter skeleton and exit")
    feedback_reply.add_argument("--signature", default=DEFAULT_SIGNATURE,
                                help="signature line for --template")

    feedback_notify = subs.add_parser("feedback-notify", help="send one notice to accounts")
    feedback_notify.add_argument("--body", help="the notice, stored verbatim")
    feedback_notify.add_argument("--body-file", help="read the notice from a file instead")
    feedback_notify.add_argument("--subject")
    feedback_notify.add_argument("--format", choices=["text", "html"], default="text")
    feedback_notify.add_argument("--account", action="append", default=[],
                                 help="recipient accountId (repeatable)")
    feedback_notify.add_argument("--all", action="store_true",
                                 help="refused: mail has no account list (see --help)")
    feedback_notify.add_argument("--yes", action="store_true",
                                 help="actually write; without it this is a dry run")

    feedback_delete = subs.add_parser("feedback-delete", help="delete a thread (needs --yes)")
    feedback_delete.add_argument("--thread", required=True)
    feedback_delete.add_argument("--yes", action="store_true")

    notice_stats = subs.add_parser("feedback-notice-stats",
                                   help="delivery coverage of one notice (read-only)")
    notice_stats.add_argument("--notice", required=True)

    rebind = subs.add_parser("feedback-rebind",
                             help="rewrite the legacy teamAccountId column from the predicate "
                                  "(only before rolling back to an old build)")
    rebind_mode = rebind.add_mutually_exclusive_group()
    rebind_mode.add_argument("--yes", action="store_true", help="actually write")
    rebind_mode.add_argument("--dry-run", dest="dry_run", action="store_true",
                             help="report the counts and write nothing (the default)")

    stats = subs.add_parser("feedback-stats", help="the feedback sections for the daily report")
    stats.add_argument("--days", type=int, default=30)
    stats.add_argument("--as-of", dest="as_of", default="now",
                       help="now / yesterday / YYYY-MM-DD (same rule as the relay's ops-report)")
    stats.add_argument("--debug-device", action="append", default=[],
                       help="a debug deviceId from the relay (repeatable); "
                            "the owner tool passes the DSH-* list")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    store = Store(args.db)
    try:
        return _dispatch(store, args)
    except StoreError as error:
        # 与中转管理命令同一条约定：StoreError 是业务失败，退 1；
        # argparse 的用法错误自己会 SystemExit(2)。
        sys.stderr.write(f"admin.py: {error}\n")
        return 1
    finally:
        store.close()


def _notify_account_state(account_ids: Iterable[str | None]) -> None:
    """告诉中转"这些账户的信件状态变了"，让它借在线连接扇一帧（032 FR-009）。

    CLI 没有请求上下文，只能自己起一次环回调用（与 mail 服务里那条通知同一个实现）。
    失败**不影响命令本身**：真值在 mail 库里，客户端前台刷新仍能拉到，只是角标晚一点；
    所以这里只往 stderr 记一行，退出码照旧。
    """
    ids = sorted({account for account in account_ids if account})
    if not ids:
        return
    notifier = AccountStateNotifier()

    async def run() -> None:
        try:
            for account_id in ids:
                await notifier(account_id)
        finally:
            await notifier.aclose()

    try:
        asyncio.run(run())
    except Exception as error:  # noqa: BLE001 - 通知是尽力而为，不能连累命令
        print(json.dumps({"notifyError": str(error), "accounts": len(ids)}), file=sys.stderr)


def _dispatch(store: Store, args: argparse.Namespace) -> int:
    command = args.command

    team = str(getattr(args, "team_account", "") or "").strip()

    if command == "feedback-list":
        if args.scope is not None:
            _require_team(team, "feedback-list --scope")
        since_ms = (now_ms() - max(1, int(args.since)) * 86_400_000
                    if args.since is not None else None)
        _emit(_feedback_rows(store, status=None if args.status == "all" else args.status,
                             since_ms=since_ms, limit=max(1, int(args.limit)),
                             scope=args.scope or "all", team=team))
        return 0

    if command == "feedback-notice-stats":
        stats_row = store.notice_delivery_stats(args.notice)
        if stats_row is None:
            _emit({"ok": False, "error": "notice not found"})
            return 1
        _emit(stats_row)
        return 0

    if command == "feedback-rebind":
        _require_team(team, "feedback-rebind")
        _emit(store.rebind_team_account(team, dry_run=not args.yes))
        return 0

    if command == "feedback-show":
        thread = _show_thread(store, args.thread, team)
        if thread is None:
            _emit({"ok": False, "error": "thread not found"})
            return 1
        _emit(thread)
        return 0

    if command == "feedback-reply":
        if args.template:
            sys.stdout.write(_reply_template(args.signature))
            return 0
        if not args.thread:
            raise StoreError("feedback-reply 需要 --thread（或者 --template）")
        letter = _read_body(args)
        if args.subject is not None:
            if store.set_feedback_subject(args.thread, args.subject) is False:
                _emit({"ok": False, "error": "thread not found"})
                return 1
        written = store.append_feedback_message(args.thread, letter, author="owner",
                                                format=args.format)
        if written is None:
            _emit({"ok": False, "error": "thread not found"})
            return 1
        # 回信是一封新信：让来信账户的那几台设备当场去拉，而不是等下次前台刷新。
        thread = store.feedback_thread(args.thread, None, messages_per_thread=0)
        if thread is not None:
            _notify_account_state([thread.get("accountId")])
        _emit({"ok": True, "threadId": args.thread, "messageId": written["messageId"],
               "createdAt": int(written["createdAt"])})
        return 0

    if command == "feedback-notify":
        if args.all:
            raise StoreError("mail 没有账号清单：全量群发由本机工具从中转取账号后逐个点名"
                             "（node scripts/dev/feedback.mjs notify --all）")
        if not args.account:
            raise StoreError("必须点名收件人：--account <accountId>（可重复）")
        body = _read_body(args)
        if not args.yes:
            _emit({"ok": True, "dryRun": True, "recipients": len(args.account),
                   "accounts": args.account})
            return 0
        notice = store.create_notice(body, args.subject, args.account,
                                     format=args.format, created_by="admin.py")
        _notify_account_state(args.account)
        _emit({"ok": True, "noticeId": notice["noticeId"], "recipients": notice["recipients"],
               "createdAt": int(notice["createdAt"])})
        return 0

    if command == "feedback-delete":
        thread = store.feedback_thread(args.thread, None, messages_per_thread=0)
        if thread is None:
            _emit({"ok": False, "error": "thread not found"})
            return 1
        if not args.yes:
            _emit({"ok": True, "dryRun": True, "threadId": args.thread, "exists": True,
                   "messages": int(thread["messageCount"])})
            return 0
        removed = store.delete_feedback_thread(args.thread)
        _emit({"ok": True, "threadId": args.thread, "deleted": True, "messages": removed})
        return 0

    if command == "feedback-stats":
        _require_team(team, "feedback-stats")
        _emit(_feedback_stats(store, max(1, int(args.days)),
                              as_of=_resolve_as_of(args.as_of),
                              debug_ids=set(args.debug_device), team=team))
        return 0

    raise StoreError(f"unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
