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
import datetime
import json
import os
import re
import subprocess
import sys
from typing import Any
from urllib.parse import quote

from hub import dead_device_warn_threshold_from_env
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

#: 日报「今日」板块里每类明细最多这么多条。服务端先给个界（正文是要塞进通知投到手机上的，
#: 报告本身越短越好）；渲染层还会再截到手机上看得完的条数。
REPORT_TODAY_LIMIT = 20

#: 模拟器 / 测试台来源上报的"机型"：日报的反馈板块按它把验收单剔出去
#: （`arm64` 是 iOS 模拟器，`deploy-check` 是部署演练脚本用的名字）。
TEST_DEVICE_MODELS = {"arm64", "x86_64", "deploy-check", "Node", "simulator", "test-harness"}

#: 留存要按"账号第一次活跃"分队列，得读窗口以前的历史用量；这是查询上界（天）。
RETENTION_HISTORY_DAYS = 400


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

    device_hygiene = subs.add_parser(
        "device-hygiene",
        help="count in-use / revoked / expired device records (read-only)")
    device_hygiene.add_argument("--agent", help="only this agent (default: the whole database)")

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
                                      help="send one notice to accounts (dry run unless --yes)")
    feedback_notify.add_argument("--body")
    feedback_notify.add_argument("--body-file")
    feedback_notify.add_argument("--subject")
    feedback_notify.add_argument("--format", choices=FEEDBACK_FORMATS,
                                 default=DEFAULT_FEEDBACK_FORMAT,
                                 help="body format: text (Markdown on the phone, the default)"
                                      " or html (the locked-down container)")
    feedback_notify.add_argument("--account", action="append", default=[],
                                 help="accountId, may be repeated")
    feedback_notify.add_argument("--all", action="store_true",
                                 help="every account; must be asked for explicitly")
    feedback_notify.add_argument("--yes", action="store_true", help="actually write it")

    feedback_delete = subs.add_parser("feedback-delete",
                                      help="delete a thread and its messages (needs --yes)")
    feedback_delete.add_argument("--thread", required=True)
    feedback_delete.add_argument("--yes", action="store_true")

    ops_report = subs.add_parser("ops-report", help="raw data for the daily operations report")
    ops_report.add_argument("--days", type=int, default=30)
    ops_report.add_argument("--as-of", dest="as_of", default="now",
                            help="now (default) | yesterday | YYYY-MM-DD；后两者按那一整天算")
    ops_report.add_argument("--journal-unit", dest="journal_unit", default=DEFAULT_JOURNAL_UNIT,
                            help="systemd 单元名：过去 72 小时分布图从它的日志重建（默认 dsh-relay）")
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
        # 一台设备要回答的"版本组合"有三段：手机（下面每行的 appVersion）、
        # 连接器与 DSH（这台电脑那一行的两列）。三段放在同一份输出里，
        # 排障时一条命令就够，不必再去 join agent-list。
        agents = {row["agentId"]: row for row in store.list_agents()}
        # 只**加**字段，不改已有字段名——`scripts/dev/*.mjs` 在解这份 JSON。
        _emit([
            {
                **_with_versions(row, agents),
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
                # 这台设备连的那台电脑跑的是哪套版本（见 `_with_versions`）。
                # None = 连接器还没报过（老版本，或这台设备从没连上过那台电脑）。

            }
            for row in rows
        ])
        return 0

    if command == "device-hygiene":
        return _device_hygiene(store, args)

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
        targets = _notify_accounts(store, args)
        if not targets:
            # 没有收件人时**连 --yes 也不写库**：留下一条发给零个账号的通知，
            # 会让"发送记录"从此撒谎。
            _emit({"ok": False, "error": "no recipients", "recipients": 0, "accounts": []})
            return 1
        if not args.yes:
            _emit({"ok": True, "dryRun": True, "recipients": len(targets), "accounts": targets})
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
        _emit(_ops_report(store, max(1, int(args.days)), as_of=_resolve_as_of(args.as_of),
                          journal_unit=args.journal_unit))
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


def _device_hygiene(store: Store, args: argparse.Namespace) -> int:
    """数一数设备记录：在用 / 已撤销 / 已过期（只读，不删任何东西）。

    为什么需要它：已撤销与已过期的设备行会在**每次连接器连上时**被逐条重放给
    连接器（`hub.py:_tell_agent_about_the_gone`），2012 条曾把连接器的处理链堵住
    （maintainers/ANALYSIS-20261012-connector-flap.md）。`device-list --all` 能看到
    明细，但"现在攒了多少、离告警线还有多远"需要一个数字——这就是那个数字。
    真删是另一件事：`purge-revoked-devices.py`（默认预演，`--apply` 才删）。

    阈值是**按 agent** 判的（告警发生在某个 agent 的连接器连上时），所以只有
    `--agent` 点名了才给 `overThreshold` 的结论；全局视图里它是 `None`，不是 `false`
    ——"没判"和"没超"在运维读日志时是两回事。
    """
    agent_id = _resolve_agent(store, args.agent)["agentId"] if args.agent else None
    counts = store.device_hygiene(agent_id)
    threshold = dead_device_warn_threshold_from_env()
    _emit({
        "ok": True,
        **counts,
        "warnThreshold": threshold,
        "overThreshold": (counts["dead"] > threshold) if (agent_id and threshold) else None,
        "hint": "purge-revoked-devices.py --db <db> --all-agents --apply "
                "（去掉 --apply 只是预演）",
    })
    return 0


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


def _notify_accounts(store: Store, args: argparse.Namespace) -> list[str]:
    """通知的收件账号：`--account` 点名（可重复），或**显式** `--all` 发给全部账号。

    点名一个不存在的账号是**错误**，不静默丢弃：这条命令的全部意义就是别把通知发错人，
    打错一个 accountId 却看到"发出去了"是最糟的结果。设备维度已按 019 删除：
    收件人是账号，账号下有几台设备、哪台在线，都不影响投递。

    **两个都不给也是错误**（019 收紧了这条）：以前"不给参数"等于"发给所有人"，
    一次手滑就把测试正文广播给全中转的账号。全量群发必须是显式写下来的动作。
    """
    if args.account:
        wanted = list(dict.fromkeys(account for account in args.account if account))
        unknown = [account for account in wanted if store.get_account(account) is None]
        if unknown:
            raise StoreError(f"这些账号不存在：{', '.join(unknown)}")
        return wanted
    if not args.all:
        raise StoreError("必须点名收件人：--account <accountId>（可重复），或显式 --all 发给全部账号")
    return [row["accountId"] for row in store.list_accounts()]


