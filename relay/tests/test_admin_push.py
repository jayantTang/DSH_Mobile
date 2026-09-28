"""``admin.py push-test`` and the extra ``device-list`` fields (R-1 C-10).

``push-test`` is the operator's only way to tell a working push from a silently
misconfigured one, so what it *prints* is the feature: the APNs status and
reason, never a traceback. These tests drive it as the operator does — through
``argv`` — with the APNs endpoint replaced by a stub.
"""

from __future__ import annotations

import json

import pytest

import admin
import push as push_module
from push import PushSender
from store import Store


class StubResponse:
    def __init__(self, status_code: int, body: str = "", headers: dict | None = None):
        self.status_code = status_code
        self.text = body
        self.headers = headers or {}


class StubClient:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests: list[dict] = []

    async def post(self, url, *, headers, content):
        self.requests.append({"url": url, "headers": headers, "content": content})
        return self.responses.pop(0) if self.responses else StubResponse(200)


@pytest.fixture
def provisioned(tmp_path):
    """A device with a push registration, in a throwaway database."""
    store = Store(str(tmp_path / "state.db"))
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    device = store.claim_pair_code(code["code"], device_name="iPhone")
    store.set_push(device["deviceId"], "ab" * 32, "sandbox", True, True)
    store.close()
    # 一张**现场生成的**临时 key：仓库里不许有任何私钥，测试要就自己造一张。
    key = tmp_path / "AuthKey_TESTKEY12.p8"
    key.write_text(_generated_key())
    return {"db": str(tmp_path / "state.db"), "deviceId": device["deviceId"],
            "keyPath": str(key)}


def run_cli(db: str, *args: str, capsys) -> tuple[int, dict]:
    """Run the command as the operator would; stdout is the JSON report."""
    code = admin.main(["--db", db, *args])
    captured = capsys.readouterr()
    out = captured.out.strip()
    return code, (json.loads(out) if out else {"stderr": captured.err.strip()})


def test_push_test_sends_one_and_prints_what_apple_said(provisioned, capsys, monkeypatch):
    """凭据与链路通不通，就看这一条输出。"""
    client = StubClient(StubResponse(200, headers={"apns-id": "abc-123"}))
    monkeypatch.setattr(admin.PushSender, "from_env",
                        classmethod(lambda cls, env=None, _client=None: _sender(client, provisioned)))

    code, report = run_cli(provisioned["db"], "push-test", "--device",
                           provisioned["deviceId"], capsys=capsys)
    assert code == 0, report
    assert report["ok"] is True and report["status"] == 200
    assert report["env"] == "sandbox" and report["kind"] == "turnEnd"
    assert report["apnsId"] == "abc-123"
    assert len(client.requests) == 1
    # 发的是**登记时那个环境**对应的主机。
    assert client.requests[0]["url"] == f"{push_module.APNS_HOSTS['sandbox']}/3/device/{'ab' * 32}"


def test_push_test_prints_the_rejection_reason_and_exits_nonzero(provisioned, capsys, monkeypatch):
    """`sandbox/production` 配错是静默故障——所以拒绝原因必须打印出来。"""
    client = StubClient(StubResponse(400, '{"reason":"BadDeviceToken"}'))
    monkeypatch.setattr(admin.PushSender, "from_env",
                        classmethod(lambda cls, env=None, _client=None: _sender(client, provisioned)))

    code, report = run_cli(provisioned["db"], "push-test", "--device",
                           provisioned["deviceId"], "--kind", "attention", capsys=capsys)
    assert code == 1
    assert report["ok"] is False and report["status"] == 400
    assert report["reason"] == "BadDeviceToken"
    assert report["deadToken"] is True and report["cleared"] is True

    # 与 relay 在线时的行为一致：Apple 说令牌死了就清登记。
    store = Store(provisioned["db"])
    try:
        assert store.device_by_id(provisioned["deviceId"])["apnsToken"] is None
    finally:
        store.close()


