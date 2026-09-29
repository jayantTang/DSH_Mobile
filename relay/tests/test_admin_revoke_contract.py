"""C-04 F3：`admin.py device-revoke` 的输出契约与"不再够 relay"。

这件事的教训是：`ok:true` 只许陈述 admin **自己核实过的事实**。以前它还顺手打一次
relay 的 HTTP 面去踢在线设备，但库一撤那个令牌立刻失效（`device_by_token` 对
`revokedAt` 非空返回 None），那一步必然是 401，而 `HTTPError` 是 `URLError` 的
子类、被无差别 `except` 吞掉，于是"库撤了、设备还在线"却报了成功。

所以下面钉两件事：**输出字段恰为那四个**，以及**根本没有对外调用**——把
`DLP_ADMIN_RELAY_URL` 指到黑洞地址、甚至环境里放一个必然失败的代理，结果都必须一样。
"""

from __future__ import annotations

import json

import pytest

import admin
from store import Store


@pytest.fixture
def provisioned(tmp_path):
    store = Store(str(tmp_path / "state.db"))
    account = store.create_account("ops")
    agent = store.register_agent(account["accountId"], "mac")
    code = store.mint_pair_code(agent["agentId"], ttl_ms=60_000)
    device = store.claim_pair_code(code["code"], device_name="iPhone")
    token = device["deviceToken"]
    store.close()
    return {"db": str(tmp_path / "state.db"), "deviceId": device["deviceId"], "token": token}


def run_cli(db: str, *args: str, capsys) -> tuple[int, dict, str]:
    code = admin.main(["--db", db, *args])
    captured = capsys.readouterr()
    out = captured.out.strip()
    return code, (json.loads(out) if out else {}), captured.err.strip()


def test_device_revoke_by_device_prints_exactly_the_new_contract(provisioned, capsys):
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--device", provisioned["deviceId"], capsys=capsys)
    assert code == 0, err
    assert payload == {
        "ok": True,
        "deviceId": provisioned["deviceId"],
        "revoked": True,
        "detach": "relay-reconcile",
    }


def test_device_revoke_by_token_is_field_for_field_identical(provisioned, capsys):
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--token", provisioned["token"], capsys=capsys)
    assert code == 0, err
    assert payload == {
        "ok": True,
        "deviceId": provisioned["deviceId"],
        "revoked": True,
        "detach": "relay-reconcile",
    }


def test_device_revoke_writes_revoked_at(provisioned, capsys):
    run_cli(provisioned["db"], "device-revoke", "--device", provisioned["deviceId"],
            capsys=capsys)
    store = Store(provisioned["db"])
    try:
        row = store.device_by_id(provisioned["deviceId"])
        assert row["revokedAt"] is not None
    finally:
        store.close()


def test_a_black_hole_relay_url_changes_nothing(provisioned, capsys, monkeypatch):
    """证明这条命令**没有**任何对外调用：地址指向黑洞也一样成功、一样快。"""
    monkeypatch.setenv("DLP_ADMIN_RELAY_URL", "http://127.0.0.1:1/dsh-link")
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--device", provisioned["deviceId"], capsys=capsys)
    assert code == 0, err
    assert payload["ok"] is True and payload["detach"] == "relay-reconcile"


def test_a_dead_proxy_environment_changes_nothing(provisioned, capsys, monkeypatch):
    """连"偷偷走 stdlib 默认代理"这种路也堵死。"""
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:1")
    monkeypatch.setenv("https_proxy", "http://127.0.0.1:1")
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--token", provisioned["token"], capsys=capsys)
    assert code == 0, err
    assert payload["ok"] is True


def test_an_already_revoked_token_is_a_one_line_error_not_a_traceback(provisioned, capsys):
    run_cli(provisioned["db"], "device-revoke", "--token", provisioned["token"],
            capsys=capsys)
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--token", provisioned["token"], capsys=capsys)
    assert code == 1
    assert payload == {}
    assert err.strip() == "admin.py: that device token is unknown, revoked, or expired"
    assert "Traceback" not in err


def test_an_unknown_device_is_a_one_line_error(provisioned, capsys):
    code, payload, err = run_cli(provisioned["db"], "device-revoke",
                                 "--device", "dev_nope", capsys=capsys)
    assert code == 1
    assert payload == {}
    assert "Traceback" not in err
    assert err.strip().startswith("admin.py:")


def test_neither_device_nor_token_is_an_error(provisioned, capsys):
    code, payload, err = run_cli(provisioned["db"], "device-revoke", capsys=capsys)
    assert code == 1
    assert err.strip() == "admin.py: pass --device or --token"


def test_the_module_no_longer_has_a_relay_url_or_a_detach_helper():
    """删干净：不留下一条会漂移的"第二条实现"。"""
    assert not hasattr(admin, "ADMIN_RELAY_URL")
    assert not hasattr(admin, "_detach_live_device")
    source = (admin.__file__)
    with open(source, encoding="utf-8") as handle:
        text = handle.read()
    assert "urllib.request" not in text
    assert "urllib.error" not in text
    # `quote` 仍是 `dsh://pair` 深链要用的，不许顺手删掉。
    assert "from urllib.parse import quote" in text
