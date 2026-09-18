"""SQLite persistence for the DLP relay.

Only *hashes* of secrets are stored: ``agentSecret``/``deviceToken`` are 256-bit
random values, so SHA-256 is enough (and lets us look a row up by hash), while
the short human-typed pairing codes are stretched with scrypt so an offline
brute force of a leaked database stays expensive. Invite codes get the same
treatment as agent secrets — they are long and machine-generated, so a SHA-256
lookup is both sufficient and fast enough for a single indexed read.

These are blocking sqlite3 calls; the HTTP handlers reach them through
:func:`asyncio.to_thread` where the work is non-trivial.
"""

from __future__ import annotations

import hashlib
import os
import secrets
import sqlite3
import threading
import time
from typing import Any, Iterable

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS accounts (
  accountId  TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
  agentId    TEXT PRIMARY KEY,
  accountId  TEXT NOT NULL,
  name       TEXT NOT NULL,
  secretHash TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  updatedAt  INTEGER NOT NULL,
  disabled   INTEGER NOT NULL DEFAULT 0,
  lastSeenAt INTEGER
);
CREATE INDEX IF NOT EXISTS agents_account ON agents(accountId);

CREATE TABLE IF NOT EXISTS devices (
  deviceId        TEXT PRIMARY KEY,
  deviceTokenHash TEXT NOT NULL UNIQUE,
  agentId         TEXT NOT NULL,
  accountId       TEXT NOT NULL,
  name            TEXT NOT NULL,
  model           TEXT,
  appVersion      TEXT,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  lastSeenAt      INTEGER,
  revokedAt       INTEGER
);
CREATE INDEX IF NOT EXISTS devices_agent ON devices(agentId);

CREATE TABLE IF NOT EXISTS pairCodes (
  codeHash  TEXT PRIMARY KEY,
  agentId   TEXT NOT NULL,
  accountId TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  expiresAt INTEGER NOT NULL,
  usedAt    INTEGER,
  deviceId  TEXT
);
CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId);

