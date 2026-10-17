"""中转自身版本标识的单元测试（`relay/version.py`）。"""

from __future__ import annotations

import json

import relay
import version


def test_describe_says_unversioned_without_a_deploy_stamp():
    """没有 `build.json`（本机 pytest）时不编版本号：0.0.0 = 这不是一次部署。"""
    described = version.describe()
    assert described["relayVersion"] == version.UNVERSIONED == "0.0.0"
    assert "build" not in described


def test_build_stamp_is_read_when_the_deploy_script_wrote_one(tmp_path, monkeypatch):
    stamp = tmp_path / "build.json"
    stamp.write_text(json.dumps({"version": "20261017.1240", "commit": "abc1234",
                                 "deployedAt": "2026-10-17T03:00:00Z"}), encoding="utf-8")
    monkeypatch.setattr(version, "_BUILD_FILE", stamp)
    described = version.describe()
    assert described["relayVersion"] == "20261017.1240"
    assert described["build"] == {"commit": "abc1234", "deployedAt": "2026-10-17T03:00:00Z"}


def test_a_stamp_without_a_version_still_counts_as_unversioned(tmp_path, monkeypatch):
    """老格式（只有 commit/deployedAt）的 build.json 不能冒充发布号。"""
    stamp = tmp_path / "build.json"
    stamp.write_text(json.dumps({"commit": "abc1234"}), encoding="utf-8")
    monkeypatch.setattr(version, "_BUILD_FILE", stamp)
    assert version.deployed_version() == "0.0.0"


def test_a_broken_build_file_is_ignored(tmp_path, monkeypatch):
    """坏文件不能让 /healthz 500：它是排障入口，比指纹更重要。"""
    stamp = tmp_path / "build.json"
    stamp.write_text("not json", encoding="utf-8")
    monkeypatch.setattr(version, "_BUILD_FILE", stamp)
    assert "build" not in version.describe()


def test_the_startup_line_never_assumes_a_commit():
    """生产上当场踩过：没有 git 元数据的机器只写 deployedAt，直接取 commit 会让服务崩溃。"""
    assert relay.version_log_line({"relayVersion": "1.0.0"}) == "relay: version 1.0.0"
    assert relay.version_log_line(
        {"relayVersion": "1.0.0", "build": {"deployedAt": "2026-10-17T04:38:03Z"}}
    ) == "relay: version 1.0.0 (deployed 2026-10-17T04:38:03Z)"
    assert relay.version_log_line(
        {"relayVersion": "1.0.0", "build": {"commit": "abc1234"}}
    ) == "relay: version 1.0.0 (commit abc1234)"
    # 连版本号都没有也要能打日志，不许再抛一次。
    assert relay.version_log_line({}) == "relay: version unknown"
