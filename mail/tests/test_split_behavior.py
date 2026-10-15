"""拆分后的边界行为（DESIGN-20261015）：mail ↔ 中转那条唯一的运行时接口。

钉三件事：

1. 生产解析器（internal.RelayIdentityResolver）对中转的每种应答都按契约降级：
   200 → 设备归属；404 / 5xx / 网络错误 / 畸形 JSON → None（匿名）。
2. 匿名凭据流不依赖中转：解析器完全不可用时，提交/取件照样工作。
   这是"中转部署/重启不影响信件匿名路径"的机制保证。
3. `_caller` 对解析器的意外异常也降级为匿名（任何实现都不能把提交变成 500）。

中转那一半的契约（loopback 守卫、404 语义）钉在 relay/tests/test_internal_token_resolve.py，
两边合起来才是完整的 I-1；真实两服务的端到端在 L3 演练（M5）。
"""

from __future__ import annotations

import pytest
from aiohttp import web

import mail as mail_module
from internal import RelayIdentityResolver
from store import Store


async def test_the_production_resolver_maps_each_relay_answer(aiohttp_client):
    """200 → 设备；404 / 500 / 畸形 JSON → None。网络错误那条在下一个用例。"""
    async def resolve(request: web.Request) -> web.Response:
        token = (await request.json())["token"]
        if token == "good":
            return web.json_response({"deviceId": "dev_1", "accountId": "acc_1",
                                      "expiresAt": 123})
        if token == "garbage":
            return web.json_response({"nope": True})
        if token == "boom":
            return web.json_response({}, status=500)
        return web.json_response({}, status=404)

    app = web.Application()
    app.router.add_post("/internal/tokens/resolve", resolve)
    client = await aiohttp_client(app)
    resolver = RelayIdentityResolver(str(client.make_url("/")), timeout_s=2.0)
    try:
        assert await resolver("good") == {"deviceId": "dev_1", "accountId": "acc_1",
                                          "expiresAt": 123}
        assert await resolver("unknown") is None
        assert await resolver("boom") is None
        assert await resolver("garbage") is None
    finally:
        await resolver.aclose()


async def test_the_production_resolver_degrades_on_a_dead_relay(tmp_path):
    """中转不在（部署中/挂了）：连接被拒也是 None，不抛。"""
    resolver = RelayIdentityResolver("http://127.0.0.1:1", timeout_s=0.5)
    assert await resolver("any") is None
    await resolver.aclose()


async def test_anonymous_letters_survive_a_dead_resolver(tmp_path, aiohttp_client):
    """匿名凭据流不依赖中转：解析器不可用时，匿名提交/取件照常（故障矩阵的第 2 行）。"""
    store = Store(str(tmp_path / "mail.db"))
    app = mail_module.create_app(store=store,
                                 resolve_device=RelayIdentityResolver("http://127.0.0.1:1",
                                                                      timeout_s=0.2))
    client = await aiohttp_client(app)

    submitted = await client.post("/feedback/submit", json={"text": "中转不在也要能提意见"})
    assert submitted.status == 200, await submitted.text()
    ticket = await submitted.json()

    inboxed = await client.post("/feedback/inbox", json={
        "tickets": [{"threadId": ticket["threadId"], "ticketKey": ticket["ticketKey"]}]})
    assert inboxed.status == 200, await inboxed.text()
    assert [t["threadId"] for t in (await inboxed.json())["threads"]] == [ticket["threadId"]]
    store.close()


async def test_a_broken_resolver_never_turns_a_submission_into_a_500(tmp_path, aiohttp_client):
    """`_caller` 兜住解析器的意外异常：提交按匿名落库，不是 500。"""
    store = Store(str(tmp_path / "mail.db"))

    async def broken(_token):
        raise RuntimeError("resolver bug")

    app = mail_module.create_app(store=store, resolve_device=broken)
    client = await aiohttp_client(app)

    submitted = await client.post("/feedback/submit", json={"text": "解析器炸了也按匿名"},
                                  headers={"Authorization": "Bearer whatever"})
    assert submitted.status == 200, await submitted.text()
    thread = store.feedback_thread((await submitted.json())["threadId"], None)
    assert thread["deviceId"] is None, "解析失败的令牌按匿名处理"
    store.close()


def test_the_service_module_parses_its_arguments(tmp_path):
    """入口模块的参数表与文档一致（部署单元 M3 会用 --db/--port/--base-path）。"""
    parser = mail_module.build_parser()
    args = parser.parse_args(["--db", str(tmp_path / "m.db"), "--port", "8788",
                              "--base-path", "/dsh-link",
                              "--relay-internal-url", "http://127.0.0.1:8787"])
    assert args.port == 8788
    assert args.base_path == "/dsh-link"
    assert args.relay_internal_url == "http://127.0.0.1:8787"
