"""自助登记契约（``POST /agents/enroll``）：邀请码、错误码与限流。

登记是公开分发的入口：**没有有效、未用、未过期的邀请码，就没有身份**。这里钉住
用户实际会撞到的四种拒绝（未知 / 过期 / 已用 / 缺字段），以及两道预算：

* **码桶是闸门**：同一个码失败 5 次后被冻结，第 6 次回 429；
* **来源桶只记账不拦人**：同一来源失败过，也不能否决运营者发出去的合法邀请码
  （2026-09-25 owner 的决定）。两者都写成用例，免得以后把其中一个改成另一个。
"""

from __future__ import annotations

import pytest

from . import support

#: 五次的含义：``_ENROLL_FAILURES = 5`` / ``_ENROLL_WINDOW_S = 900``。
ENROLL_FAILURE_BUDGET = 5


def mint_invite(relay, *, ttl_seconds: str = "600") -> dict:
    return relay.admin("invite-mint", "--ttl-seconds", ttl_seconds, "--note", "blackbox")


async def enroll(client: support.Client, code: str, *,
                 name: str | None = "BLACKBOX-Mac") -> support.HttpResponse:
    payload: dict = {"inviteCode": code}
    if name is not None:
        payload["name"] = name
    return await client.post("/agents/enroll", json_body=payload)


# ── 成功路径 ────────────────────────────────────────────────────────────────


async def test_enroll_returns_a_usable_identity(client: support.Client, relay) -> None:
    invite = mint_invite(relay)
    response = await enroll(client, invite["code"], name="BLACKBOX-enroll-mac")

    assert response.status == 200, response.text
    body = response.json()
    assert body["ok"] is True
    assert body["agentId"].startswith("agt_")
    assert body["agentSecret"].startswith("as_")
    assert body["accountId"].startswith("acc_")
    assert body["agentName"] == "BLACKBOX-enroll-mac"

    # 返回的 secret 是能用的凭据，不是装饰串：拿它铸码、认领一台设备。
    minted = await client.post("/pair/code", json_body={}, token=body["agentSecret"])
    assert minted.status == 200, minted.text
    claimed = await support.claim_code(client, minted.json()["code"],
                                       name="BLACKBOX-enrolled-phone")
    assert claimed.status == 200, claimed.text
    assert claimed.json()["agentId"] == body["agentId"]
    assert claimed.json()["accountId"] == body["accountId"]


async def test_enroll_without_a_name_uses_the_default(client: support.Client, relay) -> None:
    invite = mint_invite(relay)
    response = await enroll(client, invite["code"], name=None)
    assert response.status == 200, response.text
    assert response.json()["agentName"] == "My computer"


async def test_enroll_tolerates_retyped_codes(client: support.Client, relay) -> None:
    """码是从一块屏幕读到另一块屏幕再敲进去的：大小写与分隔符不该影响登记。"""
    invite = mint_invite(relay)
    retyped = f"  {invite['code'].lower().replace('-', ' ')}  "
    response = await enroll(client, retyped, name="BLACKBOX-retyped")
    assert response.status == 200, response.text


# ── 拒绝路径 ────────────────────────────────────────────────────────────────


async def test_an_unknown_invite_answers_404_enroll_unknown(
        client: support.Client) -> None:
    response = await enroll(client, "ZZZZ-ZZZZ-ZZZZ-0000")
    support.assert_error_envelope(response, status=404, code="enroll/unknown")


async def test_an_expired_invite_answers_404_enroll_expired(
        client: support.Client, relay) -> None:
    # 只有管理面铸得出"一出生就过期"的码（HTTP 没有铸邀请码的接口）。
    invite = mint_invite(relay, ttl_seconds="0")
    response = await enroll(client, invite["code"])
    support.assert_error_envelope(response, status=404, code="enroll/expired")


async def test_a_used_invite_answers_404_enroll_used(client: support.Client,
                                                     relay) -> None:
    invite = mint_invite(relay)
    first = await enroll(client, invite["code"], name="BLACKBOX-first")
    assert first.status == 200, first.text
    replay = await enroll(client, invite["code"], name="BLACKBOX-replay")
    support.assert_error_envelope(replay, status=404, code="enroll/used")


@pytest.mark.parametrize("payload", [
    {},
    {"inviteCode": ""},
    {"inviteCode": "   "},
    {"inviteCode": 5},
    {"name": "BLACKBOX-no-code"},
])
async def test_enroll_rejects_malformed_requests(client: support.Client,
                                                 payload: dict) -> None:
    response = await client.post("/agents/enroll", json_body=payload)
    support.assert_error_envelope(response, status=400, code="enroll/bad-request")


async def test_enroll_rejects_non_json(client: support.Client) -> None:
    response = await client.post("/agents/enroll", data=b"not json",
                                 headers={"content-type": "application/json"})
    support.assert_error_envelope(response, status=400, code="enroll/bad-request")


# ── 限流：码桶是闸门 ────────────────────────────────────────────────────────


async def test_five_bad_guesses_freeze_that_code_with_429(
        client: support.Client) -> None:
    code = "BLACKBOX-FAIL-CODE-0001"
    for _ in range(ENROLL_FAILURE_BUDGET):
        response = await enroll(client, code)
        support.assert_error_envelope(response, status=404, code="enroll/unknown")

    frozen = await enroll(client, code)
    support.assert_error_envelope(frozen, status=429, code="enroll/rate-limited")

    # 冻结的是**这个码**，不是这个来源：换一个没人猜过的码照常得到 404。
    fresh = await enroll(client, "BLACKBOX-FAIL-CODE-0002")
    support.assert_error_envelope(fresh, status=404, code="enroll/unknown")


async def test_a_valid_invite_is_admitted_after_five_failures_from_one_source(
        client: support.Client, relay) -> None:
    """来源桶只累计、不否决：运营者发的合法码必须仍然进得来。"""
    code = "BLACKBOX-FAIL-CODE-0003"
    for _ in range(ENROLL_FAILURE_BUDGET):
        response = await enroll(client, code)
        support.assert_error_envelope(response, status=404, code="enroll/unknown")

    invite = mint_invite(relay)
    admitted = await enroll(client, invite["code"], name="BLACKBOX-late-but-valid")
    assert admitted.status == 200, admitted.text
    assert admitted.json()["agentId"].startswith("agt_")
