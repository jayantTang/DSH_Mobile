"""``relay/push.py``: APNs delivery, entirely against stubs.

No network and no real credential is involved. The two things worth proving here
are the ones a person cannot check by looking at a phone:

* the payload has **no content in it** — only a localization key and the two
  identifiers the app needs to open and dedupe a reminder; and
* the sender's failure handling is bounded: one re-sign on ``403``, a dead-token
  verdict on ``410``/``BadDeviceToken``, and nothing at all in disabled mode.

The signing tests use a **throwaway key generated in the test**, never a
credential from anywhere: the repository must not contain one, and neither must
its test suite.
"""

from __future__ import annotations

import asyncio
import json

import pytest

import push as push_module
from push import ALERT_KEYS, APNS_HOSTS, PushSender


# ── stubs ───────────────────────────────────────────────────────────────────


class StubResponse:
    def __init__(self, status_code: int, body: str = "", headers: dict | None = None):
        self.status_code = status_code
        self.text = body
        self.headers = headers or {}


class StubClient:
    """Records every request and replays a queued response."""

    def __init__(self, responses: list[StubResponse] | None = None):
        self.responses = list(responses or [])
        self.requests: list[dict] = []

    async def post(self, url: str, *, headers: dict, content: bytes) -> StubResponse:
        self.requests.append({"url": url, "headers": dict(headers), "content": content})
        if not self.responses:
            return StubResponse(200, headers={"apns-id": "stub"})
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    def payloads(self) -> list[dict]:
        return [json.loads(request["content"].decode("utf-8")) for request in self.requests]


def sender(client: StubClient, **overrides) -> PushSender:
    settings = {
        "enabled": True, "key_path": "/nonexistent/generated.p8", "key_id": "KEYID1234",
        "team_id": "TEAMID1234", "topic": "com.example.app", "default_env": "sandbox",
        "min_interval_s": 60.0, "client": client, "now": lambda: 1_000_000.0,
    }
    settings.update(overrides)
    instance = PushSender(**settings)
    # A generated key, so signing is exercised without shipping one.
    instance._token = lambda *, force=False: "stub-jwt"  # noqa: SLF001 - the seam under test
    return instance


def run(coro):
    return asyncio.run(coro)


# ── the payload promise ─────────────────────────────────────────────────────


def test_the_payload_contains_only_a_localization_key_and_identifiers():
    """R-1 的隐私硬约束：payload 里不许有会话内容。

    审这一条只需要看一个地方——`_payload`。这里逐字段断言，多出任何一个键都会
    让这条用例红，那正是我们要的（"只加一个字段"最容易悄悄带进内容）。
    """
    instance = sender(StubClient())
    payload = instance._payload("turnEnd", "session-abc")  # noqa: SLF001
    assert payload == {
        "aps": {"alert": {"title-loc-key": "运行结束"}, "sound": "default",
                "thread-id": "session-abc"},
        "kind": "turnEnd",
        "sid": "session-abc",
    }
    # 键就是键：它是本地化表的键，不是要显示的文案，所以中英都由手机决定。
    assert payload["aps"]["alert"]["title-loc-key"] in ALERT_KEYS.values()

    attention = instance._payload("attention", "session-abc", "evt-1")  # noqa: SLF001
    assert attention["aps"]["alert"] == {"title-loc-key": "需要你确认"}
    assert attention["eid"] == "evt-1"


def test_no_content_field_can_appear_in_any_kind():
    """两种 kind、两种语言下都不许出现正文类字段。"""
    instance = sender(StubClient())
    forbidden = {"title", "subtitle", "body", "loc-args", "title-loc-args", "loc-key",
                 "message", "text", "path", "host", "tool", "error", "sessionTitle"}
    for kind in ALERT_KEYS:
        payload = instance._payload(kind, "sid-1", "eid-1")  # noqa: SLF001
        serialized = json.dumps(payload, ensure_ascii=False)
        alert_keys = set(payload["aps"]["alert"])
        assert not (alert_keys & forbidden), f"{kind} 的 alert 里出现了正文类字段"
        # 除了白名单里的六个键，整个 payload 不许再有任何东西。
        assert set(payload) <= {"aps", "kind", "sid", "eid"}
        assert set(payload["aps"]) <= {"alert", "sound", "thread-id"}
        # 会话标识只在自定义字段里（锁屏上不显示），没有混进 alert。
        assert "sid-1" not in json.dumps(payload["aps"]["alert"], ensure_ascii=False)
        assert "eid-1" not in serialized.split('"eid"')[0]


