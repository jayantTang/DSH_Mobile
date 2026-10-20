#!/usr/bin/env python3
"""本地 Git Diff 审查：5 秒内给出可拦截的判定，不依赖 Docker、不依赖远程 CI。

两层审查，先规则后模型：
  1. 确定性规则（永远执行）：打补丁式 if-else 链、吞异常、无效 Mock 测试。
  2. 模型审查（可选）：走本机 OpenAI 兼容端点（默认 127.0.0.1:8799/v1），
     超时 5 秒；无凭据或端点不可用时降级为"跳过"，不影响规则判定。

退出码：0 通过；1 命中拦截项；2 工具自身错误（git 取不到 Diff、参数非法）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

EXIT_OK = 0
EXIT_BLOCK = 1
EXIT_ERROR = 2

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
BRANCH_RE = re.compile(
    r"^\s*(?:if|elif|else\s+if)\s*\(?\s*(?P<var>[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"
    r"\s*(?P<op>===|==|\.equals\s*\(|is)\s*"
    r"(?P<lit>['\"][^'\"]*['\"]|[A-Z][A-Z0-9_]*|-?\d+)\s*\)?"
)
SWALLOW_RE = re.compile(r"except[^:]*:\s*(pass|\.\.\.)\s*$|catch\s*\([^)]*\)\s*\{\s*\}\s*$")
MARKER_RE = re.compile(r"#\s*(hack|workaround|fixme)|临时|兜底|特例", re.IGNORECASE)
TEST_PATH_RE = re.compile(r"(^|/)(tests?|spec)/|(^|/)test_[^/]*\.py$|[._-]test\.(js|mjs|ts)$|Tests?\.swift$")
MOCK_ONLY_RE = re.compile(
    r"\.assert_called(_once)?\s*\(|\.assert_not_called\s*\(|\.assert_any_call\s*\("
    r"|assert\s+[\w\.]*(mock|spy|stub)[\w\.]*\.(called|call_count)"
    r"|toHaveBeenCalled|toBeCalled|expect\([^)]*\.called[^)]*\)\.toBe\(\s*true\s*\)"
    r"|assert\s+True\s*$|expect\(\s*true\s*\)\.toBe\(\s*true\s*\)",
    re.IGNORECASE,
)
ASSERT_RE = re.compile(r"^\s*(assert|self\.assert|expect\(|XCTAssert|#\[test\]|@Test\b)")
SLEEP_RE = re.compile(r"time\.sleep\(|await\s+sleep\(|Thread\.sleep\(")
CODE_SUFFIXES = (".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".swift", ".sh", ".go", ".rs", ".java", ".kt")


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    message: str

    def render(self) -> str:
        location = f"{self.file}:{self.line}" if self.line else self.file
        return f"  [{self.rule}] {location}  {self.message}"


def git(*args: str, cwd: Optional[Path] = None) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} 失败：{proc.stderr.strip()}")
    return proc.stdout


DIFF_ARGS = {
    "staged": ["diff", "--cached", "--no-color", "-U3"],
    "unstaged": ["diff", "--no-color", "-U3"],
    "range": ["diff", "--no-color", "-U3"],
}


def get_diff(mode: str, rev_range: Optional[str], diff_file: Optional[str], root: Path) -> str:
    if diff_file:
        return Path(diff_file).read_text(encoding="utf-8", errors="replace")
    if mode not in DIFF_ARGS:
        raise ValueError(f"未知模式 {mode}")
    if mode == "range" and not rev_range:
        raise ValueError("--mode range 需要 --range A..B")
    extra = [rev_range] if mode == "range" and rev_range else []
    return git(*DIFF_ARGS[mode], *extra, cwd=root)


def added_lines(diff: str) -> list[tuple[str, int, str]]:
    """解析新增行，返回 (文件, 新文件行号, 行内容)。"""
    rows: list[tuple[str, int, str]] = []
    current_file = ""
    new_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ b/"):
            current_file = raw[6:]
            continue
        if raw.startswith("+++ /dev/null"):
            current_file = ""
            continue
        match = HUNK_RE.match(raw)
        if match:
            new_line = int(match.group(1))
            continue
        if not current_file:
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            rows.append((current_file, new_line, raw[1:]))
            new_line += 1
        elif raw.startswith(" "):
            new_line += 1
    return rows


def check_patch_if_else(rows: Iterable[tuple[str, int, str]]) -> list[Finding]:
    branches: dict[tuple[str, str], list[tuple[int, str]]] = {}
    findings: list[Finding] = []
    for path, line, text in rows:
        match = BRANCH_RE.match(text)
        if not match:
            continue
        key = (path, match.group("var"))
        branches.setdefault(key, []).append((line, text.strip()))
        if MARKER_RE.search(text):
            findings.append(
                Finding("patch_if_else", path, line, f"新增特例分支并带临时标记：{text.strip()[:80]}")
            )
    for (path, var), items in branches.items():
        if len(items) >= 3:
            findings.append(
                Finding(
                    "patch_if_else",
                    path,
                    items[0][0],
                    f"对 `{var}` 新增 {len(items)} 个字面量分支，疑似用 if-else 堆叠特例；应改为表驱动或收敛到单一职责",
                )
            )
    return findings


def check_swallowed_error(rows: Iterable[tuple[str, int, str]]) -> list[Finding]:
    rows = list(rows)
    findings: list[Finding] = []
    for index, (path, line, text) in enumerate(rows):
        match = SWALLOW_RE.search(text.strip())
        if match:
            findings.append(Finding("swallowed_error", path, line, "新增空 catch / except pass，异常被吞掉"))
            continue
        if re.search(r"except[^:]*:\s*$", text.strip()) and index + 1 < len(rows):
            nxt = rows[index + 1]
            if nxt[0] == path and re.fullmatch(r"\s*(pass|\.\.\.)\s*", nxt[2]):
                findings.append(
                    Finding("swallowed_error", path, line, "新增 except: pass，异常被吞掉，至少记录或重抛")
                )
    return findings


def check_ineffective_mock(rows: Iterable[tuple[str, int, str]]) -> list[Finding]:
    findings: list[Finding] = []
    by_file: dict[str, list[tuple[int, str]]] = {}
    for path, line, text in rows:
        if not TEST_PATH_RE.search(path):
            continue
        by_file.setdefault(path, []).append((line, text))

    for path, items in by_file.items():
        asserts = [(line, text) for line, text in items if ASSERT_RE.search(text)]
        if not asserts:
            continue
        if all(MOCK_ONLY_RE.search(text) for _, text in asserts):
            line = asserts[0][0]
            findings.append(
                Finding(
                    "ineffective_mock",
                    path,
                    line,
                    "新增断言只检查 Mock 被调用，未校验真实行为；补一条对返回值或产物的断言",
                )
            )
        sleeps = [(line, text) for line, text in items if SLEEP_RE.search(text)]
        for line, _ in sleeps:
            findings.append(
                Finding("flaky_wait", path, line, "新增基于 sleep 的等待，测试结果不稳定；改为等待确定状态")
            )
    return findings


def parse_llm_json(content: str) -> Optional[dict]:
    """从模型回复里取出第一个完整 JSON 对象。"""
    start = content.find("{")
    while start != -1:
        depth = 0
        for index in range(start, len(content)):
            char = content[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(content[start : index + 1])
                    except json.JSONDecodeError:
                        break
        start = content.find("{", start + 1)
    return None


def resolve_token() -> str:
    for name in (
        "LOCAL_AI_REVIEW_TOKEN",
        "LLM_ROUTER_TOKEN",
        "OPENAI_API_KEY",
        "DEEPSEEK_API_KEY",
        "ANTHROPIC_API_KEY",
    ):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    config = Path.home() / ".dsh" / "llm-key-router" / "config.json"
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    token = data.get("token")
    return token if isinstance(token, str) else ""


def code_diff(diff: str) -> str:
    """只保留代码文件的 diff 块，文档与配置不进入模型上下文。"""
    blocks: list[str] = []
    current: list[str] = []
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            if current:
                blocks.append("\n".join(current))
            current = [line]
        elif current:
            current.append(line)
    if current:
        blocks.append("\n".join(current))
    kept = []
    for block in blocks:
        match = re.search(r"^\+\+\+ b/(.+)$", block, re.MULTILINE)
        if match and match.group(1).endswith(CODE_SUFFIXES):
            kept.append(block)
    return "\n".join(kept)


def llm_review(diff: str, timeout: float) -> tuple[Optional[dict], str]:
    """返回 (判定, 说明)。端点不可用或超时返回 (None, 原因)。"""
    token = resolve_token()
    if not token:
        return None, "无模型凭据"
    base = os.environ.get("LOCAL_AI_REVIEW_BASE_URL") or os.environ.get(
        "DSH_REVIEW_BASE_URL", "http://127.0.0.1:8799/v1"
    )
    model = os.environ.get("LOCAL_AI_REVIEW_MODEL", "deepseek-v4-flash")
    diff = code_diff(diff) or diff
    if len(diff) > 8000:
        diff = diff[:5000] + "\n…（已截断）…\n" + diff[-3000:]
    payload = json.dumps(
        {
            "model": model,
            "temperature": 0,
            "max_tokens": 400,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "你是严格的代码审查器。只依据给出的 diff 判定，不要推测 diff 之外的文件。"
                        "只拦截明确问题：打补丁式 if-else（为单个症状加特例分支）、无效 Mock 测试"
                        "（只断言 mock 被调用、不校验真实行为）、吞异常、明显的空实现或逻辑错误。"
                        "输出 JSON：{\"block\": true|false, "
                        "\"reasons\": [{\"file\": \"...\", \"line\": 0, \"reason\": \"...\"}]}，"
                        "不要输出其它文字。"
                    ),
                },
                {"role": "user", "content": diff},
            ],
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{base.rstrip('/')}/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=max(timeout, 0.1)) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        return None, f"模型审查不可用（{type(exc).__name__}），已跳过"
    elapsed = time.monotonic() - started
    try:
        message = body["choices"][0]["message"]
        content = message.get("content") or message.get("reasoning_content") or ""
    except (KeyError, IndexError, TypeError):
        return None, "模型返回结构异常，已跳过"
    verdict = parse_llm_json(content)
    if verdict is None:
        snippet = content.strip().replace("\n", " ")[:80]
        return None, f"模型回复不是 JSON（{elapsed:.1f}s）：{snippet}，已跳过"
    return verdict, f"模型审查 {elapsed:.1f}s"


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="本地 Diff 审查（无 Docker）")
    parser.add_argument("--mode", choices=["staged", "unstaged", "range"], default="staged")
    parser.add_argument("--range", dest="rev_range", default=None)
    parser.add_argument("--diff-file", default=None)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-llm", action="store_true")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    try:
        root = Path(git("rev-parse", "--show-toplevel").strip())
        diff = get_diff(args.mode, args.rev_range, args.diff_file, root)
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"local_ai_review: {exc}", file=sys.stderr)
        return EXIT_ERROR

    if not diff.strip():
        print("local_ai_review: 无改动，跳过")
        return EXIT_OK

    rows = added_lines(diff)
    code_rows = [row for row in rows if row[0].endswith(CODE_SUFFIXES)]
    if not code_rows:
        print(f"local_ai_review: {len(rows)} 行新增均为文档/配置，跳过审查")
        return EXIT_OK

    findings = (
        check_patch_if_else(rows)
        + check_swallowed_error(rows)
        + check_ineffective_mock(rows)
    )

    llm_note = "已用 --no-llm 跳过"
    llm_verdict: Optional[dict] = None
    if not args.no_llm:
        llm_verdict, llm_note = llm_review(diff, args.timeout)
        if llm_verdict:
            for reason in llm_verdict.get("reasons") or []:
                if not isinstance(reason, dict):
                    continue
                findings.append(
                    Finding(
                        "llm",
                        str(reason.get("file", "?")),
                        int(reason.get("line") or 0),
                        str(reason.get("reason", ""))[:200],
                    )
                )

    blocked = bool(findings) or bool(llm_verdict and llm_verdict.get("block"))
    if args.json:
        print(
            json.dumps(
                {
                    "blocked": blocked,
                    "findings": [finding.__dict__ for finding in findings],
                    "llm": {"note": llm_note, "block": bool(llm_verdict and llm_verdict.get("block"))},
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print(f"local_ai_review: {len(rows)} 行新增，{llm_note}")
        if findings:
            print("命中拦截项：")
            for finding in findings:
                print(finding.render())
        else:
            print("规则审查通过")

    return EXIT_BLOCK if blocked else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
