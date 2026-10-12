"""Operator CLI for the DLP relay.

The relay has no *open* signup, but it does have an invitation path: the
operator mints an invite code here, and the person receiving it redeems the code
on their own computer through ``POST /agents/enroll`` (the connector's
``dsh-mobile-link enroll``). Everything else is provisioned from a shell.

    python3 admin.py --db state.db account-create --name "Example"
    python3 admin.py --db state.db agent-register --account acc_x --name "MacBook Pro" \
        --write-config ~/.dsh/mobile-link/agent.json --relay wss://relay.example.com/dsh-link
    python3 admin.py --db state.db invite-mint --note "for Sam" --count 1
    python3 admin.py --db state.db code-mint --agent agt_x
    python3 admin.py --db state.db device-list --agent agt_x
    python3 admin.py --db state.db device-revoke --device dev_x
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from typing import Any
from urllib.parse import quote

from push import PushSender
from store import (DEFAULT_FEEDBACK_FORMAT, DEFAULT_INVITE_TTL_MS, DEFAULT_PAIR_TTL_MS,
                   FEEDBACK_FORMATS, Store, StoreError, local_day, now_ms)

#: The relay is published as a path prefix on the existing, already-certified
#: site (no new DNS record, no new certificate).
DEFAULT_RELAY = "wss://relay.example.com/dsh-link"

#: `feedback-reply --template` 的默认署名（契约：署名默认 `DSH Mobile 团队`）。
DEFAULT_SIGNATURE = "DSH Mobile 团队"

#: 日报里最多列这么多条反馈线程：原始数据也给个界，别让一次灌水撑爆日报。
REPORT_THREAD_LIMIT = 1000

#: 日报里最多列这么多台设备（未撤销的、按最近在线倒序）与前几名账号：
#: 生产库上历史设备有 1900+ 行，全量会把日报撑到几百 KB 且全是调试设备。
REPORT_DEVICE_LIMIT = 200
REPORT_TOP_ACCOUNTS = 20


def qr_payload(relay: str, code: str, agent_id: str) -> str:
    """The `dsh://pair?relay=...&code=...` deep link the iOS app scans.

    ``relay`` keeps its full path prefix so the phone reaches `/pair/claim` and
    `/link/device` under the same base. ``agent_id`` is accepted for symmetry
    with the connector and is not part of the deep link: the phone learns the
    agent from the `/pair/claim` response.
    """
    del agent_id
    return f"dsh://pair?relay={quote(relay, safe='')}&code={quote(code, safe='')}"


def _emit(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


def enroll_command(relay: str, code: str) -> str:
    """The one-liner the invitee runs on their own computer.

    The relay address travels with the code so the invitee does not have to be
    told two things and get one of them wrong.
    """
    return f"dsh-mobile-link enroll --invite {code} --relay {relay}"


def _agent_config(relay: str, agent: dict[str, Any]) -> dict[str, Any]:
    return {
        "relayUrl": relay,
        "agentId": agent["agentId"],
        "agentSecret": agent["agentSecret"],
        "agentName": agent.get("name"),
    }


def _write_config(path: str, payload: dict[str, Any]) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(path, 0o600)


def _resolve_agent(store: Store, raw: str) -> dict[str, Any]:
    agent = store.agent_by_id(raw)
    if agent is None:
        matches = [row for row in store.list_agents() if row["name"] == raw]
        if len(matches) == 1:
            return matches[0]
        raise StoreError(f"no agent matches {raw!r}")
    return agent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="admin.py", description="DLP relay administration")
    # 与 relay.py 的默认值**必须一致**：两处不同步的话，admin.py 建出来的账号
    # relay 看不到（各开一个库），排查起来像"账号不存在"。
    parser.add_argument("--db", default=os.environ.get("DLP_DB", os.path.join(
        os.path.dirname(os.path.abspath(__file__)), ".local", "state.db")))
    subs = parser.add_subparsers(dest="command", required=True)

    account_create = subs.add_parser("account-create", help="create a new account")
    account_create.add_argument("--name", required=True)
    subs.add_parser("account-list", help="list accounts")

    agent_register = subs.add_parser("agent-register", help="create an agent or rotate its secret")
    agent_register.add_argument("--account", required=True)
    agent_register.add_argument("--name", required=True)
    agent_register.add_argument("--agent", help="existing agentId to rotate")
    agent_register.add_argument("--relay", default=DEFAULT_RELAY)
    agent_register.add_argument("--write-config", help="write the agent identity file (mode 0600)")

    agent_rotate = subs.add_parser("agent-rotate", help="rotate an agent secret")
    agent_rotate.add_argument("--agent", required=True)
    agent_rotate.add_argument("--name")
    agent_rotate.add_argument("--relay", default=DEFAULT_RELAY)
    agent_rotate.add_argument("--write-config")

    agent_list = subs.add_parser("agent-list", help="list agents")
    agent_list.add_argument("--account")

    for name, help_text in (("agent-disable", "disable an agent"), ("agent-enable", "re-enable an agent")):
        sub = subs.add_parser(name, help=help_text)
        sub.add_argument("--agent", required=True)

    code_mint = subs.add_parser("code-mint", help="mint a pairing code")
    code_mint.add_argument("--agent", required=True)
    code_mint.add_argument("--ttl-seconds", type=int, default=DEFAULT_PAIR_TTL_MS // 1000)
    code_mint.add_argument("--relay", default=DEFAULT_RELAY)

    invite_mint = subs.add_parser(
        "invite-mint",
        help="mint a one-time invite code someone else redeems on their own computer",
    )
    invite_mint.add_argument("--ttl-seconds", type=int, default=DEFAULT_INVITE_TTL_MS // 1000)
    invite_mint.add_argument("--note", help="free-form label, e.g. who it is for")
    invite_mint.add_argument("--relay", default=DEFAULT_RELAY)
    invite_mint.add_argument("--count", type=int, default=1, help="mint this many codes at once")

    invite_list = subs.add_parser("invite-list", help="list invites (hashes only, never codes)")
    invite_list.add_argument("--all", action="store_true", help="include used invites")

    invite_revoke = subs.add_parser(
        "invite-revoke",
        help="retire an invite that leaked or is no longer needed (never a used one)",
    )
    invite_revoke.add_argument("--code", required=True, help="the code to retire")

    device_list = subs.add_parser("device-list", help="list devices")
    device_list.add_argument("--agent")
    device_list.add_argument("--all", action="store_true", help="include revoked devices")

    device_revoke = subs.add_parser("device-revoke", help="revoke a device")
    device_revoke.add_argument("--device")
    device_revoke.add_argument("--token")

    subs.add_parser("enrollments", help="who took an invite (joined view, read-only)")

    invite_check = subs.add_parser("invite-check",
                                   help="report whether given codes are used/expired (read-only)")
    invite_check.add_argument("--code", action="append", default=[], help="may be repeated")
    invite_check.add_argument("--stdin", action="store_true", help="read one code per line")

    usage = subs.add_parser("usage", help="daily egress per account or device")
    usage.add_argument("--days", type=int, default=7, help="how many days back to include")
    usage.add_argument("--by", choices=("account", "device"), default="account")

    purge = subs.add_parser("purge", help="drop expired pairing codes")
    purge.add_argument("--json", action="store_true")

    push_test = subs.add_parser(
        "push-test",
        help="send one APNs reminder now and print Apple's answer (needs apns.env)",
    )
    push_test.add_argument("--device", required=True, help="deviceId (see device-list)")
    push_test.add_argument("--kind", choices=("turnEnd", "attention"), default="turnEnd")
    push_test.add_argument("--sid", default="push-test",
                           help="session id to put in the payload (never displayed)")

    # ── feedback channel (014)：owner 侧的命令面 ─────────────────────────────
    # 我在服务器上读反馈、回信、群发、响应隐私删除请求；契约见
    # `specs/014-feedback-channel/contracts/admin-cli.md`。
    feedback_list = subs.add_parser("feedback-list", help="list feedback threads (owner inbox)")
    feedback_list.add_argument("--status", choices=("open", "replied", "all"), default="all")
    feedback_list.add_argument("--limit", type=int, default=50)
    feedback_list.add_argument("--since", type=int, help="only threads created in the last DAYS days")

    feedback_show = subs.add_parser("feedback-show",
                                    help="one thread with its full trail (marks it read)")
    feedback_show.add_argument("--thread", required=True)

    feedback_reply = subs.add_parser("feedback-reply", help="reply to a thread as the owner")
    feedback_reply.add_argument("--thread")
    feedback_reply.add_argument("--body", help="the letter, stored verbatim")
    feedback_reply.add_argument("--body-file", help="read the letter from a file instead")
    feedback_reply.add_argument("--subject",
                                help="replace the thread subject (≤80 chars; blank clears it);"
                                     " omit to keep the user's own")
    feedback_reply.add_argument("--format", choices=FEEDBACK_FORMATS,
                                default=DEFAULT_FEEDBACK_FORMAT,
                                help="body format: text (the phone renders Markdown, the default)"
                                     " or html (the locked-down container, for reports with images)")
    feedback_reply.add_argument("--template", action="store_true",
                                help="print the official skeleton and write nothing")
    feedback_reply.add_argument("--signature", default=DEFAULT_SIGNATURE,
                                help="signature used by --template")

    feedback_notify = subs.add_parser("feedback-notify",
                                      help="send one notice to devices (dry run unless --yes)")
    feedback_notify.add_argument("--body")
    feedback_notify.add_argument("--body-file")
    feedback_notify.add_argument("--subject")
    feedback_notify.add_argument("--format", choices=FEEDBACK_FORMATS,
                                 default=DEFAULT_FEEDBACK_FORMAT,
                                 help="body format: text (Markdown on the phone, the default)"
                                      " or html (the locked-down container)")
    feedback_notify.add_argument("--device", action="append", default=[],
                                 help="deviceId, may be repeated")
    feedback_notify.add_argument("--all", action="store_true",
                                 help="every device that is not revoked (the default)")
    feedback_notify.add_argument("--yes", action="store_true", help="actually write it")

    feedback_delete = subs.add_parser("feedback-delete",
                                      help="delete a thread and its messages (needs --yes)")
    feedback_delete.add_argument("--thread", required=True)
    feedback_delete.add_argument("--yes", action="store_true")

    ops_report = subs.add_parser("ops-report", help="raw data for the daily operations report")
    ops_report.add_argument("--days", type=int, default=30)
    return parser


def run(args: argparse.Namespace, store: Store) -> int:
    command = args.command

    if command == "account-create":
        _emit(store.create_account(args.name))
        return 0

    if command == "account-list":
        _emit(store.list_accounts())
        return 0

    if command == "agent-register":
        existing = None
        if args.agent:
            existing = _resolve_agent(store, args.agent)
        created = store.register_agent(args.account, args.name,
                                       agent_id=existing["agentId"] if existing else None)
        created["rotated"] = bool(existing)
        if args.write_config:
            _write_config(args.write_config, _agent_config(args.relay, created))
            created["configPath"] = args.write_config
        _emit(created)
        return 0

    if command == "agent-rotate":
        agent = _resolve_agent(store, args.agent)
        created = store.register_agent(agent["accountId"], args.name or agent["name"],
                                       agent_id=agent["agentId"])
        if args.write_config:
            _write_config(args.write_config, _agent_config(args.relay, created))
            created["configPath"] = args.write_config
        _emit(created)
        return 0

    if command == "agent-list":
        agents = store.list_agents(args.account)
        _emit([{**agent, "secretHash": agent["secretHash"][:12] + "…"} for agent in agents])
        return 0

    if command == "invite-check":
        # 只回答"这张码还能不能用"。公开的邀请码列表要靠它保持准确：
        # 用掉哪张就在表里标出来，新人不必翻评论猜。
        codes = list(args.code)
        if args.stdin:
            codes += [line.strip() for line in sys.stdin if line.strip()]
        _emit([{"code": code, **store.invite_status(code)} for code in codes])
        return 0

    if command == "enrollments":
        # 公开试用要回答的两个问题："码用掉几张"、"谁来了"。
        _emit({"totals": store.invite_totals(), "enrollments": store.list_enrollments()})
        return 0

    if command == "usage":
        # 记账只覆盖中转自己的出口字节（不含 SSH / OTA 下载）；日界是服务器本地日，
        # 与设备每日额度是同一个口径（都走 store.local_day()）。
        _emit(store.usage_totals(days=args.days, by=args.by))
        return 0

    if command in ("agent-disable", "agent-enable"):
        agent = _resolve_agent(store, args.agent)
        store.set_agent_disabled(agent["agentId"], command == "agent-disable")
        _emit({"ok": True, "agentId": agent["agentId"], "disabled": command == "agent-disable"})
        return 0

    if command == "code-mint":
        agent = _resolve_agent(store, args.agent)
        minted = store.mint_pair_code(agent["agentId"], int(args.ttl_seconds) * 1000)
        minted["qrPayload"] = qr_payload(args.relay, minted["code"], agent["agentId"])
        _emit(minted)
        return 0

    if command == "invite-mint":
        ttl_ms = int(args.ttl_seconds) * 1000
        count = max(1, int(args.count))
        minted = [store.mint_invite(ttl_ms, args.note) for _ in range(count)]
        for invite in minted:
            invite["enrollCommand"] = enroll_command(args.relay, invite["code"])
        _emit(minted[0] if count == 1 else minted)
        return 0

    if command == "invite-revoke":
        result = store.revoke_invite(args.code)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if not result.get("revoked"):
            raise SystemExit(1)
        return

    if command == "invite-list":
        rows = store.list_invites(include_used=bool(args.all))
        now = now_ms()
        _emit([
            {
                "codeHash": row["codeHash"][:12] + "…",
                "note": row["note"],
                "createdAt": row["createdAt"],
                "expiresAt": row["expiresAt"],
                "expiresInSeconds": max(0, (int(row["expiresAt"]) - now) // 1000),
                "usedAt": row["usedAt"],
                "usedByAgentId": row["usedByAgentId"],
            }
            for row in rows
        ])
        return 0

    if command == "device-list":
        agent_id = _resolve_agent(store, args.agent)["agentId"] if args.agent else None
        rows = store.list_devices(agent_id, include_revoked=bool(args.all))
        # 只**加**字段，不改已有字段名——`scripts/dev/*.mjs` 在解这份 JSON。
        _emit([
            {
                **row,
                "deviceTokenHash": row["deviceTokenHash"][:12] + "…",
                # APNs 令牌同样打码：它是能往这台手机推通知的凭据，而
                # `device-list` 的输出会进终端记录。排障要的是"有没有登记"，
                # 那是下面的 `push.registered`；缺失仍是 None，不是空串。
                "apnsToken": (row["apnsToken"][:8] + "…") if row.get("apnsToken") else None,
                # 推送登记状态。排障第一眼看的就是这一列：环境标错了，
                # 推送会静默收不到（APNs 回 BadDeviceToken）。
                "push": {
                    "registered": bool(row.get("apnsToken")),
                    "env": row.get("apnsEnv"),
                    "turnEnd": bool(row.get("pushTurnEnd")),
                    "attention": bool(row.get("pushAttention")),
                    "updatedAt": row.get("pushUpdatedAt"),
                },
            }
            for row in rows
        ])
        return 0

    if command == "push-test":
        return _push_test(store, args)

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
        # 两个入参都先校验再动库：正文缺/空白、主题超长都在写信之前拒绝，
        # 不能写完半封才报错（那封信已经进库了）。主题不给就沿用用户写的那句。
        letter = _read_body(args)
        if args.subject is not None:
            # 线程不存在时这里返回 False；下面的 append 同样返回 None，
            # 报的还是"thread not found"。
            store.set_feedback_subject(args.thread, args.subject)
        written = store.append_feedback_message(args.thread, letter, author="owner",
                                                format=args.format)
        if written is None:
            _emit({"ok": False, "error": "thread not found"})
            return 1
        _emit({"ok": True, "threadId": args.thread, "messageId": written["messageId"],
               "createdAt": int(written["createdAt"])})
        return 0

    if command == "feedback-notify":
        body = _read_body(args)
        targets = _notify_targets(store, args)
        if not targets:
            # 没有收件人时**连 --yes 也不写库**：留下一条发给零台设备的通知，
            # 会让"发送记录"从此撒谎。
            _emit({"ok": False, "error": "no recipients", "recipients": 0, "devices": []})
            return 1
        if not args.yes:
            _emit({"ok": True, "dryRun": True, "recipients": len(targets), "devices": targets})
            return 0
        notice = store.create_notice(body, args.subject, targets, format=args.format,
                                     created_by="admin.py")
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

    if command == "ops-report":
        _emit(_ops_report(store, max(1, int(args.days))))
        return 0

    if command == "device-revoke":
        if args.token:
            device = store.device_by_token(args.token)
            if device is None:
                raise StoreError("that device token is unknown, revoked, or expired")
            device_id = device["deviceId"]
        elif args.device:
            device_id = args.device
        else:
            raise StoreError("pass --device or --token")
        store.revoke_device(device_id)
        # 库里撤销**就是**这次操作的全部：它是在线世界的事实来源。
        # 在线那台手机由中转自己踢（hub 的「撤销对账」，每
        # DLP_REVOKE_RECONCILE_S 秒一轮）——`admin.py` 是另一个进程，够不着
        # relay 的 hub；拿同一个令牌去打 relay 也不行：库一撤，
        # `device_by_token` 立刻拒掉它（store.py 的 revokedAt 分支），那条路
        # 只会得到静默 401。所以 `--device` 与 `--token` 在这里**结果完全相同**。
        # 为什么不保留"直连踢人"，见 relay/README.md 的 device-revoke 段。
        _emit({
            "ok": True,
            "deviceId": device_id,
            "revoked": True,
            # 给运维的明示：admin 不能、也没有去踢在线设备。
            "detach": "relay-reconcile",
        })
        return 0

    if command == "purge":
        removed = store.purge_expired()
        _emit({"ok": True, "removed": removed})
        return 0

    raise StoreError(f"unhandled command {command}")


def _push_test(store: Store, args: argparse.Namespace) -> int:
    """Send one push on demand and report what Apple said.

    This command exists because the failure mode it diagnoses is invisible from
    the phone: a token registered against the wrong environment is accepted by
    the relay, sent to the wrong APNs host, and answered with
    ``BadDeviceToken`` — the phone simply never buzzes and nothing anywhere says
    why. So this **prints the status and the reason**, and it deliberately
    **ignores "the device is online"**: during the transition period a phone
    usually still holds its socket because of the keep-alive, and refusing to
    send would make the one command that could tell sandbox from production
    useless for its main purpose.

    ``--device`` is a ``deviceId``; a typo is reported as such, not as a
    traceback.
    """
    row = store.device_by_id(args.device)
    if row is None:
        raise StoreError(f"no device {args.device!r}; `device-list` shows the ids")
    if not row.get("apnsToken"):
        raise StoreError(
            f"device {args.device} 没有推送登记（App 启动/开关变化时才会上报）")
    if row.get("revokedAt"):
        raise StoreError(f"device {args.device} 已被撤销，不会再收到推送")

    sender = PushSender.from_env()
    if not sender.enabled:
        raise StoreError(
            "APNs 未配置或已关闭；需要 DLP_APNS_ENABLED=1 与 "
            "DLP_APNS_KEY_PATH/KEY_ID/TEAM_ID/TOPIC（见 deploy/apns.env.example）")

    result = asyncio.run(sender.send(
        device_id=row["deviceId"], token=row["apnsToken"], env=row.get("apnsEnv"),
        kind=args.kind, sid=args.sid, ignore_throttle=True))
    report = {
        "ok": result.ok,
        "deviceId": row["deviceId"],
        "env": row.get("apnsEnv"),
        "kind": args.kind,
        "status": result.status,
        "reason": result.reason,
        "apnsId": result.apns_id,
        "deadToken": result.dead_token,
        "skipped": result.skipped,
    }
    if result.dead_token:
        # 与 relay 在线时的行为一致：Apple 说这个令牌死了，就清掉登记。
        store.clear_push(row["deviceId"])
        report["cleared"] = True
    _emit(report)
    return 0 if result.ok else 1


def _read_body(args: argparse.Namespace) -> str:
    """`--body` 与 `--body-file` 二选一的正文，**原样**返回（不裁剪、不加工）。

    正文进库就是用户看到的那封信：称呼、正文、署名、日期都由拟稿人写全。这里只拦
    "空白正文"——服务端会按 400 拒收，命令侧早一步说清楚比发出去再回滚好。
    """
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
    """一条线程的全部留言；顺手把 `ownerReadAt` 推到最新一条用户消息。

    "owner 已看过"的落点只有这一个字段（`feedback-list` 用它算 `ownerUnread`），所以
    它属于"读"这个动作本身。只前进不后退：回信之后再看一眼，不该把时间拨回去。
    线程不存在返回 None；取件凭据的哈希按仓库口径截断（`invite-list`/`agent-list` 同款）。
    """
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
    """owner 清单的每一行（`feedback-list` 与 `ops-report` 用同一个形状）。

    `subject` 是可选主题，用户没填就是 None（展示层用 `excerpt` 兜底）；
    `ops-report` 的 `feedback.threads[]` 照抄这一份，所以两处永远同形。
    `format` 是 `excerpt` 那条留言（线程首条）的正文格式（FR-034）：线程行不带留言，
    格式只能顺着摘要一起取；`feedback-show` 的每条留言各自带自己的 `format`。
    """
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
    """官方回信骨架：称呼 / 正文 / 署名 / 日期四部分（打印，不写库）。

    形态按**真信件**写，不写「称呼：」「正文：」这类字段名：这些字会原样出现在手机上的
    信件卡片与列表摘要里，字段名看起来像表单而不像回信（2026-10-12 在仿真器上看到
    「称呼：你好」成了列表标题之后改的）。正文一律原样入库，骨架就是给拟稿人填空的
    （FR-015）。
    """
    day = str(local_day(now_ms() / 1000))
    return (
        "<对用户的称呼>：\n"
        "\n"
        "<回信正文：先说结论，再说下一步>\n"
        "\n"
        f"{signature}\n"
        f"{day[:4]}-{day[4:6]}-{day[6:]}\n"
    )


def _notify_targets(store: Store, args: argparse.Namespace) -> list[str]:
    """通知的收件人：`--all`（默认）是全部未撤销设备，`--device` 指定时只发这几台。

    点名一台不存在或已撤销的设备是**错误**，不静默丢弃：这条命令的全部意义就是别把
    通知发错人，打错一个 deviceId 却看到"发出去了"是最糟的结果。
    """
    if args.all or not args.device:
        return [row["deviceId"] for row in store.list_devices(include_revoked=False)]
    known = {row["deviceId"] for row in store.list_devices(include_revoked=False)}
    wanted = list(dict.fromkeys(device for device in args.device if device))
    unknown = [device for device in wanted if device not in known]
    if unknown:
        raise StoreError(f"这些设备不存在或已撤销：{', '.join(unknown)}")
    return wanted


def _recent_days(days: int) -> list[int]:
    """最近 N 天的本地日序号（含今天），从早到晚。"""
    now = now_ms() / 1000
    return sorted({local_day(now - offset * 86_400) for offset in range(max(1, int(days)))})


def _device_report_row(row: dict[str, Any]) -> dict[str, Any]:
    """`device-list` 的全列 + 打码，另加一个 `revoked` 布尔（日报表格按它分色）。

    `device-list` 那份输出保持原样不动（脚本在解它）；这里是同口径的第二处渲染。
    """
    return {
        **row,
        "deviceTokenHash": row["deviceTokenHash"][:12] + "…",
        "apnsToken": (row["apnsToken"][:8] + "…") if row.get("apnsToken") else None,
        "revoked": bool(row.get("revokedAt")),
        "push": {
            "registered": bool(row.get("apnsToken")),
            "env": row.get("apnsEnv"),
            "turnEnd": bool(row.get("pushTurnEnd")),
            "attention": bool(row.get("pushAttention")),
            "updatedAt": row.get("pushUpdatedAt"),
        },
    }


def _feedback_report(store: Store, threads: list[dict[str, Any]]) -> dict[str, Any]:
    """反馈板块：窗口内的新增/待回复/已回复、首复中位小时数、线程清单。"""
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
        "threads": threads,
    }


def _usage_report(store: Store, days: int) -> dict[str, Any]:
    """用量板块：每日出口字节/连接数/设备数、按账号（降序）、窗口内的总计。

    `usage_totals(by="account")` 是**按天**一行，同一个账号在窗口里会出现多次；日报要的是
    「这个窗口里谁用得最多」，所以先按 `accountId` 合并再排序（2026-10-12 第一次跑生产日报时
    看到「Jayant：4.7 GB / Jayant：3.1 GB / …」一长串同名条目之后改的），并且只留前
    `REPORT_TOP_ACCOUNTS` 名——原始数据是给人看的，不是导库。
    """
    accounts = store.usage_totals(days=days, by="account")
    per_day: dict[int, dict[str, int]] = {}
    for row in store.usage_totals(days=days, by="device"):
        entry = per_day.setdefault(int(row["day"]),
                                   {"egressBytes": 0, "connections": 0, "devices": 0})
        entry["egressBytes"] += int(row["egressBytes"])
        entry["connections"] += int(row["connections"])
        entry["devices"] += int(row["devices"])
    empty = {"egressBytes": 0, "connections": 0, "devices": 0}
    merged: dict[str, dict[str, Any]] = {}
    for row in accounts:
        account = merged.setdefault(row["accountId"], {"accountId": row["accountId"],
                                                       "name": row["name"], "egressBytes": 0})
        account["egressBytes"] += int(row["egressBytes"])
    ranked = sorted(merged.values(), key=lambda entry: entry["egressBytes"], reverse=True)
    return {
        "perDay": [{"day": day, **per_day.get(day, empty)} for day in _recent_days(days)],
        "topAccounts": ranked[:REPORT_TOP_ACCOUNTS],
        "totals": {"egressBytes": sum(int(row["egressBytes"]) for row in accounts),
                   "connections": sum(int(row["connections"]) for row in accounts)},
    }


def _is_debug_device(row: dict[str, Any]) -> bool:
    """调试设备：仓库自己的命名规则（`DSH-` 前缀）与测试台造出来的那几类。

    为什么日报要剔除：历次用例的 `DSH-Test`/`DSH-Sweep`/`DSH-Runner` 与探针设备会让
    「每日新增设备」出现 200+/天的假高峰（2026-10-12 第一版日报上真发生了），
    而那正是 owner 用来判断"有没有新用户"的图。
    """
    name = str(row.get("name") or "")
    model = str(row.get("model") or "")
    return name.startswith("DSH-") or model in {"Node", "test-harness", "simulator"}


def _ops_report(store: Store, days: int) -> dict[str, Any]:
    """日报的四个板块：反馈 / 设备 / 用量 / 邀请码（本机渲染，服务器上不画图）。

    `--days` 是窗口（本地日，含今天）：反馈只数窗口内**新建**的线程，用量与每日新增
    设备也只覆盖窗口；邀请码的账是全量（码用没用完跟窗口无关）。空库照样四个板块
    齐全、计数为 0——日报每天都会跑。

    设备板块只统计**真实设备**（剔除 `_is_debug_device`），被剔除的行数放在 `debug` 里，
    这样"图上是用户、库里有多少调试行"两件事都看得见。
    """
    stamp = now_ms()
    threads = _feedback_rows(store, status=None, since_ms=stamp - days * 86_400_000,
                             limit=REPORT_THREAD_LIMIT)
    devices = store.list_devices(include_revoked=True)
    real = [row for row in devices if not _is_debug_device(row)]
    live = [row for row in real if not row.get("revokedAt")]
    created_per_day: dict[int, int] = {}
    for row in real:
        day = local_day(int(row["createdAt"]) / 1000)
        created_per_day[day] = created_per_day.get(day, 0) + 1
    return {
        "ok": True,
        "generatedAt": stamp,
        "days": days,
        "feedback": _feedback_report(store, threads),
        "devices": {
            "paired": len(live),
            "active7d": len([row for row in live
                             if int(row.get("lastSeenAt") or 0) >= stamp - 7 * 86_400_000]),
            "revoked": len(real) - len(live),
            "debug": len(devices) - len(real),
            "newPerDay": [{"day": day, "count": created_per_day.get(day, 0)}
                          for day in _recent_days(days)],
            # 只列**未撤销的真实设备**，按最近在线倒序取前 `REPORT_DEVICE_LIMIT` 台：
            # 全量列表在生产库上是 1900+ 行（历次调试配对都还在），日报会被它撑爆
            # （2026-10-12 第一版 327 KB，正文里 90% 是 DSH-Test/DSH-Sweep 的历史行）。
            "list": [_device_report_row(row) for row in
                     sorted(live, key=lambda row: int(row.get("lastSeenAt") or row["createdAt"]),
                            reverse=True)[:REPORT_DEVICE_LIMIT]],
        },
        "usage": _usage_report(store, days),
        "invites": {**store.invite_totals(), "enrollments": store.list_enrollments()},
    }


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    store = Store(args.db)
    try:
        return run(args, store)
    except StoreError as error:
        sys.stderr.write(f"admin.py: {error}\n")
        return 1
    finally:
        store.close()


if __name__ == "__main__":
    raise SystemExit(main())