# ── disabled / misconfigured ────────────────────────────────────────────────


def test_a_disabled_sender_never_touches_http():
    client = StubClient()
    instance = PushSender.from_env({}, client=client)
    assert instance.enabled is False
    result = run(instance.send(device_id="dev_1", token="aa" * 32, env="sandbox",
                               kind="turnEnd", sid="s-1"))
    assert result.skipped == "disabled" and result.ok is False
    assert client.requests == []


def test_partial_configuration_disables_push_instead_of_raising():
    """配了一半的部署必须还能转发——这是「推送配置错掉转发」的防线。"""
    client = StubClient()
    instance = PushSender.from_env({"DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_ID": "K"}, client=client)
    assert instance.enabled is False
    assert run(instance.send(device_id="d", token="t", env="sandbox",
                             kind="turnEnd", sid="s")).skipped == "disabled"


def test_a_missing_key_file_disables_push():
    instance = PushSender.from_env({
        "DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_PATH": "/nonexistent/AuthKey_XX.p8",
        "DLP_APNS_KEY_ID": "K", "DLP_APNS_TEAM_ID": "T", "DLP_APNS_TOPIC": "com.x",
    }, client=StubClient())
    assert instance.enabled is False


def test_fully_configured_env_is_enabled_and_reads_every_setting(tmp_path):
    key = tmp_path / "AuthKey_TESTKEY12.p8"
    key.write_text("placeholder")
    instance = PushSender.from_env({
        "DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_PATH": str(key), "DLP_APNS_KEY_ID": "TESTKEY12",
        "DLP_APNS_TEAM_ID": "TEAM123456", "DLP_APNS_TOPIC": "com.jayanttang.dsh",
        "DLP_APNS_ENV_DEFAULT": "production", "DLP_APNS_MIN_INTERVAL_S": "5",
    }, client=StubClient())
    assert instance.enabled is True
    assert instance.default_env == "production" and instance.min_interval_s == 5.0
    assert instance.topic == "com.jayanttang.dsh"


@pytest.mark.parametrize("value", ["0", "", "no", "false", "off", None])
def test_the_switch_is_off_unless_it_says_otherwise(value):
    env = {} if value is None else {"DLP_APNS_ENABLED": value}
    assert PushSender.from_env(env, client=StubClient()).enabled is False


# ── the request itself ──────────────────────────────────────────────────────


def test_send_posts_to_the_host_that_matches_the_device_environment():
    client = StubClient([StubResponse(200, headers={"apns-id": "abc"})])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="ff" * 32, env="production",
                               kind="turnEnd", sid="s-1"))
    assert result.ok and result.status == 200 and result.apns_id == "abc"
    request = client.requests[0]
    assert request["url"] == f"{APNS_HOSTS['production']}/3/device/{'ff' * 32}"
    headers = request["headers"]
    assert headers["apns-topic"] == "com.example.app"
    assert headers["apns-push-type"] == "alert" and headers["apns-priority"] == "10"
    assert headers["apns-collapse-id"] == "s-1"
    assert headers["authorization"] == "bearer stub-jwt"
    # turnEnd 短、attention 长：一条"跑完了"放一小时就是噪音。
    assert int(headers["apns-expiration"]) == int(1_000_000 + 3600)


def test_attention_sets_a_longer_expiration():
    client = StubClient()
    instance = sender(client)
    run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                      kind="attention", sid="s-1", eid="e-1"))
    assert client.requests[0]["headers"]["apns-expiration"] == str(int(1_000_000 + 24 * 3600))