CREATE TABLE IF NOT EXISTS invites (
  codeHash        TEXT PRIMARY KEY,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  usedAt          INTEGER,
  usedByAgentId   TEXT,
  note            TEXT
);
"""

DEFAULT_PAIR_TTL_MS = 10 * 60 * 1000
DEFAULT_DEVICE_TTL_MS = 365 * 24 * 60 * 60 * 1000
#: Invites are handed out by a person and redeemed days later, unlike pairing
#: codes which live for minutes.
DEFAULT_INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000

_SCRYPT_N = 1 << 14
_SCRYPT_R = 8
_SCRYPT_P = 1

class StoreError(Exception):
    """Base class for store-level failures."""

class NotFound(StoreError):
    """The requested row does not exist (or is disabled/expired)."""

class Conflict(StoreError):
    """The requested write violates a uniqueness invariant."""

class InviteRejected(StoreError):
    """An invite code could not be redeemed.

    Carries *why* so the caller can be told the difference between a typo, a
    code someone already used, and one that has simply run out of time.
    """

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason

def now_ms() -> int:
    return int(time.time() * 1000)

def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def new_id(prefix: str, nbytes: int = 9) -> str:
    return f"{prefix}_{secrets.token_hex(nbytes)}"

def new_token(prefix: str, nbytes: int = 32) -> str:
    return f"{prefix}_{secrets.token_urlsafe(nbytes)}"

def normalize_pair_code(code: str) -> str:
    """Pair codes are case-insensitive and ignore separators when claimed."""
    return "".join(ch for ch in code.strip().upper() if ch.isalnum())

#: Invite alphabet: no 0/O/1/I/L, because the code is read off one screen and
#: typed on another (or pasted into an installer and retyped from a chat).
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_GROUPS = 4
INVITE_GROUP_LEN = 4

def new_invite_code(groups: int = INVITE_GROUPS) -> str:
    """A fresh `XXXX-XXXX-XXXX-XXXX` invite code."""
    total = groups * INVITE_GROUP_LEN
    raw = "".join(secrets.choice(INVITE_ALPHABET) for _ in range(total))
    return "-".join(raw[index:index + INVITE_GROUP_LEN]
                    for index in range(0, total, INVITE_GROUP_LEN))

def normalize_invite_code(code: str) -> str:
    return normalize_pair_code(code)

def hash_invite_code(code: str) -> str:
    """SHA-256, not scrypt.

    The code is long and machine-generated, so there is nothing to brute force,
    and a single indexed lookup beats scanning every unused invite through a
    deliberately expensive KDF.
    """
    return sha256_hex(normalize_invite_code(code))

def hash_pair_code(code: str, *, salt: bytes | None = None) -> str:
    normalized = normalize_pair_code(code)
    salt = salt or os.urandom(16)
    digest = hashlib.scrypt(
        normalized.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32
    )
    return f"scrypt${salt.hex()}${digest.hex()}"

def _verify_pair_code(code: str, stored: str) -> bool:
    try:
        scheme, salt_hex, digest_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        candidate = hashlib.scrypt(
            normalize_pair_code(code).encode("utf-8"),
            salt=bytes.fromhex(salt_hex),
            n=_SCRYPT_N,
            r=_SCRYPT_R,
            p=_SCRYPT_P,
            dklen=32,
        )
        return secrets.compare_digest(candidate.hex(), digest_hex)
    except (ValueError, AttributeError):
        return False

class Store:
    """A small synchronous SQLite store with an async-friendly surface."""

    def __init__(self, path: str):
        self.path = path
        directory = os.path.dirname(os.path.abspath(path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False, timeout=15)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(SCHEMA)
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ── internal helpers ────────────────────────────────────────────────────

    def _execute(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Cursor:
        with self._lock:
            cursor = self._conn.execute(sql, tuple(params))
            return cursor

    def _write(self, sql: str, params: Iterable[Any] = ()) -> None:
        with self._lock:
            self._conn.execute(sql, tuple(params))
            self._conn.commit()

    def _row(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute(sql, tuple(params)).fetchone()

    def _rows(self, sql: str, params: Iterable[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return list(self._conn.execute(sql, tuple(params)).fetchall())

    # ── accounts ────────────────────────────────────────────────────────────

    def create_account(self, name: str) -> dict[str, Any]:
        account_id = new_id("acc")
        created = now_ms()
        self._write(
            "INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
            (account_id, name, created),
        )
        return {"accountId": account_id, "name": name, "createdAt": created}

    def get_account(self, account_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM accounts WHERE accountId=?", (account_id,))
        return dict(row) if row else None

    def list_accounts(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self._rows("SELECT * FROM accounts ORDER BY createdAt")]

    # ── agents ──────────────────────────────────────────────────────────────

    def register_agent(self, account_id: str, name: str, agent_id: str | None = None) -> dict[str, Any]:
        """Create an agent (or rotate the secret of an existing one)."""
        if self.get_account(account_id) is None:
            raise NotFound(f"account {account_id} does not exist")
        secret = new_token("as")
        stamp = now_ms()
        if agent_id is None:
            agent_id = new_id("agt")
            self._write(
                "INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"
                " VALUES(?,?,?,?,?,?)",
                (agent_id, account_id, name, sha256_hex(secret), stamp, stamp),
            )
        else:
            row = self._row("SELECT * FROM agents WHERE agentId=?", (agent_id,))
            if row is None:
                raise NotFound(f"agent {agent_id} does not exist")
            self._write(
                "UPDATE agents SET name=?, secretHash=?, updatedAt=?, disabled=0 WHERE agentId=?",
                (name, sha256_hex(secret), stamp, agent_id),
            )
        return {"agentId": agent_id, "agentSecret": secret, "accountId": account_id, "name": name}

    def set_agent_disabled(self, agent_id: str, disabled: bool) -> None:
        if self._row("SELECT agentId FROM agents WHERE agentId=?", (agent_id,)) is None:
            raise NotFound(f"agent {agent_id} does not exist")
        self._write("UPDATE agents SET disabled=?, updatedAt=? WHERE agentId=?",
                    (1 if disabled else 0, now_ms(), agent_id))

    def agent_by_id(self, agent_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM agents WHERE agentId=?", (agent_id,))
        return dict(row) if row else None

    def agent_by_secret(self, secret: str) -> dict[str, Any] | None:
        if not secret:
            return None
        row = self._row("SELECT * FROM agents WHERE secretHash=?", (sha256_hex(secret),))
        if row is None or row["disabled"]:
            return None
        return dict(row)

    def list_agents(self, account_id: str | None = None) -> list[dict[str, Any]]:
        if account_id:
            rows = self._rows("SELECT * FROM agents WHERE accountId=? ORDER BY createdAt", (account_id,))
        else:
            rows = self._rows("SELECT * FROM agents ORDER BY createdAt")
        return [dict(row) for row in rows]

    def touch_agent(self, agent_id: str, at: int | None = None) -> None:
        self._write("UPDATE agents SET lastSeenAt=? WHERE agentId=?", (at or now_ms(), agent_id))

    # ── pairing ─────────────────────────────────────────────────────────────

    def mint_pair_code(self, agent_id: str, ttl_ms: int = DEFAULT_PAIR_TTL_MS) -> dict[str, Any]:
        agent = self.agent_by_id(agent_id)
        if agent is None:
            raise NotFound(f"agent {agent_id} does not exist")
        if agent["disabled"]:
            raise Conflict(f"agent {agent_id} is disabled")
        # 8 chars from an unambiguous alphabet, rendered as XXXX-XXXX.
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        raw = "".join(secrets.choice(alphabet) for _ in range(8))
        code = f"{raw[:4]}-{raw[4:]}"
        created = now_ms()
        expires = created + int(ttl_ms)
        self._write(
            "INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt) VALUES(?,?,?,?,?)",
            (hash_pair_code(code), agent_id, agent["accountId"], created, expires),
        )
        return {"code": code, "expiresAt": expires, "agentId": agent_id, "ttlMs": int(ttl_ms)}

    def claim_pair_code(self, code: str, *, device_name: str, model: str | None = None,
                        app_version: str | None = None,
                        ttl_ms: int = DEFAULT_DEVICE_TTL_MS) -> dict[str, Any]:
        """Consume a pairing code and mint a long-lived device token.

        The lookup has to scan live unused codes because each row carries its
        own scrypt salt; the candidate set is tiny (codes expire in minutes).
        """
        normalized = normalize_pair_code(code)
        if not normalized:
            raise NotFound("empty pairing code")
        stamp = now_ms()
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM pairCodes WHERE usedAt IS NULL AND expiresAt > ? ORDER BY createdAt DESC LIMIT 200",
                (stamp,),
            ).fetchall()
            match = next((row for row in rows if _verify_pair_code(normalized, row["codeHash"])), None)
            if match is None:
                raise NotFound("pairing code is invalid, used, or expired")
            agent = self._conn.execute(
                "SELECT * FROM agents WHERE agentId=?", (match["agentId"],)
            ).fetchone()
            if agent is None or agent["disabled"]:
                raise NotFound("the agent for this pairing code is unavailable")
            device_id = new_id("dev")
            token = new_token("dt")
            expires = stamp + int(ttl_ms)
            self._conn.execute(
                "INSERT INTO devices(deviceId, deviceTokenHash, agentId, accountId, name, model,"
                " appVersion, createdAt, expiresAt) VALUES(?,?,?,?,?,?,?,?,?)",
                (device_id, sha256_hex(token), agent["agentId"], agent["accountId"],
                 device_name or "iOS device", model, app_version, stamp, expires),
            )
            self._conn.execute("UPDATE pairCodes SET usedAt=?, deviceId=? WHERE codeHash=?",
                               (stamp, device_id, match["codeHash"]))
            self._conn.commit()
        return {
            "ok": True,
            "agentId": agent["agentId"],
            "agentName": agent["name"],
            "accountId": agent["accountId"],
            "deviceId": device_id,
            "deviceToken": token,
            "expiresAt": expires,
        }

    def purge_expired(self, at: int | None = None) -> int:
        stamp = at or now_ms()
        with self._lock:
            cursor = self._conn.execute("DELETE FROM pairCodes WHERE expiresAt < ?", (stamp,))
            self._conn.commit()
            return cursor.rowcount or 0

    # ── invites ─────────────────────────────────────────────────────────────

    def mint_invite(self, ttl_ms: int = DEFAULT_INVITE_TTL_MS, note: str | None = None,
                    code: str | None = None) -> dict[str, Any]:
        """Mint a one-time invite code.

        The plaintext code is returned exactly once — only its hash is stored,
        so nobody (including the operator, later) can read it back out of the
        database. ``code`` exists so tests can pin a known value.
        """
        plaintext = code or new_invite_code()
        created = now_ms()
        expires = created + int(ttl_ms)
        self._write(
            "INSERT INTO invites(codeHash, createdAt, expiresAt, note) VALUES(?,?,?,?)",
            (hash_invite_code(plaintext), created, expires, note),
        )
        return {"code": plaintext, "expiresAt": expires, "ttlMs": int(ttl_ms), "note": note}

    def invite_status(self, code: str) -> dict[str, Any]:
        """Inspect an invite without consuming it.

        Used for error reporting: a caller who typed a used code should be told
        that, not told the code does not exist.
        """
        row = self._row("SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(code),))
        if row is None:
            return {"exists": False}
        if row["usedAt"] is not None:
            return {"exists": True, "state": "used", "usedAt": row["usedAt"],
                    "usedByAgentId": row["usedByAgentId"]}
        if int(row["expiresAt"]) <= now_ms():
            return {"exists": True, "state": "expired", "expiresAt": row["expiresAt"]}
        return {"exists": True, "state": "unused", "expiresAt": row["expiresAt"]}

    def claim_invite(self, code: str, name: str) -> dict[str, Any]:
        """Redeem one invite: create the account and its first agent.

        One transaction, so an invite can never be marked used without the
        identity existing, and a race between two machines redeeming the same
        code leaves exactly one winner.
        """
        normalized = normalize_invite_code(code)
        if not normalized:
            raise InviteRejected("unknown", "that invite code is not valid")
        stamp = now_ms()
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(normalized),)
            ).fetchone()
            if row is None:
                raise InviteRejected("unknown", "that invite code is not valid")
            if row["usedAt"] is not None:
                raise InviteRejected("used", "that invite code has already been used")
            if int(row["expiresAt"]) <= stamp:
                raise InviteRejected("expired", "that invite code has expired")

            account_id = new_id("acc")
            agent_id = new_id("agt")
            secret = new_token("as")
            agent_name = (name or "").strip() or "My computer"
            self._conn.execute(
                "INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
                (account_id, agent_name, stamp),
            )
            self._conn.execute(
                "INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"
                " VALUES(?,?,?,?,?,?)",
                (agent_id, account_id, agent_name, sha256_hex(secret), stamp, stamp),
            )
            self._conn.execute(
                "UPDATE invites SET usedAt=?, usedByAgentId=? WHERE codeHash=?",
                (stamp, agent_id, row["codeHash"]),
            )
            self._conn.commit()
        return {
            "ok": True,
            "accountId": account_id,
            "agentId": agent_id,
            "agentName": agent_name,
            "agentSecret": secret,
            "inviteNote": row["note"],
        }

    def list_invites(self, *, include_used: bool = False) -> list[dict[str, Any]]:
        """Invites as the operator sees them — hashes only, never the code."""
        where = "" if include_used else " WHERE usedAt IS NULL"
        rows = self._rows(f"SELECT * FROM invites{where} ORDER BY createdAt")
        return [dict(row) for row in rows]

    def revoke_invite(self, code: str, at: int | None = None) -> dict[str, Any]:
        """Retire an invite that should no longer be redeemable.

        Needed because an invite can leak — a code pasted into review notes, a
        screenshot, a chat — and the only other ways to neutralise it were to
        wait out its TTL or to hand-edit the database. The code is hashed for
        lookup like everywhere else, and only the hash is ever reported back.

        Revoking sets the expiry to now rather than deleting the row: the
        failure an invitee sees stays "expired", and the note stays visible in
        `invite-list --all` as the record of what happened.
        """
        stamp = at or now_ms()
        normalized = normalize_invite_code(code)
        if not normalized:
            return {"revoked": False, "reason": "malformed"}
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM invites WHERE codeHash=?", (hash_invite_code(normalized),)
            ).fetchone()
            if row is None:
                return {"revoked": False, "reason": "unknown"}
            if row["usedAt"] is not None:
                return {"revoked": False, "reason": "used", "usedAt": row["usedAt"],
                        "usedByAgentId": row["usedByAgentId"]}
            if int(row["expiresAt"]) <= stamp:
                return {"revoked": False, "reason": "already-expired",
                        "expiresAt": row["expiresAt"]}
            self._conn.execute(
                "UPDATE invites SET expiresAt=? WHERE codeHash=?",
                (stamp, hash_invite_code(normalized)),
            )
            self._conn.commit()
        return {"revoked": True, "codeHash": hash_invite_code(normalized)[:12],
                "note": row["note"], "expiresAt": stamp}

    def purge_invites(self, at: int | None = None) -> int:
        stamp = at or now_ms()
        with self._lock:
            cursor = self._conn.execute(
                "DELETE FROM invites WHERE expiresAt < ? OR usedAt IS NOT NULL", (stamp,)
            )
            self._conn.commit()
            return cursor.rowcount or 0

    # ── devices ─────────────────────────────────────────────────────────────

    def device_by_token(self, token: str) -> dict[str, Any] | None:
        if not token:
            return None
        row = self._row("SELECT * FROM devices WHERE deviceTokenHash=?", (sha256_hex(token),))
        if row is None:
            return None
        if row["revokedAt"] is not None:
            return None
        if int(row["expiresAt"]) <= now_ms():
            return None
        return dict(row)

    def device_by_id(self, device_id: str) -> dict[str, Any] | None:
        row = self._row("SELECT * FROM devices WHERE deviceId=?", (device_id,))
        return dict(row) if row else None

    def list_devices(self, agent_id: str | None = None, *, include_revoked: bool = False) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if agent_id:
            clauses.append("agentId=?")
            params.append(agent_id)
        if not include_revoked:
            clauses.append("revokedAt IS NULL")
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self._rows(f"SELECT * FROM devices{where} ORDER BY createdAt", params)
        return [dict(row) for row in rows]

    def refresh_device(self, token: str, ttl_ms: int = DEFAULT_DEVICE_TTL_MS) -> dict[str, Any]:
        device = self.device_by_token(token)
        if device is None:
            raise NotFound("device token is invalid, revoked, or expired")
        new = new_token("dt")
        expires = now_ms() + int(ttl_ms)
        self._write("UPDATE devices SET deviceTokenHash=?, expiresAt=? WHERE deviceId=?",
                    (sha256_hex(new), expires, device["deviceId"]))
        return {
            "ok": True,
            "deviceId": device["deviceId"],
            "agentId": device["agentId"],
            "accountId": device["accountId"],
            "deviceToken": new,
            "expiresAt": expires,
        }

    def revoke_device(self, device_id: str) -> None:
        if self._row("SELECT deviceId FROM devices WHERE deviceId=?", (device_id,)) is None:
            raise NotFound(f"device {device_id} does not exist")
        self._write("UPDATE devices SET revokedAt=? WHERE deviceId=?", (now_ms(), device_id))

    def touch_device(self, device_id: str, at: int | None = None) -> None:
        self._write("UPDATE devices SET lastSeenAt=? WHERE deviceId=?", (at or now_ms(), device_id))
