"""targeted_tests 的映射单测：只验证"改动文件 → 用例文件"的对应关系，不执行外部命令。"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "targeted_tests.py"
SPEC = importlib.util.spec_from_file_location("targeted_tests", MODULE_PATH)
targeted = importlib.util.module_from_spec(SPEC)
sys.modules["targeted_tests"] = targeted
assert SPEC.loader is not None
SPEC.loader.exec_module(targeted)


def test_relay_module_maps_to_keyword_selection():
    plans = targeted.plan_for("relay/hub.py")
    assert len(plans) == 1
    argv = plans[0].argv
    assert "pytest" in " ".join(argv)
    assert argv[-2:] == ["-k", "hub"]


def test_relay_test_file_runs_itself():
    plans = targeted.plan_for("relay/tests/test_hub.py")
    assert len(plans) == 1
    assert plans[0].argv[-1].endswith("relay/tests/test_hub.py")


def test_node_module_maps_to_same_name_test():
    plans = targeted.plan_for("plugins/mobile-link/lib/history.js")
    assert len(plans) == 1
    assert plans[0].argv[:2] == ["node", "--test"]
    assert plans[0].argv[-1].endswith("test/history.test.js")


def test_node_module_without_test_is_skipped():
    assert targeted.plan_for("plugins/mobile-link/lib/router.js") == []


def test_ios_change_is_marked_skip():
    plans = targeted.plan_for("ios/DSHMobile/DSHMobile/App.swift")
    assert len(plans) == 1
    assert plans[0].argv == ["true"]


def test_docs_change_produces_nothing():
    assert targeted.plan_for("docs/ONBOARDING.md") == []