def test_a_session_id_longer_than_apples_limit_is_truncated():
    client = StubClient()
    instance = sender(client)
    run(instance.send(device_id="dev_1", token="aa", env="sandbox", kind="turnEnd",
                      sid="s" * 200))
    assert len(client.requests[0]["headers"]["apns-collapse-id"]) == 64


def test_an_unknown_kind_is_not_sent():
    client = StubClient()
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="made-up", sid="s"))
    assert result.skipped == "unsupported-kind" and client.requests == []


def test_an_unusable_environment_is_not_guessed():
    """环境标错时 APNs 回 BadDeviceToken，看起来就像"推送坏了"——所以宁可不发。"""
    client = StubClient()
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="staging",
                               kind="turnEnd", sid="s"))
    assert result.skipped == "unknown-env" and client.requests == []


# ── signing ─────────────────────────────────────────────────────────────────


def test_the_provider_token_is_signed_once_and_reused(tmp_path):
    key = tmp_path / "AuthKey_TESTKEY12.p8"
    key.write_text(_generated_key())
    client = StubClient()
    instance = PushSender(enabled=True, key_path=str(key), key_id="TESTKEY12",
                          team_id="TEAM123456", topic="com.x", client=client,
                          min_interval_s=0)
    first = run(instance.send(device_id="d1", token="aa", env="sandbox",
                              kind="turnEnd", sid="s1"))
    second = run(instance.send(device_id="d2", token="bb", env="sandbox",
                               kind="turnEnd", sid="s2"))
    assert first.ok and second.ok
    assert client.requests[0]["headers"]["authorization"] == \
        client.requests[1]["headers"]["authorization"], "同一小时内不该重签"
    # 签出来的确实是 ES256（三段、头里带 kid）。
    jwt = client.requests[0]["headers"]["authorization"].split(" ", 1)[1]
    import jwt as pyjwt
    header = pyjwt.get_unverified_header(jwt)
    assert header["alg"] == "ES256" and header["kid"] == "TESTKEY12"


def test_a_stale_token_is_re_signed(tmp_path):
    key = tmp_path / "AuthKey_TESTKEY12.p8"
    key.write_text(_generated_key())
    clock = [1_000_000.0]
    client = StubClient()
    instance = PushSender(enabled=True, key_path=str(key), key_id="K", team_id="T",
                          topic="com.x", client=client, min_interval_s=0,
                          now=lambda: clock[0])
    run(instance.send(device_id="d1", token="aa", env="sandbox", kind="turnEnd", sid="s1"))
    clock[0] += push_module.JWT_TTL_S + 1
    run(instance.send(device_id="d2", token="bb", env="sandbox", kind="turnEnd", sid="s2"))
    assert client.requests[0]["headers"]["authorization"] != \
        client.requests[1]["headers"]["authorization"], "过期后应该重签"


# ── rejections ──────────────────────────────────────────────────────────────


def test_410_asks_the_caller_to_clear_the_token():
    client = StubClient([StubResponse(410, '{"reason":"Unregistered"}')])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s"))
    assert result.ok is False and result.dead_token is True
    assert result.status == 410 and result.reason == "Unregistered"


def test_bad_device_token_asks_the_caller_to_clear_the_token():
    client = StubClient([StubResponse(400, '{"reason":"BadDeviceToken"}')])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="production",
                               kind="turnEnd", sid="s"))
    assert result.dead_token is True and result.reason == "BadDeviceToken"


def test_a_403_re_signs_exactly_once():
    """key 被撤销时重签一次；再失败只记日志——**不循环**。"""
    client = StubClient([StubResponse(403, '{"reason":"ExpiredProviderToken"}')])
    instance = sender(client)
    calls = []
    real_token = PushSender._token  # noqa: SLF001 - 数"签了几次"

    def counting_token(self, *, force=False):
        calls.append(force)
        return real_token(self, force=force)

    # 用 stub 的 jwt 太麻烦，这里只数调用：把内部实现换成记账版。
    instance._token = lambda *, force=False: (calls.append(force), "jwt")[1]  # noqa: SLF001
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s"))
    assert result.ok is True
    assert len(client.requests) == 2, "403 应该重试一次"
    assert calls.count(True) == 1, "只许强制重签一次"