def _recent_days(days: int, *, end: int | None = None) -> list[int]:
    """最近 N 天的本地日序号（含 `end` 所在的那一天），从早到晚。`end` 默认此刻。"""
    at = (now_ms() if end is None else int(end)) / 1000
    return sorted({local_day(at - offset * 86_400) for offset in range(max(1, int(days)))})


#: 日报「过去 72 小时」分布图的窗口长度。
REPORT_ACTIVITY_HOURS = 72

#: 版本分布的窗口：只看最近 48 小时有设备连接的用户（owner 2026-10-17 定）。
#: 全量设备里有一半是几周没上线的历史行，混进来以后「还有多少人在旧版」显得很严重。
REPORT_VERSION_HOURS = 48

#: systemd 单元名：只有它才写得出「谁在哪一小时连着」。可用 `--journal-unit` 覆盖。
DEFAULT_JOURNAL_UNIT = "dsh-relay"

#: 日志里的设备连接事件。认四种：
#: - `attached to agent …`：连上；
#: - `attached again while its previous socket is still open`：重连顶掉旧 socket（先把旧的算断开）；
#: - `detached (socket closed) / (revoked)`：断开；
#: - `closed a socket that had already been replaced`：旧 socket 的收尾，**忽略**，否则会把
#:   刚重连上的那台设备记成离线。
#:
#: 为什么不用 agent（电脑）的连接事件：电脑常年开着，连接器一直连着，但用户没用 App，
#: 那不该算活跃。owner 要的是「有设备连着」这个口径，与头牌的「活跃用户」一致。
_DEVICE_EVENT = re.compile(
    r"device (dev_[A-Za-z0-9]+) .*?(attached to agent|attached again|detached|"
    r"closed a socket that had already been replaced)")
_AGENT_IN_LINE = re.compile(r"agent (agt_[A-Za-z0-9]+)")


def _version_report(store: Store, *, since_ms: int, until_ms: int,
                    devices: dict[str, dict[str, Any]], debug_ids: set[str],
                    known_ids: set[str], external: set[str]) -> list[dict[str, Any]]:
    """版本分布：近 48 小时**有设备用量行**的账号装在哪个版本。

    口径与头牌「活跃账号」同一条（owner 2026-10-17 定）：只有真的用 App 连过中转的设备
    才算，不能拿 `devices.lastSeenAt`（连接器重连也会刷它）。窗口按用量行的 `lastSeenAt`
    卡，不按自然日——48 小时跨两天，按天取会把窗口拉长。

    设备数按**设备行**（重装/换机会多一行），账号数按 `accountId` 去重；两个数字不相等
    是常态，页面上分开写。`appVersion` 为空的老行归到 `None`，渲染层写「未知」。
    """
    start_day = local_day(int(since_ms) / 1000)
    end_day = local_day(int(until_ms) / 1000)
    grouped: dict[str | None, dict[str, Any]] = {}
    seen_devices: set[str] = set()
    for day in range(int(start_day), int(end_day) + 1):
        for row in store.usage_rows(day):
            device_id = row["deviceId"]
            if device_id in debug_ids or device_id in seen_devices:
                continue
            if _is_orphan_usage(row, known_ids=known_ids, external=external):
                continue
            # 夹到锚点：跨日那一跳写下的用量行可能带着第二天零点几秒的 lastSeenAt，
            # 日报会把"昨天"的表格印成"10-19 00:00"（2026-10-19 实测）。
            seen = min(int(row.get("lastSeenAt") or 0), int(until_ms))
            if seen < int(since_ms):
                continue
            seen_devices.add(device_id)
            device = devices.get(device_id) or {}
            version = (device.get("appVersion") or "").strip() or None
            entry = grouped.setdefault(version, {"appVersion": version, "devices": 0,
                                                 "accounts": set(), "lastSeenAt": 0})
            entry["devices"] += 1
            account_id = row.get("accountId") or device.get("accountId")
            if account_id:
                entry["accounts"].add(account_id)
            entry["lastSeenAt"] = max(entry["lastSeenAt"], seen)
    return sorted(
        ({"appVersion": entry["appVersion"], "devices": entry["devices"],
          "accounts": len(entry["accounts"]), "lastSeenAt": entry["lastSeenAt"] or None}
         for entry in grouped.values()),
        key=lambda item: (-item["devices"], item["appVersion"] or ""))


