"""mail 的管理 CLI：信件线程与通知的 owner 侧命令。

从中转 admin.py 抽出的 feedback-* 子命令（DESIGN-20261015 M2）。与中转版的差异：

- 没有 `--all` 群发：mail 没有账号表，账号名单的真值在中转。全量群发由
  owner 工具（feedback.mjs，M4）从中转取账号清单后逐个点名——两服务之间
  没有"取全部账号"的接口（DESIGN-20261015 I-4：人做桥）。
- 点名 `--account` 不做存在性校验（没有可查的表）；投给不存在的账号只是
  一行永远没人取的投递，owner 工具在更上层对中转校验名单。

退出码与 relay/admin.py 对齐：0 成功 / 1 业务失败 / 2 用法或存储错误。
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from store import DEFAULT_FEEDBACK_FORMAT, Store, StoreError

#: `feedback-reply --template` 的默认署名（契约：署名默认 `DSH Mobile 团队`）。
DEFAULT_SIGNATURE = "DSH Mobile 团队"


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


def _show_thread(store: Store, thread_id: str) -> dict[str, Any] | None:
    """一条线程的全部留言；顺手把 `ownerReadAt` 推到最新一条用户消息（只前进）。"""
    head = store.feedback_thread(thread_id, None, messages_per_thread=0)
    if head is None:
        return None
    thread = store.feedback_thread(thread_id, None,
                                   messages_per_thread=max(1, int(head["messageCount"])))
    latest_user = max((int(message["createdAt"]) for message in thread["messages"]
                       if message["author"] == "user"), default=None)
    if latest_user is not None and (head["ownerReadAt"] is None
                                    or latest_user > int(head["ownerReadAt"])):
        store.touch_owner_read(thread_id, at=latest_user)
        thread["ownerReadAt"] = latest_user
    thread["ticketHash"] = thread["ticketHash"][:12] + "…"
    return thread


def _feedback_rows(store: Store, *, status: str | None, since_ms: int | None,
                   limit: int) -> list[dict[str, Any]]:
    """owner 清单的每一行（与 relay/admin.py 的同名函数同形——日报与工具解同一份 JSON）。"""
    unread = store.owner_unread_counts()
    rows = store.list_feedback_threads(status=status, since_ms=since_ms, limit=limit)
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="admin.py", description="DSH mail administration")
    parser.add_argument("--db", default="mail.db", help="path to the mail SQLite database")
    subs = parser.add_subparsers(dest="command", required=True)

    feedback_list = subs.add_parser("feedback-list", help="list feedback threads (owner inbox)")
    feedback_list.add_argument("--status", choices=["open", "replied", "all"], default="all")
    feedback_list.add_argument("--limit", type=int, default=50)
    feedback_list.add_argument("--since", type=int, help="only threads from the last N days")

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

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    store = Store(args.db)
    try:
        return _dispatch(store, args)
    except StoreError as error:
        # 与 relay/admin.py 同一条约定：StoreError 是业务失败，退 1；
        # argparse 的用法错误自己会 SystemExit(2)。
        sys.stderr.write(f"admin.py: {error}\n")
        return 1
    finally:
        store.close()


def _dispatch(store: Store, args: argparse.Namespace) -> int:
    command = args.command

    if command == "feedback-list":
        since_ms = (now_ms() - max(1, int(args.since)) * 86_400_000
                    if args.since is not None else None)
        _emit(_feedback_rows(store, status=None if args.status == "all" else args.status,
                             since_ms=since_ms, limit=max(1, int(args.limit))))
        return 0

    if command == "feedback-show":
        thread = _show_thread(store, args.thread)
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

    raise StoreError(f"unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
