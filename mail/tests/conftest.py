"""mail 测试夹具。

**单独跑**：`cd mail && ../../relay/.venv/bin/python -m pytest -q`（或 mail 自己的
venv）。与 relay/tests 一样按服务目录独立运行——两边的模块名（store/admin/http）
同名，混在同一个 pytest 进程里会互相遮蔽。

与 relay/tests/conftest.py 的差异（拆分后的世界）：

- 没有 `provisioned` 的配对链路：mail 没有账号/设备表，归属由
  `app["resolve_device"]` 给出。测试注入一个**注册表式假解析器**：
  `register_device` 发令牌，`unregister_device` 模拟撤销/过期（令牌解析不到 =
  匿名，与生产里中转不可达的降级同一条路）。
- `provisioned` 保留同名同形（`["agent"]["agentId"]` / `["account"]["accountId"]`），
  让从中转移植来的用例少改调用点；agent 字段在 mail 侧没有对应物，被忽略。
"""

from __future__ import annotations

import secrets
import sys
from pathlib import Path
from typing import AsyncIterator

import pytest

MAIL_DIR = Path(__file__).resolve().parents[1]
if str(MAIL_DIR) not in sys.path:
    sys.path.insert(0, str(MAIL_DIR))

import mail as mail_module  # noqa: E402
from store import Store  # noqa: E402

#: 测试里的"这台电脑"账号：mail 只把它当不透明字符串。
ACCOUNT_ID = "acc_test"
#: 团队收件箱（2026-10-15）：测试环境的团队账号。
TEAM_ACCOUNT = "acc_team"


@pytest.fixture
def store(tmp_path) -> AsyncIterator[Store]:
    instance = Store(str(tmp_path / "mail.db"))
    try:
        yield instance
    finally:
        instance.close()


@pytest.fixture
def provisioned() -> dict:
    """与 relay/tests/conftest.py 的同名夹具同形（agent 字段被 mail 侧忽略）。"""
    return {"account": {"accountId": ACCOUNT_ID}, "agent": {"agentId": "agt_test"}}


def device_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def feedback_ticket(client, text: str = "点了新建会话之后一直转圈", **fields) -> dict:
    """提交一条反馈并返回它的 `threadId`/`ticketKey`（014 的测试共用）。

    走的就是 App 的匿名提交路径（不带 Authorization），所以取件凭据是唯一的
    读取手段——与 relay 侧同一个口径。
    """
    payload = {"text": text, **fields}
    response = await client.post("/feedback/submit", json=payload)
    assert response.status == 200, await response.text()
    return await response.json()


# ── 假解析器：mail 侧的"设备"就是注册表里的一行 ─────────────────────────────

def register_device(client, *, account_id: str = ACCOUNT_ID, name: str = "DSH-Test") -> str:
    """往测试用的解析器里注册一台设备，返回它的令牌。

    `deviceId` 每次唯一（"重配换设备"的场景要靠它）；`account_id` 默认同一个，
    对应"重装后重新配对、账号不变"的世界。
    """
    registry: dict[str, dict] = client.app["test_devices"]
    serial = len(registry) + 1
    token = f"devtok_{serial}_{secrets.token_hex(4)}"
    registry[token] = {"deviceId": f"dev_{serial}", "accountId": account_id, "name": name}
    return token


def device_of(client, token: str) -> dict:
    """注册表里这台设备的归属（替代 relay 用例里的 `store.device_by_token`）。"""
    return client.app["test_devices"][token]


def unregister_device(client, token: str) -> None:
    """令牌从此解析不到 = 匿文（对应生产里的撤销/过期/中转不可达）。"""
    client.app["test_devices"].pop(token, None)


async def build_client(aiohttp_client, store: Store, *, team_account: str = TEAM_ACCOUNT):
    """装一份完整的 mail 应用（与生产同一组装路径），返回 aiohttp 测试客户端。

    `team_account=""` 就是 `MAIL_TEAM_ACCOUNT` 为空的部署形状：团队收件箱关闭。
    """
    registry: dict[str, dict] = {}
    notified: list[tuple[str | None, list[str] | None]] = []

    async def resolve(token: str):
        return registry.get(token)

    async def notify(account_id: str | None, keys: list[str] | None = None) -> None:
        """032：已读之后那声"去看看信件"。测试里记下来，不发网络请求。"""
        notified.append((account_id, keys))

    app = mail_module.create_app(store=store, resolve_device=resolve,
                                 notify_account_state=notify,
                                 team_account=team_account)
    app["test_devices"] = registry
    app["test_notified"] = notified
    return await aiohttp_client(app)


@pytest.fixture
async def client(aiohttp_client, store: Store):
    return await build_client(aiohttp_client, store)


@pytest.fixture
async def client_without_team(aiohttp_client, store: Store):
    """团队收件箱**关闭**（`MAIL_TEAM_ACCOUNT` 为空）的同一份服务。

    2026-10-17 的生产事故就是"开关关了、库里的团队绑定还在"这个组合，
    这条夹具让那个组合可复现——它与 `client` 共用同一个 `store`，所以
    「开关开着时写的信，关掉之后谁看得见」可以在一个用例里演进。
    """
    return await build_client(aiohttp_client, store, team_account="")
