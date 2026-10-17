"""信件服务的部署构建号（`/healthz` 的 `version`）。"""

from __future__ import annotations

import json

import mail as mail_module


def test_healthz_reports_unversioned_without_a_deploy_stamp(monkeypatch, tmp_path):
    """本机 pytest 没有 build.json：报 0.0.0，表示"这不是一次部署"。"""
    monkeypatch.setattr(mail_module, "_BUILD_FILE", tmp_path / "build.json")
    assert mail_module.deployed_version() == "0.0.0"


def test_healthz_reports_the_deploy_build_stamp(monkeypatch, tmp_path):
    stamp = tmp_path / "build.json"
    stamp.write_text(json.dumps({"version": "20261017.1240",
                                 "deployedAt": "2026-10-17T04:40:00Z"}), encoding="utf-8")
    monkeypatch.setattr(mail_module, "_BUILD_FILE", stamp)
    assert mail_module.deployed_version() == "20261017.1240"


def test_a_broken_build_file_does_not_break_the_endpoint(monkeypatch, tmp_path):
    stamp = tmp_path / "build.json"
    stamp.write_text("not json", encoding="utf-8")
    monkeypatch.setattr(mail_module, "_BUILD_FILE", stamp)
    assert mail_module.deployed_version() == "0.0.0"