def _read_journal(unit: str, since_ms: int, until_ms: int) -> list[str] | None:
    """取中转日志。取不到（没装 systemd、无 journal 读权限、单元名不对）时返回 `None`——
    日报宁可少一张图，也不能因为一个可选板块整份生成失败。
    """
    since = datetime.datetime.fromtimestamp(since_ms / 1000).strftime("%Y-%m-%d %H:%M:%S")
    until = datetime.datetime.fromtimestamp(until_ms / 1000).strftime("%Y-%m-%d %H:%M:%S")
    try:
        completed = subprocess.run(  # noqa: S603 - 固定的只读运维命令，参数不是用户输入
            ["journalctl", "-u", unit, "--since", since, "--until", until,
             "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.splitlines()


def _parse_journal_time(line: str) -> int | None:
    """`short-iso` 行的前缀是 `2026-10-17T15:44:16+0800`，转成毫秒时间戳。"""
    stamp = line.split(" ", 1)[0]
    try:
        parsed = datetime.datetime.fromisoformat(stamp)
    except ValueError:
        return None
    return int(parsed.timestamp() * 1000)


def _hourly_activity(hours: int, end_ms: int, devices: dict[str, dict[str, Any]],
                     agents: dict[str, dict[str, Any]],
                     *, lines: list[str] | None = None,
                     unit: str = DEFAULT_JOURNAL_UNIT) -> list[dict[str, Any]] | None:
    """过去 `hours` 小时里，每个本地小时有多少个活跃用户、多少台设备在连。

    口径（owner 2026-10-17 定）：**只算有设备连接的用户**，电脑的连接器一直挂着不算。
    这与头牌「活跃用户」一致——电脑开着但没人用 App，不该在图上占一格。

    数据从 systemd 日志里的 `device … attached / detached` 重建：中转自己只把用量按
    **天**记账，没有小时粒度，而日报要的是 72 小时的形状。日志是唯一的现成来源；
    取不到就返回 `None`，由渲染层写「没有日志数据」，不编数字。

    返回按小时升序：`accounts` 是那一小时内有设备在线的**账号数**（同账号多台设备只算
    一个），`devices` 是在线的设备台数。
    """
    hour_ms = 3_600_000
    end = int(end_ms)
    start = end - hours * hour_ms
    raw = lines if lines is not None else _read_journal(unit, start, end)
    if raw is None:
        return None

    # 同一台设备同一时刻只有一条 socket：新连接（含 `attached again`）先关掉上一条，
    # `closed a socket that had already been replaced` 是旧 socket 的收尾、不是断开，忽略。
    open_at: dict[str, tuple[int, str | None]] = {}
    spans: list[tuple[int, int, str, str | None]] = []
    for line in raw:
        event = _DEVICE_EVENT.search(line)
        if event is None:
            continue
        device_id, kind = event.group(1), event.group(2)
        if kind == "closed a socket that had already been replaced":
            continue
        at = _parse_journal_time(line)
        if at is None:
            continue
        at = min(max(at, start), end)
        agent_id = _AGENT_IN_LINE.search(line)
        agent = agent_id.group(1) if agent_id else None
        if kind.startswith("attached"):
            if device_id in open_at:
                opened, previous_agent = open_at.pop(device_id)
                spans.append((opened, at, device_id, previous_agent))
            open_at[device_id] = (at, agent)
        else:
            previous = open_at.pop(device_id, None)
            if previous is not None:
                spans.append((previous[0], at, device_id, previous[1] or agent))
    for device_id, (opened, agent) in open_at.items():   # 窗口末尾还连着的，算到 end
        spans.append((opened, end, device_id, agent))

    # 账号来源：设备行优先（设备可能已换账号？不会，但行被清理过时用同一条日志里的 agent 兜底）。
    def account_of(device_id: str, agent_id: str | None) -> str | None:
        device = devices.get(device_id)
        # 调试设备（DSH- 前缀、模拟器机型）不进日报，与其它板块同一口径；
        # 不能走下面的 agent 兜底，否则它们会被算到 owner 账号头上。
        if device is not None and _is_debug_device(device):
            return None
        if device and device.get("accountId"):
            return device["accountId"]
        owner_agent = (device or {}).get("agentId") or agent_id
        return (agents.get(owner_agent) or {}).get("accountId") if owner_agent else None

    # 部署时区是整小时偏移（Asia/Shanghai，+08:00），所以纪元小时边界就是本地小时边界。
    first = (start // hour_ms) * hour_ms
    buckets = {at: {"hourStartAt": at, "accounts": set(), "devices": set()}
               for at in range(first, end + 1, hour_ms)}
    for opened, closed, device_id, agent_id in spans:
        if closed < opened:
            continue
        account_id = account_of(device_id, agent_id)
        if not account_id:                             # 设备行被清理、日志也没带 agent：无法归属
            continue
        cursor = (opened // hour_ms) * hour_ms
        while cursor <= closed:
            bucket = buckets.get(cursor)
            if bucket is not None:
                bucket["devices"].add(device_id)
                bucket["accounts"].add(account_id)
            cursor += hour_ms
    return [{"hourStartAt": bucket["hourStartAt"],
             "accounts": len(bucket["accounts"]),
             "devices": len(bucket["devices"])}
            for bucket in (buckets[at] for at in sorted(buckets))]


def _resolve_as_of(value: str | None, *, now: int | None = None) -> int | None:
    """`ops-report --as-of` 的取值 → 锚点毫秒时间戳（`None` = 就用此刻）。

    三种取值：

    - `now`（默认）：到此刻为止的部分数据，白天手工看用这个；
    - `yesterday`：**刚过去的一整天**。日报在 00:00 跑，若按"今天"算，此刻新的一天刚开头，
      「今日」板块全是 0；锚到昨天 23:59:59.999 才是刚结束那天的完整数据；
    - `YYYY-MM-DD`：指定那一天的一整天（补跑历史日报用）。

    锚点取当天最后一毫秒：`today` 板块与 `--days` 窗口都以锚点所在的本地日为界，
    所以「今日出口」与「最近 N 天」表里同一行的数字必然一致。
    """
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
    return _day_start_ms(_day_shift(day, 1)) - 1


def _with_versions(device: dict[str, Any],
                   agents: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """把**这台设备连的那台电脑**的版本并进设备行（三段版本要能一条命令看全）。

    手机那段在设备行的 `appVersion`（随每次连接刷新）；连接器与 DSH 在 `agents` 行
    （控制帧上报，变化才写）。没上报过就是 None——不拿上一次的值补。
    """
    agent = agents.get(device.get("agentId")) or {}
    return {
        **device,
        "connectorVersion": agent.get("connectorVersion"),
        "hostVersion": agent.get("hostVersion"),
        "versionsAt": agent.get("versionsAt"),
    }


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


def _feedback_report(store: Store, threads: list[dict[str, Any]],
                     test_count: int = 0) -> dict[str, Any]:
    """反馈板块：窗口内的新增/待回复/已回复、首复中位小时数、线程清单。

    `test_count` 是被剔除的测试提交条数（模拟器来源或调试设备提的），只报个数不进清单：
    日报要回答"用户遇到了什么"，用例自己造的验收单不是用户反馈。
    """
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


def _is_test_thread(row: dict[str, Any], debug_ids: set[str]) -> bool:
    """测试提交：调试设备提的，或来自模拟器/测试台（机型是 `arm64`、`deploy-check` 这类）。

    为什么要单独判来源：多数验收单是模拟器提的，deviceId 不在调试设备表里（设备早就撤了
    或换了），只有 `source.deviceModel` 认得出。2026-10-12 的日报里 16 条反馈有 15 条是
    这么来的，混在"用户反馈"里看不出真问题。
    """
    device = row.get("deviceId") or (row.get("source") or {}).get("deviceId")
    if device and device in debug_ids:
        return True
    model = str((row.get("source") or {}).get("deviceModel") or "")
    return model in TEST_DEVICE_MODELS


def _is_test_enrollment(row: dict[str, Any]) -> bool:
    """用仓库自己的调试命名（`DSH-` 前缀）登记的账号——历次用例跑的邀请码流程。"""
    return (str(row.get("accountName") or "").startswith("DSH-")
            or str(row.get("agentName") or "").startswith("DSH-"))


def _is_orphan_usage(row: dict[str, Any], *, known_ids: set[str],
                     external: set[str]) -> bool:
    """这条用量行的设备行已经没了、账号又是内部的——报表里当调试设备剔除。

    为什么会有这种行：`maintainers/purge-revoked-devices.py` 会删掉已撤销/已过期的
    设备行（不删的话连接器每次重连都要被灌几千帧"回不来的设备"，见
    maintainers/ANALYSIS-20261012-connector-flap.md），但按约定保留 `usageDaily`
    ——账目不能丢。代价就是历史用量里留下找不到设备主体的行：2026-10-13 实测
    近 30 天有 636 台这样的设备、29.5 GB，全部属于 owner 自用账号（历次用例的
    模拟器设备），把「活跃手机」「每日出口」抬到真实值的两倍以上。

    只剔内部账号（不在邀请码登记名单里）的孤儿行：外部用户自己解绑/过期后留下的
    孤儿行是真人真事，历史该保留。`usage` 命令照旧读全量——那是账本，这是视图。
    """
    return row["deviceId"] not in known_ids and row.get("accountId") not in external


def _usage_scan(store: Store, days: int, debug_ids: set[str],
                names: dict[str, str | None],
                *, end: int | None = None, known_ids: set[str] | None = None,
                external: set[str] | None = None) -> tuple[list[dict[str, Any]],
                                                           list[dict[str, Any]],
                                                           dict[int, set[str]]]:
    """窗口内按天读一遍 `usageDaily`，同时给出三样东西（读一次，三个板块共用）。

    - `series`：每日出口字节/连接数/设备数；
    - `ranked`：按账号合并排名（出口、连接、设备数、最近一次构建）；
    - `active_by_day`：每天活跃的账号集合（留存用它，不重复查库）。

    只统计**真实设备**（剔除 `_is_debug_device`）与**内部账号的孤儿用量行**
    （`_is_orphan_usage`）。设备板块从 2026-10-12 起就这么做了，流量这里必须同口径：
    不然同一天会在「今日」和「最近 N 天」里给出两个不同的数字（2026-10-12 实测：
    今日 4.0 GB，同一天在 30 天表里 4.4 GB，差的正是历次用例的 DSH-* 设备）。
    `usage` 命令保持全量记账不动——那是账本，日报是给人看的视图。
    """
    per_day: dict[int, dict[str, int]] = {
        day: {"egressBytes": 0, "connections": 0, "devices": 0} for day in _recent_days(days, end=end)}
    active_by_day: dict[int, set[str]] = {day: set() for day in per_day}
    merged: dict[str, dict[str, Any]] = {}
    seen_devices: dict[str, set[str]] = {}
    for day in per_day:
        for row in store.usage_rows(day):
            if row["deviceId"] in debug_ids:
                continue
            if _is_orphan_usage(row, known_ids=known_ids or set(), external=external or set()):
                continue
            entry = per_day[day]
            entry["egressBytes"] += int(row["egressBytes"])
            entry["connections"] += int(row["connections"])
            entry["devices"] += 1
            account_id = row["accountId"]
            if account_id:
                active_by_day[day].add(account_id)
            account = merged.setdefault(account_id, {"accountId": account_id,
                                                     "name": names.get(account_id),
                                                     "egressBytes": 0, "connections": 0,
                                                     "lastSeenAt": None, "lastBuild": None})
            account["egressBytes"] += int(row["egressBytes"])
            account["connections"] += int(row["connections"])
            seen_devices.setdefault(account_id, set()).add(row["deviceId"])
            # `lastSeenAt`/`lastBuild` 取窗口内最后出现过的那次（求和没意义）。
            seen = int(row["lastSeenAt"] or 0)
            if seen > int(account["lastSeenAt"] or 0):
                account["lastSeenAt"] = seen or None
                account["lastBuild"] = row.get("lastBuild") or account["lastBuild"]
    for account_id, account in merged.items():
        account["devices"] = len(seen_devices.get(account_id, ()))
    ranked = sorted(merged.values(), key=lambda entry: entry["egressBytes"], reverse=True)
    # 每天的「活跃用户」= 那天有中转连接的账号数（同一账号的多台手机只算一个）。owner
    # 2026-10-17 定的口径：活跃用户按账号算，日报头牌的 `devices` 仍是设备行数（重装会多行）。
    for day, entry in per_day.items():
        entry["accounts"] = len(active_by_day[day])
    return ([{"day": day, **per_day[day]} for day in sorted(per_day)], ranked, active_by_day)


def _usage_report(series: list[dict[str, Any]],
                  ranked: list[dict[str, Any]],
                  active_by_day: dict[int, set[str]],
                  first_seen: dict[str, int]) -> dict[str, Any]:
    """用量板块的 JSON：每日用量、账号排名（合并到一行）、窗口总计与派生指标。

    合并与剔除都在 `_usage_scan` 里做过：同一个账号在窗口里出现多次要并成一行再排名
    （2026-10-12 第一版日报的"出口流量前几名"是一长串同名条目），并且只留前
    `REPORT_TOP_ACCOUNTS` 名——原始数据是给人看的，不是导库。

    `activeAccounts` / `activeAccounts7d` 是窗口内（与最近 7 天内）**账号**口径的活跃用户：
    一天的账号数不能相加求并集，所以两个数字都在这里按账号集合算，渲染层不自己拼。

    `perDay[].newAccounts` / `returningAccounts` 把每天的活跃账号拆成两段（owner 2026-10-19
    定）：新增 = 首次活跃日就在这一天的账号，回访 = 当天活跃的其余账号。两个数在这里算，
    渲染层只读——否则同一个"谁是新用户"会在服务端与本机脚本各算一套，口径迟早漂。
    """
    peak = max(series, key=lambda entry: int(entry["egressBytes"])) if series else None
    total = sum(int(entry["egressBytes"]) for entry in series)
    active_all: set[str] = set().union(*active_by_day.values()) if active_by_day else set()
    last7 = sorted(active_by_day)[-7:]
    active_7d: set[str] = set().union(*[active_by_day[day] for day in last7]) if last7 else set()
    for entry in series:
        day = int(entry["day"])
        active = active_by_day.get(day, set())
        fresh = {account for account in active if first_seen.get(account) == day}
        entry["newAccounts"] = len(fresh)
        entry["returningAccounts"] = len(active) - len(fresh)
    return {
        "perDay": series,
        "topAccounts": ranked[:REPORT_TOP_ACCOUNTS],
        "totals": {"egressBytes": total,
                   "connections": sum(int(entry["connections"]) for entry in series)},
        # 派生指标在服务端算：口径只有一处，渲染层只负责显示（也免得本机脚本各算一套）。
        "averagePerDay": round(total / len(series)) if series else 0,
        "peakDay": ({"day": peak["day"], "egressBytes": int(peak["egressBytes"])} if peak else None),
        "activeDays": len([entry for entry in series if int(entry["egressBytes"]) > 0]),
        "activeAccounts": len(active_all),
        "activeAccounts7d": len(active_7d),
    }


def _ratio(active: int, cohort: int) -> float | None:
    return round(active / cohort, 3) if cohort else None


def _day_shift(day: int, offset: int) -> int:
    """本地日序号加减天数。跨月跨年都要对：`20261030 + 7` 是 `20261106`，不是 `20261037`。"""
    date = datetime.datetime.strptime(str(day), "%Y%m%d").date() + datetime.timedelta(days=offset)
    return int(date.strftime("%Y%m%d"))


def _day_gap(later: int, earlier: int) -> int:
    """两个本地日序号之间差几天（`later - earlier`）。同理不能用整数相减。"""
    fmt = "%Y%m%d"
    return (datetime.datetime.strptime(str(later), fmt).date()
            - datetime.datetime.strptime(str(earlier), fmt).date()).days


def _iso_week(day: int) -> tuple[int, int]:
    """本地日序号 → (ISO 年, ISO 周)。留存按自然周分队列，跨年也分得开。"""
    date = datetime.datetime.strptime(str(day), "%Y%m%d").date()
    year, week, _ = date.isocalendar()
    return year, week


def _retention_report(store: Store, *, days: int, stamp: int, external: set[str],
                      active_by_day: dict[int, set[str]],
                      first_seen: dict[str, int]) -> dict[str, Any]:
    """留存板块：只算**用邀请码登记的外部账号**（口径与 maintainers 里的活跃/新增一致）。

    owner 自用账号与历次用例账号都不算——它们天天在用，混进来会把留存率抬成一条平线。

    四个口径：
    - `users`：今日 / 近 7 天 / 近 30 天活跃的外部账号数，外加"近 7 天 ÷ 近 30 天"的粘性；
    - `d1` / `d7`：按**首次活跃日**分队列，次日 / 第 7 天是否又活跃。只统计留得下完整观察
      期的队列（首次活跃日 ≤ 今天-1 / 今天-7），队列大小与活跃数一起给出，避免只看到一个
      百分比却不知道分母；
    - `activation`：近 30 天用邀请码登记的账号里，登记后 7 天内连过中转的比例；
    - `weeks`：最近几个自然周的分周队列，次周留存（只给已经过完次周的队列）。

    活跃 = 当天在 `usageDaily` 里出现过（即当天有过中转连接），与 `usage` 的口径一致。
    """
    window = sorted(active_by_day)
    if not window:
        return {"scope": "external", "users": {}, "d1": None, "d7": None,
                "activation": None, "weeks": []}
    today = window[-1]
    start = window[0]
    today_set = active_by_day.get(today, set()) & external
    week = set().union(*[active_by_day[day] for day in window[-7:]]) & external
    month = set().union(*[active_by_day[day] for day in window]) & external

    def cohort(gap: int) -> dict[str, Any] | None:
        members = [account for account in external
                   if first_seen.get(account) is not None
                   and start <= first_seen[account] <= today - gap]
        if not members:
            return None
        again = [account for account in members
                 if account in active_by_day.get(_day_shift(first_seen[account], gap), set())]
        return {"rate": _ratio(len(again), len(members)),
                "cohort": len(members), "active": len(again)}

    enrollments = [row for row in store.list_enrollments()
                   if not _is_test_enrollment(row)
                   and row.get("accountId") in external]
    recent = [row for row in enrollments if int(row.get("usedAt") or 0) >= _day_start_ms(start)]
    observable = [row for row in recent
                  if _day_shift(local_day(int(row["usedAt"]) / 1000), 7) <= today]
    activated = [row for row in observable
                 if first_seen.get(row["accountId"]) is not None
                 and 0 <= _day_gap(first_seen[row["accountId"]],
                                   local_day(int(row["usedAt"]) / 1000)) <= 7]

    buckets: dict[tuple[int, int], set[str]] = {}
    for account in external:
        day = first_seen.get(account)
        if day is not None and day >= start:
            buckets.setdefault(_iso_week(day), set()).add(account)
    weeks = []
    for (year, number), members in sorted(buckets.items()):
        followers = {day for day in window if _iso_week(day) == (year, number + 1)}
        # 次周还没过完就不给留存率：那一周只走到一半，数字只会虚低。
        if not followers or max(followers) >= today:
            continue
        again = set().union(*[active_by_day[day] for day in followers]) & members
        weeks.append({"week": f"{year}-W{number:02d}", "size": len(members),
                      "active": len(again), "rate": _ratio(len(again), len(members))})
    return {
        "scope": "external",
        "users": {"dau": len(today_set), "wau": len(week), "mau": len(month),
                  "stickiness": _ratio(len(week), len(month)),
                  "external": len(external)},
        "d1": cohort(1),
        "d7": cohort(7),
        "activation": {"rate": _ratio(len(activated), len(observable)),
                       "cohort": len(observable), "active": len(activated)},
        "weeks": weeks[-4:],
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


def _first_device_rows(real_devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """每台「手机」的第一行：同一账号 + 同一机型只留 `createdAt` 最早的那行。

    为什么不能按 `deviceId` 去重：App 重装或换版本后会重新配对，中转插的是**新行**
    （`deviceId` 与 device token 都换了），同一台手机会被反复记成「新增手机」。
    2026-10-14 那天报 2 台新增，其中 Windows-PC 的 iPhone 11 是换版本重配：
    旧行（`20261012.1310`）最后一次在线与新行（`20261013.2233`）创建时间同为 00:21。
    账号 + 机型是库里能稳定指认"同一台手机"的口径；代价是一个人的两台同型号手机
    会被并成一台（少见，宁可少报也不要把重装算成新用户）。
    已被清理工具删掉历史行的设备再注册会重新算一次新增——历史没了，无从辨别。
    """
    firsts: dict[tuple[Any, str], dict[str, Any]] = {}
    for row in real_devices:
        key = (row.get("accountId"),
               str(row.get("model") or row.get("name") or row["deviceId"]))
        seen = firsts.get(key)
        if seen is None or int(row["createdAt"]) < int(seen["createdAt"]):
            firsts[key] = row
    return list(firsts.values())


def _day_start_ms(day: int) -> int:
    """本地日 `YYYYMMDD` 的 00:00（服务器时区）对应的毫秒时间戳。

    日界必须与 `store.local_day` 同一条：中转记账、日额度判定都按本地日切，
    「今日」要是自己另算一套（比如滑动 24 小时），同一个数字在两个地方会对不上。
    """
    return int(datetime.datetime.strptime(str(day), "%Y%m%d").timestamp() * 1000)


def _today_report(store: Store, *, stamp: int, threads: list[dict[str, Any]],
                  real_devices: list[dict[str, Any]], debug_ids: set[str],
                  names: dict[str, str | None], known_ids: set[str] | None = None,
                  external: set[str] | None = None) -> dict[str, Any]:
    """「今日」板块：`stamp` 所在服务器本地自然日 00:00 起（到 `stamp` 为止）的数据。

    为什么要有这一块：30 天窗口把当天埋在一堆历史里，看不出"今天有没有事"。今日的口径
    全部落在本地日上，与 `usage --days 1`、日额度一致。

    `stamp` 是报告锚点：默认是此刻（当天到现在的部分数据），`--as-of yesterday` 时是
    昨天 23:59:59.999，这一块就是刚过去那一整天的完整数据。

    调试设备（`_is_debug_device`）的流量、设备、账号一并剔除——这一块是给 owner 看用户的；
    被剔掉的设备 id 与账号名由调用方算好传进来（`usageDaily` 里只有 deviceId）。

    `devices.new` 是**手机**数（`_first_device_rows`）：同一账号同机型的重装/换版本
    不再算新增；`devices.newRaw` 保留设备行口径，两个数字的差就是重装行数。
    """
    day = local_day(stamp / 1000)
    start = _day_start_ms(day)
    known = {row["deviceId"]: row for row in real_devices}
    fresh_rows = _first_device_rows(real_devices)
    by_device: list[dict[str, Any]] = []
    by_account: dict[str, dict[str, Any]] = {}
    builds: dict[str, dict[str, Any]] = {}
    egress = connections = 0
    first_seen: int | None = None
    last_seen: int | None = None
    for row in store.usage_rows(day):
        if row["deviceId"] in debug_ids:
            continue
        # 内部账号的孤儿用量行（设备行已被清理工具删掉）与 `_usage_scan` 同口径剔除，
        # 否则同一天在「今日」和「最近 N 天」里又是两个数字。
        if _is_orphan_usage(row, known_ids=known_ids or set(), external=external or set()):
            continue
        device = known.get(row["deviceId"]) or {}
        size = int(row["egressBytes"])
        count = int(row["connections"])
        seen_from = int(row["firstSeenAt"] or 0)
        seen_to = int(row["lastSeenAt"] or 0)
        account_id = row.get("accountId")
        egress += size
        connections += count
        first_seen = seen_from if first_seen is None else min(first_seen, seen_from)
        last_seen = seen_to if last_seen is None else max(last_seen, seen_to)
        if row.get("lastBuild"):
            # 今日版本分布：一个构建后面挂多少台设备、多少个账号（同账号多设备只算一次）。
            build = builds.setdefault(row["lastBuild"], {"devices": 0, "accounts": set()})
            build["devices"] += 1
            if account_id:
                build["accounts"].add(account_id)
        account = by_account.setdefault(account_id, {"accountId": account_id,
                                                     "name": names.get(account_id),
                                                     "egressBytes": 0, "connections": 0,
                                                     "devices": 0})
        account["egressBytes"] += size
        account["connections"] += count
        account["devices"] += 1
        by_device.append({
            "deviceId": row["deviceId"],
            "name": device.get("name"),
            "model": device.get("model"),
            "appVersion": device.get("appVersion"),
            "accountId": account_id,
            "accountName": names.get(account_id),
            "egressBytes": size,
            "connections": count,
            "firstSeenAt": seen_from or None,
            "lastSeenAt": seen_to or None,
            "lastBuild": row.get("lastBuild"),
            "revoked": bool(device.get("revokedAt")),
        })
    by_device.sort(key=lambda row: (int(row["egressBytes"]), int(row["connections"])), reverse=True)
    ranked = sorted(by_account.values(), key=lambda row: int(row["egressBytes"]), reverse=True)
    # 在册 = 锚点时刻没被撤销；锚点之后才撤销的不算（`revokedAt > stamp`）。
    live = [row for row in real_devices
            if not row.get("revokedAt") or int(row["revokedAt"]) > stamp]
    fresh = [row for row in threads if start <= int(row["createdAt"]) <= stamp]
    enrollments = [row for row in store.list_enrollments()
                   if start <= int(row.get("usedAt") or 0) <= stamp
                   and not _is_test_enrollment(row)]
    return {
        "day": day,
        "dayStartAt": start,
        "usage": {
            "egressBytes": egress,
            "connections": connections,
            "devices": len(by_device),
            # 活跃用户（账号口径，owner 2026-10-17 定）：这一天的账号数，同一账号的多台手机
            # 只算一个；`devices` 仍是设备行数，两者不相等是常态（重装会多出行）。
            "accounts": len([key for key in by_account if key]),
            "firstSeenAt": first_seen or None,
            "lastSeenAt": last_seen or None,
            "builds": sorted(({"build": build, "devices": entry["devices"],
                               "accounts": len(entry["accounts"])}
                              for build, entry in builds.items()),
                             key=lambda item: (-item["devices"], item["build"])),
        },
        "topAccounts": ranked[:REPORT_TODAY_LIMIT],
        "devices": {
            "list": by_device[:REPORT_TODAY_LIMIT],
            "new": len([row for row in fresh_rows
                        if start <= int(row["createdAt"]) <= stamp]),
            "newRaw": len([row for row in real_devices
                           if start <= int(row["createdAt"]) <= stamp]),
            "active": len([row for row in live
                           if start <= int(row.get("lastSeenAt") or 0) <= stamp]),
            "revoked": len([row for row in real_devices
                            if start <= int(row.get("revokedAt") or 0) <= stamp]),
            "live": len(live),
        },
        "feedback": {
            "new": len(fresh),
            "open": len([row for row in fresh if row["status"] == "open"]),
            "replied": len([row for row in fresh if row["status"] == "replied"]),
            "threads": fresh[:REPORT_TODAY_LIMIT],
        },
        "invites": {"used": len(enrollments), "enrollments": enrollments[:REPORT_TODAY_LIMIT]},
    }


def _first_seen_days(store: Store, *, debug_ids: set[str],
                     owners: dict[str, str | None]) -> dict[str, int]:
    """每个账号**第一次**有用量记录的那天（本地日）——留存的队列起点。

    窗口只有 N 天，而"新用户"必须按历史上第一次活跃来定，所以这里单独读一次更长的历史
    （`RETENTION_HISTORY_DAYS`）：按设备分组拿到 (day, deviceId)，再用设备→账号的映射归到
    账号上，顺带用同一套规则剔掉调试设备。项目规模是几千行以内，一次读完不影响日报耗时。
    """
    first: dict[str, int] = {}
    for row in store.usage_totals(days=RETENTION_HISTORY_DAYS, by="device"):
        if row["deviceId"] in debug_ids:
            continue
        account = owners.get(row["deviceId"])
        if not account:
            continue
        day = int(row["day"])
        if account not in first or day < first[account]:
            first[account] = day
    return first


def _invite_report(store: Store, stamp: int, enrollments: list[dict[str, Any]],
                   *, test_count: int = 0, totals: dict[str, int] | None = None,
                   unused: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """激活码（邀请码）的账：还有多少能用、哪些快到期、最近谁激活了。

    `remaining` 是老口径（未使用的全部），把**已过期但没用**的也算在里面；日报要说
    「还剩几张能发」，所以另给 `usable`（未用且未过期）、`expiringSoon`（7 天内到期）、
    `expiredUnused`（已经废掉的）。三个数各自独立，加起来才等于 `remaining`。

    `totals` / `unused` 由调用方按报告锚点算好传进来（`_ops_report`）：日报是快照，
    锚点之后才铸、才用掉的码不能出现在"昨天"里。不传时退回库里此刻的状态。
    """
    if totals is None:
        totals = store.invite_totals()
    soon = int(stamp) + 7 * 86_400_000
    rows = unused if unused is not None else store.list_invites()
    unused_rows = [{"createdAt": int(row.get("createdAt") or 0),
                    "expiresAt": int(row.get("expiresAt") or 0),
                    "note": row.get("note")}
                   for row in rows]
    usable = [row for row in unused_rows if row["expiresAt"] > int(stamp)]
    return {
        **totals,
        "test": test_count,
        "usable": len(usable),
        "expiringSoon": len([row for row in usable if row["expiresAt"] <= soon]),
        "expiredUnused": len([row for row in unused_rows if row["expiresAt"] <= int(stamp)]),
        # 最早到期的排前面：日报要回答"下一批什么时候失效"。
        "unused": sorted(usable, key=lambda row: row["expiresAt"])[:12],
        "enrollments": enrollments,
    }


def _ops_report(store: Store, days: int, *, as_of: int | None = None,
                journal_unit: str = DEFAULT_JOURNAL_UNIT) -> dict[str, Any]:
    """日报的板块：**今日** + 反馈 / 设备 / 用量 / 留存 / 邀请码（最近 `--days` 天）。

    `--days` 是窗口（本地日，含 `as_of` 那天）：反馈只数窗口内**新建**的线程，用量与每日新增
    设备也只覆盖窗口；邀请码的账是全量（码用没用完跟窗口无关）。空库照样每个板块
    齐全、计数为 0——日报每天都会跑。

    `as_of`（`--as-of`）是报告的时间锚点：默认 `None` = 此刻（部分数据）；给了锚点就按
    锚点所在的本地日算，`generatedAt` 仍是真实的生成时刻——日报改到每天 00:00 跑之后，
    传的是 `yesterday`，出来的就是刚过去那一整天的完整数据（见 `_resolve_as_of`）。

    设备板块只统计**真实设备**（剔除 `_is_debug_device`），被剔除的行数放在 `debug` 里，
    这样"图上是用户、库里有多少调试行"两件事都看得见；新增手机（`devices.newPerDay` 与
    `today.devices.new`）再按 (账号, 机型) 去重，见 `_first_device_rows`，
    对应的设备行口径留在 `newRawPerDay` / `today.devices.newRaw` 里备查；反馈板块同样剔除模拟器/调试设备
    提的验收单（`_is_test_thread`），被剔的条数放在 `feedback.test`。`today` 板块是同一批
    数据的单日切片，见 `_today_report`；留存只算用邀请码登记的外部账号，见 `_retention_report`。
    """
    now = now_ms()
    stamp = now if as_of is None else int(as_of)
    listed = _feedback_rows(store, status=None, since_ms=stamp - days * 86_400_000,
                            limit=REPORT_THREAD_LIMIT)
    # `since_ms` 只有下界：锚点在过去时（00:00 跑、报刚过去那一天），锚点之后新建的线程
    # 不属于这份报告——不加这一刀，00:00–00:02 之间收到的新反馈会被算进"昨天"。
    listed = [row for row in listed if int(row["createdAt"]) <= stamp]
    devices = store.list_devices(include_revoked=True)
    agent_versions = {row["agentId"]: row for row in store.list_agents()}
    debug_ids = {row["deviceId"] for row in devices if _is_debug_device(row)}
    names = {row["accountId"]: row.get("name") for row in store.list_accounts()}
    # 报告是**锚点时刻的快照**：00:02 跑、报刚过去那一天时，锚点之后才配对的手机、
    # 才撤销的设备、才用掉的邀请码都不属于这份报告。不按锚点结算的话，日报里会出现
    # 第二天的数据（2026-10-19 实测：版本表「最近在线 10-19 00:00」、设备表「10-19 00:01」）。
    real = [row for row in devices
            if row["deviceId"] not in debug_ids and int(row.get("createdAt") or 0) <= stamp]
    live = [row for row in real
            if not row.get("revokedAt") or int(row["revokedAt"]) > stamp]
    threads = [row for row in listed if not _is_test_thread(row, debug_ids)]
    # 「每日新增手机」按手机去重（`_first_device_rows`）：换版本重装会插新设备行，
    # 不去重的话这类行会被记成新用户。`newRawPerDay` 保留设备行口径。
    created_per_day: dict[int, int] = {}
    raw_per_day: dict[int, int] = {}
    for row in real:
        day = local_day(int(row["createdAt"]) / 1000)
        raw_per_day[day] = raw_per_day.get(day, 0) + 1
    for row in _first_device_rows(real):
        day = local_day(int(row["createdAt"]) / 1000)
        created_per_day[day] = created_per_day.get(day, 0) + 1
    new_per_day = [{"day": day, "count": created_per_day.get(day, 0)}
                   for day in _recent_days(days, end=stamp)]
    raw_new_per_day = [{"day": day, "count": raw_per_day.get(day, 0)}
                       for day in _recent_days(days, end=stamp)]
    # 登记名单要在读用量之前算好：孤儿用量行（设备行被清理工具删掉）要不要算进报表，
    # 取决于它属不属于外部账号，见 `_is_orphan_usage`。
    enrollments = store.list_enrollments()
    test_enrollments = [row for row in enrollments if _is_test_enrollment(row)]
    real_enrollments = [row for row in enrollments if not _is_test_enrollment(row)]
    # 锚点之后才激活的账号不属于这份报告：不加这一刀，「近 30 天激活」与激活码表格里
    # 会混进 00:00–00:02 之间刚发生的登记。
    real_enrollments = [row for row in real_enrollments
                        if int(row.get("usedAt") or 0) <= stamp]
    # 激活码的账同样按锚点结算：之后才铸的码、才用掉的码都不在"昨天"这份报告里。
    invites_as_of = [row for row in store.list_invites(include_used=True)
                     if int(row.get("createdAt") or 0) <= stamp]
    used_by_stamp = [row for row in invites_as_of
                     if row.get("usedAt") and int(row["usedAt"]) <= stamp]
    unused_by_stamp = [row for row in invites_as_of if row not in used_by_stamp]
    invite_totals_as_of = {"minted": len(invites_as_of), "used": len(used_by_stamp),
                           "remaining": len(unused_by_stamp)}
    external = {row["accountId"] for row in real_enrollments if row.get("accountId")}
    known_ids = {row["deviceId"] for row in devices}
    # 设备行的「最近在线」取自用量行并夹到锚点：直接读 devices.lastSeenAt 会显示
    # 第二天的时间（连接器重连也会刷它），那是另一份事实。
    last_seen_by_device: dict[str, int] = {}
    for day in _recent_days(days, end=stamp):
        for row in store.usage_rows(day):
            seen = min(int(row.get("lastSeenAt") or 0), stamp)
            if seen > last_seen_by_device.get(row["deviceId"], 0):
                last_seen_by_device[row["deviceId"]] = seen
    series, ranked, active_by_day = _usage_scan(store, days, debug_ids, names, end=stamp,
                                                known_ids=known_ids, external=external)
    owners = {row["deviceId"]: row.get("accountId") for row in devices}
    # 首次活跃日只算一次：用量图的「新增 / 回访」拆分与留存队列都读它，
    # 两处各算一遍迟早出现"图上新增 3 个、留存队列 2 个"这种对不上的数字。
    first_seen = _first_seen_days(store, debug_ids=debug_ids, owners=owners)
    return {
        "ok": True,
        "generatedAt": now,
        "asOf": stamp,
        "days": days,
        # 版本分布：只看最近 48 小时有设备连接的用户（owner 2026-10-17 定）。
        "versions": _version_report(
            store, since_ms=stamp - REPORT_VERSION_HOURS * 3_600_000, until_ms=stamp,
            devices={row["deviceId"]: row for row in devices}, debug_ids=debug_ids,
            known_ids=known_ids, external=external),
        "versionsWindowHours": REPORT_VERSION_HOURS,
        # 过去 72 小时的活跃形状：从 systemd 日志重建，只算**有设备在连**的账号。
        # 取不到日志时 `buckets` 为 None，渲染层写「没有日志数据」，不拿别的数据凑。
        "hourlyActivity": {"windowHours": REPORT_ACTIVITY_HOURS,
                           "buckets": _hourly_activity(
                               REPORT_ACTIVITY_HOURS, stamp,
                               {row["deviceId"]: row for row in devices},
                               agent_versions, unit=journal_unit)},
        "today": _today_report(store, stamp=stamp, threads=threads, real_devices=real,
                               debug_ids=debug_ids, names=names, known_ids=known_ids,
                               external=external),
        "feedback": _feedback_report(store, threads, test_count=len(listed) - len(threads)),
        "devices": {
            "paired": len(live),
            "active7d": len([row for row in live
                             if stamp - 7 * 86_400_000
                             <= last_seen_by_device.get(row["deviceId"], 0) <= stamp]),
            "activeWindow": len([row for row in live
                                 if stamp - days * 86_400_000
                                 <= last_seen_by_device.get(row["deviceId"], 0) <= stamp]),
            "newInWindow": sum(int(entry["count"]) for entry in new_per_day),
            "newRawInWindow": sum(int(entry["count"]) for entry in raw_new_per_day),
            "windowDays": days,
            "revoked": len(real) - len(live),
            "debug": len([row for row in devices
                          if row["deviceId"] in debug_ids
                          and int(row.get("createdAt") or 0) <= stamp]),
            "newPerDay": new_per_day,
            # 设备行口径的每日新增，只用来核对与 `newPerDay` 的差（差 = 重装行数）。
            # 渲染层不读它；`_first_device_rows` 记了为什么要按手机去重。
            "newRawPerDay": raw_new_per_day,
            # 只列**未撤销的真实设备**，按最近在线倒序取前 `REPORT_DEVICE_LIMIT` 台：
            # 全量列表在生产库上是 1900+ 行（历次调试配对都还在），日报会被它撑爆
            # （2026-10-12 第一版 327 KB，正文里 90% 是 DSH-Test/DSH-Sweep 的历史行）。
            # `accountName` 是日报自己加的：手机上设备名常常全是「iPhone」，得靠账号名区分。
            # `lastSeenAt` 用**锚点内的用量行**覆盖：registry 那一列会被 00:00 之后的
            # 重连刷成第二天的时间。
            "list": [{**_device_report_row(_with_versions(row, agent_versions)),
                      "lastSeenAt": last_seen_by_device.get(row["deviceId"]),
                      "accountName": names.get(row["accountId"])}
                     for row in
                     sorted(live, key=lambda row: int(last_seen_by_device.get(row["deviceId"])
                                                      or row["createdAt"]),
                            reverse=True)[:REPORT_DEVICE_LIMIT]],
        },
        "usage": _usage_report(series, ranked, active_by_day, first_seen),
        "retention": _retention_report(store, days=days, stamp=stamp, external=external,
                                       active_by_day=active_by_day,
                                       first_seen=first_seen),
        "invites": _invite_report(store, stamp, real_enrollments,
                                  test_count=len(test_enrollments),
                                  totals=invite_totals_as_of, unused=unused_by_stamp),
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
