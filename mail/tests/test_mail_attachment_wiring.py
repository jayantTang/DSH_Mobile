"""服务装配（设计 M4）：附件目录、清扫任务、环境变量。

要钉三件事：附件目录由装配自己建好且是 0700；`sweep_interval_s=0`（测试默认）
一个后台任务都不起；起了的任务在应用关闭时被取消（用例不泄漏任务）。
"""

from __future__ import annotations

import os
import stat

import pytest

import mail as mail_module
from store import Store


def mode_of(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


async def resolve(_token):
    return None


async def notify(_account_id, _keys=None):
    return None


@pytest.fixture
def store(tmp_path):
    instance = Store(str(tmp_path / "mail.db"))
    try:
        yield instance
    finally:
        instance.close()


def app_for(store: Store, **options):
    return mail_module.create_app(store=store, resolve_device=resolve,
                                  notify_account_state=notify, **options)


def test_the_attachment_root_is_created_next_to_the_database_at_0700(store, tmp_path):
    app = app_for(store)
    root = app["attachments_root"]
    assert root == str(tmp_path / "attachments")
    assert os.path.isdir(root) and mode_of(root) == 0o700
    assert mode_of(os.path.join(root, "tmp")) == 0o700


def test_an_explicit_root_wins_over_the_default(store, tmp_path):
    app = app_for(store, attachments_root=str(tmp_path / "elsewhere"))
    assert app["attachments_root"] == str(tmp_path / "elsewhere")
    assert os.path.isdir(str(tmp_path / "elsewhere"))


async def test_no_sweeper_runs_unless_the_interval_is_positive(store, aiohttp_client):
    client = await aiohttp_client(app_for(store))
    try:
        assert client.app.get("attachment_sweeper") is None
        health = await client.get("/healthz")
        assert health.status == 200
        assert await health.json() == {"ok": True, "service": "dsh-mail", "version": "0.0.0"}
    finally:
        await client.close()


async def test_a_positive_interval_starts_a_task_that_cleanup_cancels(store, aiohttp_client):
    client = await aiohttp_client(app_for(store, sweep_interval_s=3600))
    sweeper = client.app["attachment_sweeper"]
    assert not sweeper.done(), "启动后清扫任务应该在等下一次间隔"
    await client.close()
    assert sweeper.cancelled() or sweeper.done(), "应用关闭时必须取消清扫任务"


def test_the_environment_variables_reach_the_parser(monkeypatch, tmp_path):
    monkeypatch.setenv("MAIL_ATTACHMENTS_DIR", str(tmp_path / "bytes"))
    monkeypatch.setenv("MAIL_ATTACHMENT_SWEEP_S", "90")
    args = mail_module.build_parser().parse_args([])
    assert args.attachments_dir == str(tmp_path / "bytes")
    assert args.attachment_sweep_s == 90.0


def test_the_parser_defaults_match_the_design(monkeypatch):
    """没配环境时：目录跟着库走（空串 = 用默认），清扫 3600 秒（设计 §3.3）。"""
    monkeypatch.delenv("MAIL_ATTACHMENTS_DIR", raising=False)
    monkeypatch.delenv("MAIL_ATTACHMENT_SWEEP_S", raising=False)
    args = mail_module.build_parser().parse_args([])
    assert args.attachments_dir == ""
    assert args.attachment_sweep_s == 3600.0
