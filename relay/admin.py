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
import json
import os
import sys
from typing import Any
from urllib.parse import quote

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
    parser.add_argument("--db", default=os.environ.get("DLP_DB", os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "state.db")))
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

    purge = subs.add_parser("purge", help="drop expired pairing codes")
    purge.add_argument("--json", action="store_true")
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
        _emit([{**row, "deviceTokenHash": row["deviceTokenHash"][:12] + "…"} for row in rows])
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
        _emit({"ok": True, "deviceId": device_id, "revoked": True})
        return 0

    if command == "purge":
        removed = store.purge_expired()
        _emit({"ok": True, "removed": removed})
        return 0

    raise StoreError(f"unhandled command {command}")


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
