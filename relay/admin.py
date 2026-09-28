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
from store import DEFAULT_INVITE_TTL_MS, DEFAULT_PAIR_TTL_MS, Store, StoreError, now_ms

#: The relay is published as a path prefix on the existing, already-certified
#: site (no new DNS record, no new certificate).
DEFAULT_RELAY = "wss://relay.example.com/dsh-link"


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