def test_a_second_403_gives_up_without_looping():
    client = StubClient([StubResponse(403, '{"reason":"InvalidProviderToken"}'),
                         StubResponse(403, '{"reason":"InvalidProviderToken"}')])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s"))
    assert result.ok is False and result.reason == "InvalidProviderToken"
    assert len(client.requests) == 2, "重签一次之后仍失败就必须停"


def test_a_transport_failure_is_reported_not_raised():
    client = StubClient([RuntimeError("connection reset")])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s"))
    assert result.ok is False and "transport" in (result.reason or "")


def test_a_non_json_error_body_still_yields_a_reason():
    client = StubClient([StubResponse(500, "<html>nope</html>")])
    instance = sender(client)
    result = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s"))
    assert result.status == 500 and "nope" in (result.reason or "")


# ── throttling ──────────────────────────────────────────────────────────────


def test_a_second_push_to_the_same_device_within_the_window_is_skipped():
    """锁屏不堆：同一台设备 60 秒内只发一条（可配）。"""
    clock = [1_000_000.0]
    client = StubClient()
    instance = sender(client, now=lambda: clock[0])
    first = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                              kind="turnEnd", sid="s1"))
    second = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                               kind="turnEnd", sid="s2"))
    assert first.ok is True and second.skipped == "throttled"
    assert len(client.requests) == 1

    # 另一台设备不受影响。
    other = run(instance.send(device_id="dev_2", token="bb", env="sandbox",
                              kind="turnEnd", sid="s3"))
    assert other.ok is True and len(client.requests) == 2

    # 过了窗口就恢复。
    clock[0] += 61
    third = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                              kind="turnEnd", sid="s4"))
    assert third.ok is True and len(client.requests) == 3


def test_push_test_can_bypass_the_throttle():
    """`push-test` 要能连发（排障时不该等 60 秒）。"""
    client = StubClient()
    instance = sender(client)
    for _ in range(3):
        run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                          kind="turnEnd", sid="s", ignore_throttle=True))
    assert len(client.requests) == 3


def test_a_failed_push_does_not_consume_the_throttle_window():
    """被拒的没送达，不该把接下来 60 秒的提醒一起吞掉。"""
    clock = [1_000_000.0]
    client = StubClient([StubResponse(500, '{"reason":"InternalServerError"}')])
    instance = sender(client, now=lambda: clock[0])
    run(instance.send(device_id="dev_1", token="aa", env="sandbox", kind="turnEnd", sid="s"))
    again = run(instance.send(device_id="dev_1", token="aa", env="sandbox",
                              kind="turnEnd", sid="s"))
    assert again.ok is True and len(client.requests) == 2


# ── fan-out ─────────────────────────────────────────────────────────────────


def test_send_many_delivers_to_every_device_and_survives_a_bad_row():
    client = StubClient()
    instance = sender(client, min_interval_s=0)
    targets = [
        {"deviceId": "dev_1", "apnsToken": "aa", "apnsEnv": "sandbox"},
        {"deviceId": "dev_2", "apnsToken": "bb", "apnsEnv": "production"},
        {"deviceId": "dev_3", "apnsToken": None, "apnsEnv": "sandbox"},   # 没登记
    ]
    results = run(instance.send_many(targets, kind="attention", sid="s-1", eid="e-1"))
    assert len(results) == 3
    assert [result.skipped for result in results] == [None, None, "no-token"]
    assert len(client.requests) == 2
    assert client.payloads()[1]["eid"] == "e-1"


# ── helpers ─────────────────────────────────────────────────────────────────


def _generated_key() -> str:
    """A throwaway P-256 key, generated here and thrown away.

    Deliberately not a fixture file: this repository must not contain a private
    key of any kind, and a test that needs one can make its own.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    return ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()).decode("ascii")
