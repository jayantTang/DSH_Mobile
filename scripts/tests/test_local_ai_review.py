"""local_ai_review 的规则与 CLI 单测（无需网络、无需 Docker）。"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "local_ai_review.py"
SPEC = importlib.util.spec_from_file_location("local_ai_review", MODULE_PATH)
review = importlib.util.module_from_spec(SPEC)
sys.modules["local_ai_review"] = review
assert SPEC.loader is not None
SPEC.loader.exec_module(review)


def rows_of(diff_text: str):
    return review.added_lines(diff_text)


def test_patch_if_else_chain_blocks():
    diff = "\n".join(
        [
            "+++ b/mail/api.py",
            "@@ -1,3 +10,6 @@",
            "+    if mode == 'fast':",
            "+        return run_fast()",
            "+    elif mode == 'slow':",
            "+        return run_slow()",
            "+    elif mode == 'debug':",
            "+        return run_debug()",
        ]
    )
    findings = review.check_patch_if_else(rows_of(diff))
    assert [f.rule for f in findings] == ["patch_if_else"]


def test_patch_if_else_marker_blocks_single_branch():
    diff = "\n".join(
        [
            "+++ b/plugins/mobile-link/lib/router.js",
            "@@ -1,2 +1,3 @@",
            "+    if (op === 'special') { // 临时兜底",
            "+        handleSpecial()",
        ]
    )
    findings = review.check_patch_if_else(rows_of(diff))
    assert findings and findings[0].rule == "patch_if_else"


def test_two_branches_are_allowed():
    diff = "\n".join(
        [
            "+++ b/mail/api.py",
            "@@ -1,2 +1,3 @@",
            "+    if mode == 'fast':",
            "+    elif mode == 'slow':",
        ]
    )
    assert review.check_patch_if_else(rows_of(diff)) == []


def test_swallowed_exception_blocks():
    diff = "\n".join(
        [
            "+++ b/mail/internal.py",
            "@@ -5,2 +5,4 @@",
            "+    try:",
            "+        send()",
            "+    except Exception:",
            "+        pass",
        ]
    )
    findings = review.check_swallowed_error(rows_of(diff))
    assert findings and findings[0].rule == "swallowed_error"


def test_ineffective_mock_blocks():
    diff = "\n".join(
        [
            "+++ b/plugins/mobile-link/test/handoff.test.js",
            "@@ -1,1 +1,3 @@",
            "+  await browser.deliver(frame)",
            "+  expect(send).toHaveBeenCalled()",
            "+  expect(store.save.called).toBe(true)",
        ]
    )
    findings = review.check_ineffective_mock(rows_of(diff))
    assert [f.rule for f in findings] == ["ineffective_mock"]


def test_effective_mock_with_real_assertion_passes():
    diff = "\n".join(
        [
            "+++ b/mail/tests/test_feedback_store.py",
            "@@ -1,1 +1,3 @@",
            "+    hub.send(frame)",
            "+    assert sender.called",
            "+    assert hub.pending_count == 0",
        ]
    )
    assert review.check_ineffective_mock(rows_of(diff)) == []


def test_parse_llm_json_extracts_object():
    assert review.parse_llm_json('说明文字 {"block": true, "reasons": []} 尾巴') == {
        "block": True,
        "reasons": [],
    }
    assert review.parse_llm_json("不是 JSON") is None


def test_cli_blocks_on_patch_style(tmp_path):
    diff = "\n".join(
        [
            "diff --git a/mail/api.py b/mail/api.py",
            "+++ b/mail/api.py",
            "@@ -1,1 +20,4 @@",
            "+    if env == 'dev':",
            "+        return dev()",
            "+    elif env == 'prod':",
            "+        return prod()",
            "+    elif env == 'test':",
            "+        return test()",
        ]
    )
    diff_file = tmp_path / "x.diff"
    diff_file.write_text(diff + "\n", encoding="utf-8")
    assert review.main(["--diff-file", str(diff_file), "--no-llm", "--json"]) == 1


def test_cli_skips_docs_only(tmp_path):
    diff = "\n".join(
        [
            "+++ b/docs/ONBOARDING.md",
            "@@ -1,1 +1,2 @@",
            "+多一行文档",
        ]
    )
    diff_file = tmp_path / "docs.diff"
    diff_file.write_text(diff + "\n", encoding="utf-8")
    assert review.main(["--diff-file", str(diff_file), "--no-llm"]) == 0