def test_push_test_ignores_the_throttle(provisioned, capsys, monkeypatch):
    """排障时不该等 60 秒：连发三条都该真的发出去。"""
    client = StubClient(StubResponse(200), StubResponse(200), StubResponse(200))
    monkeypatch.setattr(admin.PushSender, "from_env",
                        classmethod(lambda cls, env=None, _client=None: _sender(client, provisioned)))

    for _ in range(3):
        code, report = run_cli(provisioned["db"], "push-test", "--device",
                               provisioned["deviceId"], capsys=capsys)
        assert code == 0 and report["ok"] is True
    assert len(client.requests) == 3


def test_push_test_reports_a_typo_instead_of_a_traceback(provisioned, capsys):
    """打错 device id 要给出明确错误（退出码 1 + 一行人话），而不是栈。"""
    code, report = run_cli(provisioned["db"], "push-test", "--device", "dev_nope",
                           capsys=capsys)
    assert code == 1
    assert "dev_nope" in report["stderr"]
    assert "Traceback" not in report["stderr"]


def test_push_test_explains_an_unregistered_device(tmp_path, capsys):
    store = Store(str(tmp_path / "state.db"))
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    device = store.claim_pair_code(code["code"], device_name="iPhone")
    store.close()
    code, report = run_cli(str(tmp_path / "state.db"), "push-test", "--device",
                           device["deviceId"], capsys=capsys)
    assert code == 1 and "推送登记" in report["stderr"]


def test_push_test_says_so_when_apns_is_not_configured(provisioned, capsys, monkeypatch):
    monkeypatch.setattr(admin.PushSender, "from_env",
                        classmethod(lambda cls, env=None, client=None: PushSender.disabled()))
    code, report = run_cli(provisioned["db"], "push-test", "--device",
                           provisioned["deviceId"], capsys=capsys)
    assert code == 1 and "APNs 未配置" in report["stderr"]


def test_device_list_adds_push_fields_without_renaming_existing_ones(provisioned, capsys):
    """`scripts/dev/*.mjs` 在解这份 JSON：只允许加字段。"""
    code, rows = run_cli(provisioned["db"], "device-list", capsys=capsys)
    assert code == 0 and len(rows) == 1
    row = rows[0]
    # 原有字段名一个不动。
    for field in ("deviceId", "deviceTokenHash", "agentId", "accountId", "name",
                  "model", "appVersion", "createdAt", "expiresAt", "lastSeenAt",
                  "revokedAt"):
        assert field in row, f"device-list 少了原有字段 {field}"
    assert row["push"] == {
        "registered": True, "env": "sandbox", "turnEnd": True, "attention": True,
        "updatedAt": row["pushUpdatedAt"],
    }
    assert row["deviceTokenHash"].endswith("…"), "令牌哈希仍必须是截断显示"


def test_the_existing_subcommands_keep_their_output_shape(provisioned, capsys):
    """加了子命令不该动别的子命令的输出格式。"""
    code, accounts = run_cli(provisioned["db"], "account-list", capsys=capsys)
    assert code == 0 and accounts[0]["name"] == "ops"
    code, agents = run_cli(provisioned["db"], "agent-list", capsys=capsys)
    assert code == 0 and agents[0]["secretHash"].endswith("…")
    code, usage = run_cli(provisioned["db"], "usage", "--days", "1", capsys=capsys)
    assert code == 0


def _sender(client, provisioned) -> PushSender:
    """A configured sender signing with the test's own generated key.

    Deliberately not a stubbed ``_token``: the 403 path re-signs for real, and a
    stub would make that path untested (and, as it happens, silently break).
    """
    return PushSender(enabled=True, key_path=provisioned["keyPath"], key_id="TESTKEY12",
                      team_id="TEAMID1234", topic="com.example.app",
                      client=client, min_interval_s=60.0)


def _generated_key() -> str:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    return ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()).decode("ascii")

