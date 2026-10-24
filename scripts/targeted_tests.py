#!/usr/bin/env python3
"""靶向测试：只跑受本次改动影响的最小用例集，30 秒内必须返回。

用法：
  scripts/targeted_tests.py --staged          # 用暂存区文件算影响面（pre-commit 用这个）
  scripts/targeted_tests.py path/a.py ...     # 显式给文件
  scripts/targeted_tests.py --staged --list   # 只看会跑什么，不执行

退出码：0 通过或无需运行；1 有用例失败/超时；2 工具自身错误。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUDGET_SECONDS = float(os.environ.get("LOCAL_GUARD_TEST_BUDGET", "30"))
Python_PYTEST = "pytest"
IOS_NOTE = "iOS 改动需要 xcodebuild（>30s），本地提交防线跳过；发布前按 scripts/verify/lanes.json 取证据"


@dataclass
class Command:
    label: str
    argv: list[str]
    cwd: Path


def changed_files(mode: str) -> list[str]:
    args = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]
    if mode == "unstaged":
        args = ["git", "diff", "--name-only", "--diff-filter=ACMR"]
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip())
    return [line for line in proc.stdout.splitlines() if line]


def python_venv() -> str:
    venv = ROOT / ".venv" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def pytest_command(label: str, test_dir: Path, target: Path | None, keyword: str | None) -> Command:
    argv = [python_venv(), "-m", "pytest", "-q", "--no-header"]
    if target is not None:
        argv.append(str(target))
    else:
        argv.append(str(test_dir))
    if keyword:
        argv.extend(["-k", keyword])
    return Command(label, argv, ROOT)


def plan_for(path: str) -> list[Command]:
    file = ROOT / path
    plans: list[Command] = []

    if path.startswith("relay-go/") and path.endswith(".go"):
        # 只跑改动所在的包；Go 命令经 make 走固定的缓存与代理设置（见 relay-go/Makefile）。
        target = Path(path).parent.as_posix().removeprefix("relay-go/")
        plans.append(Command(path, ["make", "-C", str(ROOT / "relay-go"), "test-pkg", f"PKG={target}"],
                             ROOT / "relay-go"))
        return plans

    if path in {"relay-go/go.mod", "relay-go/go.sum"}:
        plans.append(Command(path, ["make", "-C", str(ROOT / "relay-go"), "test"], ROOT / "relay-go"))
        return plans

    if (path.startswith("mail/") and path.endswith(".py")):
        test_dir = ROOT / "mail" / "tests"
        if "/tests/" in path:
            plans.append(pytest_command(path, test_dir, file, None))
        else:
            exact = test_dir / f"test_{file.stem}.py"
            plans.append(
                pytest_command(path, test_dir, exact if exact.exists() else None, None if exact.exists() else file.stem)
            )
        return plans

    if path.startswith("plugins/") and path.endswith((".js", ".mjs")):
        parts = Path(path).parts
        if len(parts) < 2:
            return plans
        package = ROOT / "plugins" / parts[1]
        test_dir = package / "test"
        if not test_dir.is_dir():
            return plans
        if "/test/" in path and path.endswith(".test.js"):
            plans.append(Command(path, ["node", "--test", str(file)], package))
        else:
            exact = test_dir / f"{file.stem}.test.js"
            if exact.exists():
                plans.append(Command(path, ["node", "--test", str(exact)], package))
            else:
                # 没有同名用例就不猜：整包并发跑会互相污染（历史用例已出现过这种失败）。
                print(f"[skip] {path}: 没有 test/{file.stem}.test.js，未选到靶向用例", file=sys.stderr)
        return plans

    if path.startswith("scripts/"):
        if path.endswith(".py"):
            exact = ROOT / "scripts" / "tests" / f"test_{file.stem}.py"
            if exact.exists():
                plans.append(pytest_command(path, ROOT / "scripts" / "tests", exact, None))
        elif path.endswith(".mjs"):
            exact = file.with_name(f"{file.stem}.test.mjs")
            if exact.exists():
                plans.append(Command(path, ["node", "--test", str(exact)], ROOT))
        return plans

    if path.startswith("ios/"):
        plans.append(Command(path, ["true"], ROOT))
        return plans

    return plans


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="靶向测试（无 Docker）")
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--unstaged", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--budget", type=float, default=BUDGET_SECONDS)
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)

    try:
        if args.files:
            files = args.files
        elif args.unstaged:
            files = changed_files("unstaged")
        else:
            files = changed_files("staged")
    except RuntimeError as exc:
        print(f"targeted_tests: {exc}", file=sys.stderr)
        return 2

    plans: list[Command] = []
    seen: set[tuple[str, str]] = set()
    for path in files:
        for command in plan_for(path):
            key = (command.label, tuple(command.argv))
            if key in seen:
                continue
            seen.add(key)
            plans.append(command)

    if not plans:
        print(f"targeted_tests: {len(files)} 个改动，无需靶向用例")
        return 0

    if args.list:
        for command in plans:
            print(f"  {command.label}: {' '.join(command.argv)}")
        return 0

    deadline = time.monotonic() + args.budget
    failures = 0
    for command in plans:
        remaining = deadline - time.monotonic()
        if command.argv == ["true"]:
            print(f"[skip] {command.label}: {IOS_NOTE}")
            continue
        if remaining <= 1:
            print(f"[skip] {command.label}: 30 秒预算已用完，未执行；请在发布前单独补跑")
            failures += 1
            continue
        print(f"[run ] {command.label}: {' '.join(command.argv)}（预算 {remaining:.0f}s）")
        try:
            proc = subprocess.run(command.argv, cwd=command.cwd, timeout=remaining)
        except subprocess.TimeoutExpired:
            print(f"[timeout] {command.label}: 超过预算，判定失败")
            failures += 1
            continue
        except OSError as exc:
            print(f"[error] {command.label}: {exc}")
            failures += 1
            continue
        if proc.returncode == 5 and Python_PYTEST in command.argv:
            # pytest 的 5 = 没收集到用例（文件名不带 test_、或 -k 没命中）。
            # 靶向选择本来就允许"这个文件没有对应用例"，不算失败。
            print(f"[skip] {command.label}: 没有匹配的用例（pytest 退出码 5）")
            continue
        if proc.returncode != 0:
            print(f"[fail] {command.label}: 退出码 {proc.returncode}")
            failures += 1
        else:
            print(f"[ok  ] {command.label}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
