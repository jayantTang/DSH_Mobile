#!/usr/bin/env python3
"""One table-driven test over report.py's lint rules.

The lint is the part of the report contract that has to keep working when nobody
is looking: a rule that silently stops firing turns every later report back into
the "pass because the engine was green" document this contract exists to replace.
So the rules are tested the way they fail — by feeding the checker a record that
breaks each one and asserting it notices.

    test/.venv/bin/python test/tools/test_report.py

Self-contained: builds its own run directory from fixed inputs, calls
`report.render`, and writes nothing outside a temporary directory.
"""

import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402  (path set above)

CASE = """---
id: TC-TEST-01
title: lint 自测用例
用例版本: 1
通过判据: 12 步全为通过；像素核对全部通过；无未验证步骤
---

# TC-TEST-01 lint 自测用例

## 步骤

1. 打开设置页，截图留证。
2. 确认设置页首屏分组齐全：连接方式、权限。
"""

DECLARATION = """构建: abc1234（Debug，仿真器 TEST-SIM），App 1.0
数据: 只读打开真实会话；未写入、未造数据
边界: 只核对首屏可见内容；屏幕外只留截图
基线: 上轮无遗留问题
"""

STEP1 = """操作: 打开设置页
实际: 设置页打开，首屏 3 个分组共 11 行，滚动到「关于」用时 0.4 秒
依据: 截图 01；断言 s01 pass
结论: 通过
异常: 无
"""

STEP2 = """操作: 确认分组齐全
实际: 首屏依次是「连接方式」「权限」「提醒」三组，各组标题字号一致，无重叠
依据: 截图 01 与 detail/events.ndjson 的 s02–s04 一致；像素核对无错误色
结论: 通过
异常: 无
"""

PLAN = {
    "run": "TESTRUN",
    "screens": [{"id": "settings", "steps": [
        {"row": 1, "id": "s01", "title": "打开设置页，截图留证。", "expect": [],
         "shots": [{"name": "settings"}]},
        {"row": 2, "id": "s02", "title": "确认设置页首屏分组齐全：连接方式、权限。",
         "expect": ["text:连接方式", "text:权限"], "shots": []},
    ]}],
}


def build(root, review, with_criteria=True):
    run_dir = os.path.join(root, "runs", "TESTRUN")
    os.makedirs(os.path.join(run_dir, "detail"))
    os.makedirs(os.path.join(run_dir, "shots"))
    os.makedirs(os.path.join(run_dir, "annotated"))
    with open(os.path.join(root, "case.md"), "w", encoding="utf-8") as handle:
        handle.write(CASE)
    plan = json.loads(json.dumps(PLAN))
    if not with_criteria:
        plan.pop("criteria", None)
    with open(os.path.join(run_dir, "detail", "plan.json"), "w", encoding="utf-8") as handle:
        json.dump(plan, handle, ensure_ascii=False)
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        record = {"run": "TESTRUN", "case": "TC-TEST-01", "caseTitle": "lint 自测用例",
                   "caseVersion": "1", "caseFile": "case.md", "gitCommit": "abc1234",
                   "criteria": ["12 步全为通过", "像素核对全部通过", "无未验证步骤"],
                   "at": "2026-09-16T18:00:00Z", "durationSeconds": 12.5,
                   "environment": {"simulator": "TEST-SIM", "ios": "26.3", "model": "iPhone-17-Pro",
                                   "xcode": "26.3", "host": "26.0 macOS"},
                   "appBuild": "1",
                   "engineVerdict": "PASS", "pixelOk": True, "host": {"port": 1, "source": "test"},
                   "simulator": "TEST-SIM", "appVersion": "1.0",
                   "verdicts": [{"id": "s01", "status": "pass", "detail": "已到达该状态"},
                                {"id": "s02", "status": "pass", "detail": "存在 text:连接方式"}],
                   "screenshots": [{"step": "s01", "name": "settings",
                                    "file": "01-s01-settings.png", "note": "设置页"}]}
        if not with_criteria:
            record.pop("criteria", None)
        json.dump(record, handle, ensure_ascii=False)
    # The picture the summary references has to exist, or artifact-missing fires.
    open(os.path.join(run_dir, "shots", "01-s01-settings.png"), "wb").write(b"")
    with open(os.path.join(run_dir, "review.md"), "w", encoding="utf-8") as handle:
        handle.write(review)
    return run_dir


def check(review, with_criteria=True):
    """Renders the fixture and returns `{code: [messages]}` plus the verdict."""
    root = tempfile.mkdtemp(prefix="dsh-lint-")
    try:
        run_dir = build(root, review, with_criteria)
        _, errors, warnings = report.render(run_dir, "通过", "自测")
        codes = {}
        for code, message in errors + warnings:
            codes.setdefault(code, []).append(message)
        return codes
    finally:
        shutil.rmtree(root, ignore_errors=True)


GOOD = "# 评审\n\n## 声明\n\n" + DECLARATION + "\n## r1\n\n" + STEP1 + "\n## r2\n\n" + STEP2


CASES = [
    ("干净的记录不该报任何问题",
     GOOD, [], {}),
    ("缺执行前声明 → missing-declaration",
     GOOD.replace(DECLARATION, ""), ["missing-declaration"]),
    ("少写一步 → step-missing",
     GOOD.split("## r2")[0], ["step-missing"]),
    ("结论不是四态 → verdict-invalid",
     GOOD.replace("结论: 通过\n异常: 无\n\n## r2", "结论: 看着还行\n异常: 无\n\n## r2"),
     ["verdict-invalid"]),
    ("实际是空的 → observed-empty",
     GOOD.replace("实际: 设置页打开，首屏 3 个分组共 11 行，滚动到「关于」用时 0.4 秒", "实际: "),
     ["observed-empty"]),
    ("实际复述期望 → observed-parrots",
     GOOD.replace("实际: 首屏依次是「连接方式」「权限」「提醒」三组，各组标题字号一致，无重叠",
                  "实际: 出现「连接方式」、「权限」"),
     ["observed-parrots"]),
    ("实际只说「正常」 → evidence-weak",
     GOOD.replace("实际: 设置页打开，首屏 3 个分组共 11 行，滚动到「关于」用时 0.4 秒", "实际: 正常"),
     ["evidence-weak"]),
    ("实际与依据都没有可核对的东西 → evidence-weak",
     GOOD.replace("实际: 首屏依次是「连接方式」「权限」「提醒」三组，各组标题字号一致，无重叠",
                  "实际: 三个分组都在，看起来整齐")
         .replace("依据: 截图 01 与 detail/events.ndjson 的 s02–s04 一致；像素核对无错误色", "依据: 看过了"),
     ["evidence-weak"]),
    ("产品类发现缺影响/复现/证据 → finding-incomplete",
     GOOD + "\n## 发现\n\n产品: 设置页滚动时标题闪一下\n",
     ["finding-incomplete"]),
    ("异常类别写错 → finding-incomplete",
     GOOD.replace("异常: 无\n\n## r2", "异常: 界面|分组标题偏移 2pt|滚动 3/3 次\n\n## r2"),
     ["finding-incomplete"]),
    ("产品类发现写全了 → 通过",
     GOOD + "\n## 发现\n\n产品: 设置页滚动时标题闪一下\n影响: 视觉抖动，不影响操作\n"
            "复现: 设置页上下滚动 3/3 次\n证据: 截图 04\n",
     []),
    ("用例没声明通过判据 → no-criteria",
     GOOD, ["no-criteria"], {"with_criteria": False}),
    ("产品写「无」不算发现 → 通过",
     GOOD + "\n## 发现\n\n产品: 无（本轮未发现产品缺陷）\n",
     []),
]


def main():
    failures = []
    for case in CASES:
        name, review, expected = case[0], case[1], case[2]
        codes = check(review, **(case[3] if len(case) > 3 else {}))
        got = sorted(set(codes))
        want = sorted(set(expected))
        ok = got == want
        print(f"{'✓' if ok else '✗'} {name}")
        if not ok:
            failures.append((name, want, got, codes))
        else:
            for code in got:
                print(f"      {code}: {codes[code][0]}")
    # artifact-missing needs the summary, not the review, to be wrong: render
    # once more with a screenshot entry whose file was never written.
    root = tempfile.mkdtemp(prefix="dsh-lint-")
    try:
        run_dir = build(root, GOOD)
        os.remove(os.path.join(run_dir, "shots", "01-s01-settings.png"))
        _, errors, _ = report.render(run_dir, "通过", "自测")
        codes = [code for code, _ in errors]
        ok = "artifact-missing" in codes
        print(f"{'✓' if ok else '✗'} 截图文件缺失 → artifact-missing")
        if not ok:
            failures.append(("截图文件缺失", ["artifact-missing"], codes, {}))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        for name, want, got, codes in failures:
            print(f"FAIL {name}\n  期望 {want}\n  实到 {got}\n  {codes}")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
