#!/usr/bin/env python3
"""Renders one run as an HTML report, and refuses to render a report that lies.

The report is for a person deciding whether to accept the work, so it is built
the way review documents are: numbered sections that can be pointed at ("看 2.3"),
a verdict per step, the screenshot next to the step it belongs to, and — for
every step — what was actually observed and what that observation is based on.

Two rules carry the honesty of the thing:

  * the four fields a reviewer reads (期望 / 实际 / 依据 / 结论) all come from the
    tester, and `实际` has to say something the expectation did not;
  * the report is only produced when the record is complete enough to mean
    something — see `test/REPORT-CONTRACT.md`.

Usage:
  report.py --run-dir test/runs/<id> --verdict 通过 --note "一句话结论"
  report.py --run-dir test/runs/<id> --scaffold      # writes review.md skeleton
  report.py --run-dir test/runs/<id> --verdict 失败 --allow-lint-errors  # 调试用

Exit codes: 0 written (judgement 报告不完整 when lint blocked it); 2 bad arguments.
The last stdout line is a JSON result — `{report, verdict, lint:{ok,errors,warnings}}`.
"""

import argparse
import html
import json
import os
import re
import sys

# Four states, because "not tested" and "tested and broken" are different
# answers and collapsing them is how a report starts lying.
STATES = {
    "通过": ("pass", "#1a7f37", "#e7f4ea"),
    "可疑": ("suspect", "#9a6700", "#fdf3d8"),
    "失败": ("fail", "#b42318", "#fde8e6"),
    "未验证": ("unknown", "#57606a", "#eef0f2"),
}

# Engine verdicts to the report's vocabulary. `blocked` means the step never ran
# because something before it failed: unverified, not failed.
ENGINE_STATES = {"pass": "通过", "fail": "失败", "blocked": "未验证"}

FINDING_KINDS = ("产品", "用例", "环境")

# A case that declares no criteria still gets audited against the default the
# contract states, so an old case is judged by a stated rule instead of by taste.
DEFAULT_CRITERIA = ("四态全为通过，无失败项", "像素核对全部通过", "无未验证或可疑的步骤")

# What the report recommends, and what each recommendation costs. The wording is
# deliberately the release language a reader already knows; the names in
# parentheses are the machine-readable values written to summary.json.
POSTURES = {
    "GO": ("合入", "#1a7f37", "#e7f4ea"),
    "NO-GO": ("不合入", "#b42318", "#fde8e6"),
    "CONDITIONAL": ("有条件合入", "#9a6700", "#fdf3d8"),
}

# The verdict a blocked report carries, so no downstream reader can mistake a
# failed lint for an accepted judgement.
BLOCKED_VERDICT = "报告不完整"

CSS = """
/* Chinese has to be named, not inherited.
 *
 * `-apple-system` resolves to the system UI font, and on iOS that font reports
 * itself unable to draw a CJK glyph — a native view still renders Chinese, but a
 * web view uses only the families the stylesheet names and fell back to empty
 * boxes. Naming PingFang first is what every Chinese site does for the same
 * reason, and on macOS PingFang is the Chinese font a browser picks anyway, so
 * both ends render the same page the same way.
 *
 * The trade-off is Latin text: with PingFang first, digits and file paths take
 * PingFang's Latin glyphs instead of the system UI font. That is a small,
 * deliberate price for text that renders everywhere.
 */
:root { color-scheme: light; }
* { box-sizing: border-box; }
body {
  margin: 0 auto; padding: 32px 24px 64px; max-width: 820px;
  font: 15px/1.6 "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Helvetica Neue", sans-serif;
  color: #1f2328; background: #fff;
}
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 17px; margin: 36px 0 12px; padding-bottom: 6px; border-bottom: 1px solid #d8dee4; }
h3 { font-size: 15px; margin: 20px 0 8px; }
a { color: #0969da; }
.meta { color: #57606a; font-size: 13px; margin-bottom: 20px; }
.meta code { background: #f6f8fa; padding: 1px 5px; border-radius: 4px; }
.verdict {
  display: flex; align-items: baseline; flex-wrap: wrap; gap: 10px;
  padding: 14px 16px; border-radius: 8px; margin: 18px 0 6px;
}
.verdict .value { white-space: nowrap; font-size: 20px; font-weight: 600; }
.verdict .note { flex: 1 1 100%; }
.verdict .label { font-size: 13px; color: #57606a; }
.wall {
  margin: 16px 0; padding: 12px 16px; border-radius: 8px;
  background: #fde8e6; border: 1px solid #f3b3ab;
}
.wall .head { font-weight: 600; color: #b42318; margin-bottom: 6px; }
.wall ul { margin: 6px 0 0; padding-left: 20px; font-size: 13px; }
.wall code { background: rgba(0,0,0,.05); padding: 1px 5px; border-radius: 4px; }
.note { color: #1f2328; }
.grid { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 4px; }
.grid .cell {
  flex: 1 1 150px; padding: 8px 12px; border: 1px solid #e4e8ec;
  border-radius: 8px; background: #fafbfc;
}
.grid .k { display: block; color: #57606a; font-size: 12px; }
.grid .v { font-size: 17px; font-weight: 600; font-variant-numeric: tabular-nums; }
.posture { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin: 14px 0 4px; }
.posture .value { font-size: 18px; font-weight: 700; }
.criteria { margin: 6px 0 0; padding-left: 20px; }
.criteria li { margin: 2px 0; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid #e4e8ec; vertical-align: top; }
th { color: #57606a; font-weight: 500; background: #f6f8fa; }
.badge {
  display: inline-block; min-width: 46px; text-align: center;
  padding: 1px 8px; border-radius: 999px; font-size: 12px; font-weight: 600;
}
.kind { display: inline-block; padding: 1px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }
.kind-product { background: #fde8e6; color: #b42318; }
.kind-case { background: #fdf3d8; color: #9a6700; }
.kind-env { background: #eef0f2; color: #57606a; }
.step { margin: 10px 0 18px; }
.step > summary { cursor: pointer; list-style: none; }
.step > summary::-webkit-details-marker { display: none; }
.step > summary::before { content: "▸"; color: #57606a; margin-right: 6px; font-size: 11px; }
.step[open] > summary::before { content: "▾"; }
.step-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
.step-head .title { font-weight: 600; }
.step-head .num { color: #57606a; font-variant-numeric: tabular-nums; }
figure { margin: 10px 0 0; max-width: 560px; }
figure img {
  display: block; width: 100%; height: auto;
  border: 1px solid #d8dee4; border-radius: 8px; background: #f6f8fa;
}
figcaption { color: #57606a; font-size: 12px; margin-top: 6px; }
.findings { margin: 8px 0 0; padding: 8px 12px; border-radius: 6px; font-size: 13px; }
.findings div + div { margin-top: 4px; }
.empty { color: #57606a; font-size: 13px; }
table.fields { margin: 6px 0 0; font-size: 13px; }
table.fields th { width: 84px; color: #57606a; font-weight: 500; background: #fafbfc; }
table.fields td { color: #1f2328; }
footer { margin-top: 44px; padding-top: 12px; border-top: 1px solid #d8dee4; color: #57606a; font-size: 12px; }
"""


def esc(value):
    return html.escape(str(value if value is not None else ""))


def badge(state):
    key, ink, background = STATES[state]
    return f'<span class="badge {key}" style="color:{ink};background:{background}">{state}</span>'


def paraphrase(selectors):
    """The checks, in the words a reviewer reads.

    `text:提醒` is a query, not an expectation. Grouped by kind so several read
    as one sentence — 出现「连接方式」、「权限」、「提醒」 — while the mechanical form
    stays in the steps file where it belongs.
    """
    quoted = []
    elements = []
    for selector in selectors:
        prefix, _, value = selector.partition(":")
        if prefix in ("text", "label"):
            quoted.append(html.escape(value))
        elif prefix == "id":
            elements.append(html.escape(value))
        else:
            quoted.append(html.escape(selector))
    parts = []
    if quoted:
        parts.append("出现「" + "」、「".join(quoted) + "」")
    if elements:
        parts.append("元素 " + "、".join(f"<code>{name}</code>" for name in elements) + " 存在")
    return "；".join(parts)


# A picture wide enough to read the interface text, small enough to load over a
# relay on a phone. Measured: at 640px the 13px captions in a screenshot are
# still legible; below ~560px the smallest labels start to smear.
PREVIEW_WIDTH = 640
PREVIEW_QUALITY = 80


def write_preview(source, target, width=PREVIEW_WIDTH, quality=PREVIEW_QUALITY):
    """Writes the downscaled JPEG the report displays, and returns its relative path.

    Files rather than data URIs. Embedding looked convenient — one self-contained
    file — but it put a 300,000-character line inside the report, which no text
    viewer can page through and which the phone's file reader would try to lay
    out as a single row of text. A sibling file loads natively in the browser and
    in a WKWebView, and keeps the HTML small enough to read anywhere.
    """
    try:
        from PIL import Image
    except ImportError:
        return None
    if not os.path.exists(source):
        return None
    try:
        image = Image.open(source).convert("RGB")
        if image.width > width:
            image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
        image.save(target, format="JPEG", quality=quality, optimize=True)
        return os.path.basename(target)
    except Exception:
        return None


def preview_for(run_dir, entry):
    """Makes (once) and returns the report's picture for one screenshot."""
    name = entry.get("file")
    if not name:
        return None
    media = os.path.join(run_dir, "media")
    os.makedirs(media, exist_ok=True)
    stem = os.path.splitext(name)[0]
    target = os.path.join(media, f"{stem}.jpg")
    if not os.path.exists(target):
        # Prefer the annotated copy: it carries the step and the verdict on the
        # picture itself, which is what makes a screenshot self-explanatory.
        for source in (os.path.join(run_dir, "annotated", name),
                       os.path.join(run_dir, "shots", name)):
            if write_preview(source, target):
                return f"media/{stem}.jpg"
        return None
    return f"media/{stem}.jpg"


def read_json(path, fallback=None):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


# --------------------------------------------------------------------- record

FIELD_NAMES = {
    "操作": "action", "动作": "action", "do": "action",
    "期望": "expect", "期望效果": "expect",
    "实际": "observed", "实际现象": "observed", "现象": "observed",
    "依据": "evidence", "判定依据": "evidence",
    "结论": "verdict", "本步结论": "verdict",
    "备注": "note",
    "异常": "anomaly",
}

DECLARATION_KEYS = {
    "构建": "build", "数据": "data", "数据来源": "data",
    "边界": "boundary", "覆盖边界": "boundary",
    "基线": "baseline", "基线状态": "baseline",
}

DECLARATION_LABELS = {
    "build": "被测构建", "data": "数据来源", "boundary": "覆盖边界", "baseline": "基线状态",
}

FINDING_FIELDS = {
    "影响": "impact", "复现": "reproduce", "证据": "evidence",
    "处理建议": "advice", "建议": "advice",
}

# The order a reviewer reads them in. Kept separately from the map above because
# iterating a `label -> key` dict yields labels, which is how a lint rule ends up
# printing `KeyError: 'impact'` instead of the missing field's name.
FINDING_ORDER = ("impact", "reproduce", "evidence", "advice")

RANGE_SEPARATOR = re.compile(r"^\s*(?:[–—~]|\.\.|-)\s*")


def expand_key(key):
    """`r3` → ['r3']; `r1–r16` → ['r1', ..., 'r16'].

    A section heading may cover a run of steps, because "r1–r16 都顺利到达" is a
    honest thing to write when sixteen steps share one observation — but every
    step it covers still needs its own conclusion.
    """
    match = re.match(r"^r(\d+)\s*(?:[–—~]|\.\.|-)\s*r?(\d+)$", key)
    if not match:
        return [key]
    start, end = int(match.group(1)), int(match.group(2))
    if end < start:
        start, end = end, start
    return [f"r{number}" for number in range(start, end + 1)]


def split_blocks(text, heading):
    """The `## <heading>` sections of review.md, as one string each."""
    pattern = re.compile(r"^##\s*(.+?)\s*$", re.M)
    marks = list(pattern.finditer(text))
    found = []
    for index, mark in enumerate(marks):
        title = mark.group(1).strip().lower()
        if title != heading:
            continue
        end = marks[index + 1].start() if index + 1 < len(marks) else len(text)
        found.append(text[mark.end():end])
    return found


def read_fields(block, names):
    """`键: 值` lines, continuation lines appended to the field before them."""
    fields = {}
    current = None
    for line in block.split("\n"):
        match = re.match(r"^\s*(?:[-*]\s*)?([^:：]{1,6})[:：]\s*(.*)$", line)
        key = names.get(match.group(1).strip()) if match else None
        if key:
            current = key
            fields[key] = match.group(2).strip()
            continue
        if current and line.strip():
            fields[current] = (fields[current] + " " + line.strip()).strip()
    return fields


def basis_from_review(record):
    """The `## 判定` section of review.md, if the tester wrote one there."""
    block = record.get("judgementBlock") or ""
    if not block:
        return ""
    fields = read_fields(block, {"判定依据": "basis", "依据": "basis", "理由": "basis"})
    if fields.get("basis"):
        return fields["basis"]
    return " ".join(line.strip() for line in block.split("\n") if line.strip())


def read_review(run_dir):
    """The tester's own record: the declaration, each step, findings, regression.

    The engine can report that an element existed and the pixels can report that
    ink was present; neither can say "列表渲染正常，滚动无卡顿". That sentence is the
    tester's, written after looking at the screenshot, and it lives in its own
    file so it can be corrected without re-running anything.
    """
    path = os.path.join(run_dir, "review.md")
    if not os.path.exists(path):
        return {"steps": {}, "declaration": {}, "declarationRaw": "", "findings": [],
                "regression": {}, "preamble": "", "exists": False}
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    pattern = re.compile(r"^##\s*(.+?)\s*$", re.M)
    marks = list(pattern.finditer(text))
    record = {"steps": {}, "declaration": {}, "declarationRaw": "", "findings": [],
              "regression": {}, "judgementBlock": "", "preamble":
              text[:marks[0].start()].strip() if marks else text.strip(),
              "exists": True}

    for index, mark in enumerate(marks):
        title = mark.group(1).strip()
        end = marks[index + 1].start() if index + 1 < len(marks) else len(text)
        body = text[mark.end():end]

        if title.lower() in ("声明", "执行前声明"):
            record["declarationRaw"] = body.strip()
            record["declaration"] = read_fields(body, DECLARATION_KEYS)
            continue

        if title.lower() in ("发现", "问题", "findings"):
            record["findings"] = read_findings(body)
            continue

        if title.lower() in ("回归", "上轮问题回归"):
            record["regression"] = read_fields(body, {
                "上轮": "previous", "本轮": "current", "结论": "verdict",
            })
            continue

        if title.lower() in ("判定", "本次判定"):
            record["judgementBlock"] = body.strip()
            continue

        keys = expand_key(title)
        fields = read_fields(body, FIELD_NAMES)
        fields["verdict"] = (fields.get("verdict") or "").replace("*", "").strip()
        fields["section"] = title
        for key in keys:
            record["steps"][key] = fields
    return record


def read_findings(body):
    """The `## 发现` section: one blank-line-separated block per finding.

    A block starts with `产品:` / `用例:` / `环境:` and continues with the labelled
    lines that follow it, so the free-form tail a person writes stays attached to
    its own finding instead of silently joining the next one.
    """
    findings = []
    current = None
    for line in body.split("\n"):
        start = re.match(r"^\s*(?:[-*]\s*)?(产品|用例|环境)\s*[:：]\s*(.*)$", line)
        if start:
            current = {"kind": start.group(1), "summary": start.group(2).strip()}
            findings.append(current)
            continue
        if current is None:
            continue
        match = re.match(r"^\s*(?:[-*]\s*)?([^:：]{1,6})[:：]\s*(.*)$", line)
        key = FINDING_FIELDS.get(match.group(1).strip()) if match else None
        if key:
            current[key] = match.group(2).strip()
            current["_last"] = key
            continue
        if line.strip() and current.get("_last"):
            current[current["_last"]] = (current[current["_last"]] + " " + line.strip()).strip()
    # `产品: 无` is how a tester says "none here" — it is not a finding, and
    # treating it as one turns the honest answer into a lint failure.
    return [item for item in findings
            if not (re.sub(r"[（(].*?[)）]", "", item["summary"]).strip() in ("无", "none", "-")
                    and len(item) <= 3)]


def repo_root(run_dir):
    """`test/runs/<id>` → the repo root, so a case file path in the summary resolves."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(run_dir))))


def read_case_wording(run_dir, summary, plan):
    """Each case step's own sentence, by plan row — what `实际` must not parrot."""
    path = summary.get("caseFile") or ""
    if path and not os.path.isabs(path):
        path = os.path.join(repo_root(run_dir), path)
    wording = {}
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        text = ""
    if not text:
        return wording
    start = None
    lines = text.split("\n")
    for index, line in enumerate(lines):
        if re.match(r"^#{2,}[ \t]*步骤", line):
            start = index + 1
            break
    if start is None:
        return wording
    row = 0
    for line in lines[start:]:
        if re.match(r"^#{2,}[ \t]", line):
            break
        numbered = re.match(r"^\s*(\d+)[.、)]\s+(.*)$", line)
        if numbered:
            row += 1
            wording[row] = numbered.group(2).strip()
        elif row and line.strip():
            wording[row] += " " + line.strip()
    for screen in plan.get("screens", []):
        for step in screen.get("steps", []):
            if step.get("row") is not None:
                wording[str(step["row"])] = wording.get(step["row"], step.get("title", ""))
    return wording


def steps_of(plan):
    """The case's own steps: one numbered line, however many directives it holds.

    A case line like "确认两个入口都在" becomes two engine steps (one assertion
    each) but stays one step in the report, because that is the unit a reviewer
    reads and answers for. The plan's `row` is what says which line a step came
    from.
    """
    rows = []
    by_row = {}
    for screen in plan.get("screens", []):
        for step in screen.get("steps", []):
            key = step.get("row")
            if key is None:
                key = f"solo-{len(rows)}"
            entry = by_row.get(key)
            if entry is None:
                entry = {"key": key, "screen": screen.get("id", ""), "ids": [],
                         "title": step.get("title", ""), "expect": [], "shots": []}
                by_row[key] = entry
                rows.append(entry)
            entry["ids"].append(step.get("id", ""))
            entry["expect"] = entry["expect"] or step.get("expect", [])
            entry["shots"].extend(shot.get("name", "") for shot in step.get("shots", []))
    return rows


# ----------------------------------------------------------------------- lint

FILLER = re.compile(r"(正常|没问题|无异常|一切正常|符合预期|未记录|见图|见截图|ok)")
NUMBER = re.compile(r"\d")
# What counts as something a second person could go and check. Deliberately not
# the bare counters (个/处/条/行/次): "三个分组都在" is a claim, not a
# measurement, and accepting it is how a lint rule stops meaning anything.
EVIDENCE_HINT = re.compile(
    r"(截图|原图|annotated|shot|detail|事件流|像素|录屏|"
    r"\d+\s*(?:秒|ms|pt|%|px|行|条|个|次|处|份)|"
    r"错误|报错|超时|编号|s\d{2}\b|r\d+\b)", re.I)


def plain(selectors):
    """`paraphrase` as text: what the expectation reads as once the HTML is gone.

    Tag-stripping has to happen *before* normalization, because the tags sit
    between two Chinese words and would otherwise glue "元素<code>…" into a
    different string than the tester's prose — which is exactly how a parrot
    check silently stops matching.
    """
    return html.unescape(re.sub(r"<[^>]+>", "", paraphrase(selectors))).strip()


def normalize(text):
    return re.sub(r"<[^>]*>|[\s，。、：；！？（）()\[\]「」【】,.:;!?'\"`|/\\~<>\-]+",
                  "", str(text or ""))


def shingles(text, size=3):
    compact = normalize(text)
    if len(compact) <= size:
        return {compact} if compact else set()
    return {compact[i:i + size] for i in range(len(compact) - size + 1)}


def overlap(left, right):
    """How much two pieces of prose are the same prose, 0–1."""
    one, two = shingles(left), shingles(right)
    if not one or not two:
        return 0.0
    return len(one & two) / len(one | two)


def lint(run_dir, record, case_steps, wording, summary, shots_by_step, previous=(),
         explicit_criteria=True):
    """Everything the contract checks, as `[(code, message)]`, errors first.

    Errors block the report: a record missing half its steps, or an `实际` that
    just restates the expectation, produces a document that looks like evidence
    and is not. Warnings are printed in the report instead of blocking it.
    """
    errors = []
    warnings = []

    steps = record["steps"]
    declaration = record["declaration"]
    for key, label in DECLARATION_LABELS.items():
        if not declaration.get(key):
            errors.append(("missing-declaration", f"执行前声明缺「{label}」"))

    for step in case_steps:
        key = f"r{step['key']}"
        seen = steps.get(key)
        if not seen:
            errors.append(("step-missing", f"{key}（{step['title']}）没有评审记录"))
            continue
        if not seen.get("observed"):
            errors.append(("observed-empty", f"{key} 的「实际」是空的"))
        if seen.get("verdict") not in STATES:
            errors.append(("verdict-invalid",
                           f"{key} 的结论「{seen.get('verdict') or '空'}」不是通过/可疑/失败/未验证"))
        expectation = normalize(plain(step["expect"]) or step.get("title", ""))
        source = normalize(wording.get(str(step["key"]), step.get("title", "")))
        observed = seen.get("observed", "")
        parroted = False
        for name, target in (("用例原文", source), ("期望效果", expectation)):
            if not target or not observed:
                continue
            compact = normalize(observed)
            ratio = overlap(observed, target)
            if ratio > 0.7 or (target in compact and len(compact) < len(target) * 1.3):
                errors.append(("observed-parrots",
                               f"{key} 的「实际」基本是{name}的复述（重合 {ratio:.0%}）：{observed[:40]}"))
                parroted = True
                break
        evidence_text = observed + " " + seen.get("evidence", "")
        has_hint = bool(EVIDENCE_HINT.search(evidence_text))
        if observed and not parroted:
            if not FILLER.sub("", observed).strip():
                errors.append(("evidence-weak",
                               f"{key} 的「实际」只有「{observed.strip()}」，没有具体事实"))
            elif not has_hint:
                # An empty 「依据」 does not excuse a claim with nothing to check
                # it against: weak evidence is weak evidence either way.
                errors.append(("evidence-weak",
                               f"{key} 没有可核对的证据（数字/计数/耗时/报错原文/截图编号）"))
            elif not NUMBER.search(evidence_text):
                warnings.append(("evidence-thin", f"{key} 的证据里没有数字，检查一下够不够核对"))
        for item in seen.get("anomaly", "").split(";"):
            item = item.strip()
            if not item or item in ("无", "none", "-"):
                continue
            kind = item.split("|")[0].strip()
            if kind not in FINDING_KINDS:
                errors.append(("finding-incomplete",
                               f"{key} 的「异常」类别「{kind}」不是 产品/用例/环境"))
            elif len([part for part in item.split("|") if part.strip()]) < 3:
                errors.append(("finding-incomplete",
                               f"{key} 的异常缺描述或复现：{item[:40]}"))
        if not shots_by_step.get(step["ids"][0] if step["ids"] else ""):
            if "截图" in wording.get(str(step["key"]), "") or "截图" in step.get("title", ""):
                warnings.append(("shot-missing-for-step", f"{key} 要求截图留证，但这一步没有截图"))

    # A case that never says what "pass" means can be graded on a curve, and the
    # report would look exactly the same. Old runs predate the field, so this is
    # a warning there and an error for anything run since.
    if not explicit_criteria:
        # Runs made before the field existed are warned about, everything after is
        # blocked — the rule has to apply to the reports written from now on.
        legacy = not summary.get("criteria") and str(summary.get("at", "")) < "2026-09-16T12"
        item = ("no-criteria", "用例没有声明「通过判据」，报告按契约默认判据审")
        (warnings if legacy else errors).append(item)

    for finding in record["findings"]:
        if finding["kind"] != "产品":
            continue
        missing = [label for label, key in FINDING_FIELDS.items()
                   if key in ("impact", "reproduce", "evidence") and not finding.get(key)]
        if missing:
            errors.append(("finding-incomplete",
                           f"产品类发现「{finding['summary'][:30]}」缺 " + "/".join(missing)))

    for entry in summary.get("screenshots", []):
        name = entry.get("file")
        if not name:
            continue
        if not any(os.path.exists(os.path.join(run_dir, folder, name))
                   for folder in ("shots", "annotated")):
            errors.append(("artifact-missing", f"报告引用的截图不存在：{name}"))

    uncovered = [f"r{step['key']}" for step in case_steps
                 if (steps.get(f"r{step['key']}") or {}).get("verdict") in ("未验证", "可疑")]
    if uncovered:
        warnings.append(("uncovered", "未验证或存疑的步骤：" + "、".join(uncovered)))
    if previous and not record["regression"]:
        warnings.append(("regression-absent",
                         f"上一轮 {previous[0]['run']} 判定「{previous[0]['judgement']}」，本轮没有「回归」一节"))
    return errors, warnings


# --------------------------------------------------------------------- render

def sibling_runs(run_dir, summary):
    """Earlier runs of the same case, newest first, as the record of what is open.

    Read from the runs themselves rather than from a hand-kept list: the previous
    run's commit and judgement are what the 基线 line of a declaration should
    quote, and everything still unfinished has to be answerable in this run's
    report. `open` says whether that run left something unresolved — 失败 / 可疑,
    or its own record admitting an unfinished step.
    """
    runs = os.path.dirname(os.path.abspath(run_dir))
    self_name = os.path.basename(os.path.abspath(run_dir))
    case = summary.get("case")
    found = []
    try:
        names = sorted(os.listdir(runs), reverse=True)
    except OSError:
        return found
    for name in names:
        if name == self_name:
            continue
        other = read_json(os.path.join(runs, name, "summary.json"))
        if not other or not case or other.get("case") != case:
            continue
        judgement = other.get("judgement") or "未判定"
        lint_errors = (other.get("lint") or {}).get("errors") or []
        unfinished = [item for item in lint_errors
                      if item.get("code") in ("step-missing", "observed-empty", "verdict-invalid")]
        found.append({
            "run": name,
            "commit": other.get("gitCommit", "?"),
            "judgement": judgement,
            "note": other.get("judgementNote", ""),
            "open": judgement in ("失败", "可疑", "报告不完整") or bool(unfinished),
        })
    return found



def criteria_of(summary, plan):
    """The case's own definition of done, and whether it was declared."""
    declared = summary.get("criteria") or plan.get("criteria") or []
    if declared:
        return list(declared), True
    return list(DEFAULT_CRITERIA), False


def rate(passed, total):
    return "—" if not total else f"{100 * passed / total:.0f}%"


def duration_text(seconds):
    if seconds is None:
        return "—"
    return f"{seconds:.1f} 秒" if seconds < 90 else f"{seconds / 60:.1f} 分"


def recommendation(judgement, summary, blocked):
    """合入 / 有条件合入 / 不合入, with the reason that decides it.

    The standard templates end in a release posture (GO / NO-GO / CONDITIONAL
    GO); this is that line, derived from facts the run already recorded rather
    than from the tester's mood. Order matters: a broken record and a failed
    check both outrank a clean one.
    """
    engine = summary.get("engineVerdict", "?")
    if blocked:
        return "NO-GO", "报告不完整——先补齐记录，判定还不成立"
    if judgement == "未验证" or engine == "ERROR":
        return "NO-GO", "这一轮没有真正测到，不能当作通过"
    # 可疑 outranks 失败 on purpose: a failure the tester attributed to the case
    # itself is a question for a person, not a verdict on the product. Saying
    # NO-GO there would be the report overruling its own finding.
    if judgement == "可疑":
        return "CONDITIONAL", "有存疑项（见「发现」），需要有人定夺后再合入"
    if judgement == "失败" or engine == "FAIL":
        return "NO-GO", "存在失败项（见「发现」与逐屏核对）"
    if engine == "PASS":
        return "GO", "该用例范围内未发现问题"
    return "CONDITIONAL", "引擎判定与人工判定不一致，需要复核"


def collect_facts(run_dir, summary, case_steps, record, pixel, shots):
    """The numbers a reader asks for first, computed once."""
    verdicts = summary.get("verdicts", [])
    engine_steps = [item for item in verdicts if item.get("kind") != "screen"]
    engine_pass = sum(1 for item in engine_steps if item.get("status") == "pass")
    pixel_results = pixel.get("results", [])
    pixel_pass = sum(1 for item in pixel_results if item.get("ok"))
    by_case = {"通过": 0, "失败": 0, "未验证": 0, "可疑": 0}
    for step in case_steps:
        state = (record["steps"].get(f"r{step['key']}") or {}).get("verdict")
        if state in by_case:
            by_case[state] += 1
    with_shot = sum(1 for step in case_steps if shots.get(step["ids"][0] if step["ids"] else ""))
    return {
        "enginePass": engine_pass,
        "engineTotal": len(engine_steps),
        "pixelPass": pixel_pass,
        "pixelTotal": len(pixel_results),
        "steps": len(case_steps),
        "casePass": by_case["通过"],
        "caseFail": by_case["失败"],
        "caseUnverified": by_case["未验证"] + by_case["可疑"],
        "shots": sum(1 for entry in summary.get("screenshots", []) if entry.get("file")),
        "stepsWithShot": with_shot,
    }


def environment_rows(summary):
    """What this run actually ran against — the reproducibility half of a report."""
    env = summary.get("environment") or {}
    build = summary.get("appBuild")
    rows = [
        ("代码版本", summary.get("gitCommit", "?"), True),
        ("App 版本", summary.get("appVersion", "?") + (f"（build {build}）" if build and build != "?" else ""), False),
        ("仿真器", env.get("simulator") or summary.get("simulator", "?"), False),
        ("设备型号", env.get("model", "?"), False),
        ("系统版本", f"iOS {env.get('ios', '?')}", False),
        ("Xcode", env.get("xcode", "?"), False),
        ("测试机", env.get("host", "?"), False),
        ("host", f"127.0.0.1:{summary.get('host', {}).get('port', '?')}"
                 f"（{summary.get('host', {}).get('source', '')}）", False),
        # Execution time, but not the duration: that one is already in the
        # overview grid, and printing it twice makes the report look padded.
        ("执行时间", summary.get("at", "?"), False),
    ]
    return rows


def render(run_dir, verdict, note, basis="", allow_lint_errors=False):
    summary = read_json(os.path.join(run_dir, "summary.json"), {})
    plan = read_json(os.path.join(run_dir, "detail", "plan.json"), {})
    pixel = read_json(os.path.join(run_dir, "detail", "verify.json"), {"results": []})
    run_id = summary.get("run", os.path.basename(run_dir.rstrip("/")))

    record = read_review(run_dir)
    if not basis:
        basis = basis_from_review(record)
    verdicts = {item.get("id"): item for item in summary.get("verdicts", [])}
    shots = summary.get("screenshots", [])
    shots_by_step = {}
    for entry in shots:
        if entry.get("file"):
            shots_by_step.setdefault(entry.get("step"), []).append(entry)

    case_steps = steps_of(plan)
    wording = read_case_wording(run_dir, summary, plan)
    history = sibling_runs(run_dir, summary)
    previous = [item for item in history if item["open"]]
    declared_criteria, criteria_was_declared = criteria_of(summary, plan)
    errors, warnings = lint(run_dir, record, case_steps, wording, summary, shots_by_step, previous,
                            explicit_criteria=criteria_was_declared)
    blocked = bool(errors) and not allow_lint_errors
    if blocked:
        verdict = BLOCKED_VERDICT

    out = []
    out.append("<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>")
    out.append("<meta name='viewport' content='width=device-width,initial-scale=1'>")
    out.append(f"<title>{esc(summary.get('case', '测试报告'))} {esc(summary.get('caseTitle', ''))}</title>")
    out.append(f"<style>{CSS}</style></head><body>")

    # ---- header -----------------------------------------------------------
    out.append(f"<h1>{esc(summary.get('case', ''))} {esc(summary.get('caseTitle', ''))}</h1>")
    out.append("<div class='meta'>"
               f"运行 <code>{esc(run_id)}</code>　"
               f"用例版本 {esc(summary.get('caseVersion') or '—')}　"
               f"代码版本 <code>{esc(summary.get('gitCommit', '?'))}</code>　"
               f"App {esc(summary.get('appVersion', '?'))}<br>"
               f"host 127.0.0.1:{esc(summary.get('host', {}).get('port', '?'))}"
               f"（{esc(summary.get('host', {}).get('source', ''))}）　"
               f"仿真器 {esc(summary.get('simulator', ''))}<br>"
               f"用例文件 <code>{esc(summary.get('caseFile', ''))}</code>"
               "</div>")

    # ---- 1 verdict ---------------------------------------------------------
    out.append("<h2 id='verdict'>1 判定</h2>")
    if blocked:
        key, ink, background = STATES["未验证"]
    else:
        key, ink, background = STATES[verdict]
    out.append(f"<div class='verdict {key}' style='background:{background}'>"
               f"<span class='label'>本次判定</span>"
               f"<span class='value' style='color:{ink}'>{esc(verdict)}</span>"
               + (f"<span class='note'>{esc(note)}</span>" if note else "") + "</div>")
    if blocked:
        out.append("<div class='wall'><div class='head'>报告不完整："
                   f"{len(errors)} 项必须补齐后才算报告</div><ul>"
                   + "".join(f"<li><code>{esc(code)}</code> {esc(message)}</li>"
                             for code, message in errors)
                   + "</ul><div class='empty'>补齐 <code>review.md</code> 后重跑 "
                     "<code>./test/run.sh report …</code>，不需要重跑用例。</div></div>")
    if basis:
        out.append(f"<p class='note'><strong>判定依据</strong>：{esc(basis)}</p>")
    elif not blocked:
        out.append(f"<p class='wall' style='background:#fdf3d8;border-color:#e6c76a'>"
                   f"<span class='head' style='color:#9a6700'>判定依据缺失</span>"
                   f"没有写「凭哪几条证据这么判」。</p>")
    facts = collect_facts(run_dir, summary, case_steps, record, pixel, shots_by_step)
    posture, posture_why = recommendation(verdict, summary, blocked)
    label, posture_ink, posture_bg = POSTURES[posture]
    out.append(f"<div class='posture' style='background:{posture_bg};padding:10px 14px;"
               f"border-radius:8px'>"
               f"<span class='label'>结论建议</span>"
               f"<span class='value' style='color:{posture_ink}'>{label}</span>"
               f"<span class='note'>{esc(posture_why)}</span></div>")
    out.append("<div class='grid'>" + "".join(
        f"<div class='cell'><span class='k'>{esc(name)}</span>"
        f"<span class='v'>{value}</span></div>"
        for name, value in (
            ("本轮用例通过", f"{facts['casePass']}/{facts['steps']}（{rate(facts['casePass'], facts['steps'])}）"),
            ("引擎断言通过", f"{facts['enginePass']}/{facts['engineTotal']}"
                            f"（{rate(facts['enginePass'], facts['engineTotal'])}）"),
            ("像素核对通过", f"{facts['pixelPass']}/{facts['pixelTotal']}"
                            f"（{rate(facts['pixelPass'], facts['pixelTotal'])}）"),
            ("未验证/可疑", f"{facts['caseUnverified']} 步"),
            ("截图", f"{facts['shots']} 张（覆盖 {facts['stepsWithShot']}/{facts['steps']} 步）"),
            ("耗时", duration_text(summary.get("durationSeconds"))),
        )) + "</div>")
    out.append(f"<p class='empty'>引擎判定 {esc(summary.get('engineVerdict', '?'))}"
               + ("；像素核对有未通过项" if not summary.get("pixelOk") else "")
               + "；结果计数来自引擎事件流，判定来自本报告的逐屏核对。</p>")

    # ---- numbered sections ------------------------------------------------
    section = 1
    def heading(title):
        nonlocal section
        section += 1
        out.append(f"<h2 id='s{section}'>{section} {esc(title)}</h2>")
        return section

    # 2 通过判据（用例自己声明的"什么算通过"）
    heading("通过判据")
    out.append("<ul class='criteria'>"
               + "".join(f"<li>{esc(item)}</li>" for item in declared_criteria) + "</ul>")
    out.append("<p class='empty'>"
               + ("来自用例的 front matter。" if criteria_was_declared
                  else "用例没有声明判据，按契约默认判据审。")
               + "判定必须按这份判据给出，不能换标准。</p>")

    # 3 执行前声明
    heading("执行前声明")
    declaration = record["declaration"]
    if any(declaration.get(key) for key in DECLARATION_LABELS):
        out.append("<table class='fields'>"
                   + "".join(f"<tr><th>{esc(DECLARATION_LABELS[key])}</th>"
                             f"<td>{esc(declaration.get(key) or '—')}</td></tr>"
                             for key in DECLARATION_LABELS)
                   + "</table>")
    else:
        out.append("<p class='empty'>没有执行前声明——被测构建、数据来源、覆盖边界、"
                   "基线状态都无从判断。</p>")
    out.append("<h3>测试环境</h3>")
    out.append("<table class='fields'>"
               + "".join(f"<tr><th>{esc(name)}</th>"
                         f"<td>{'<code>' + esc(value) + '</code>' if mono else esc(value)}</td></tr>"
                         for name, value, mono in environment_rows(summary))
               + "</table>")

    # 4 发现
    problems = [item for item in summary.get("verdicts", []) if item.get("status") == "fail"]
    findings_pixels = [item for item in pixel.get("results", []) if not item.get("ok")]
    recorded = record["findings"]
    heading("发现")
    if not recorded and not problems and not findings_pixels:
        out.append("<p class='empty'>没有发现问题（引擎与像素核对也无失败项）。</p>")
    for finding in recorded:
        kind = finding["kind"]
        out.append(f"<h3><span class='kind kind-{'product' if kind == '产品' else 'case' if kind == '用例' else 'env'}'>"
                   f"{esc(kind)}</span> {esc(finding['summary'])}</h3>")
        # FINDING_ORDER, not the alias map: two labels map onto `advice`, and
        # iterating the map prints the same value twice under both names.
        labels = {key: label for label, key in FINDING_FIELDS.items()}
        rows = [(labels[key], finding[key]) for key in FINDING_ORDER if finding.get(key)]
        if rows:
            out.append("<table class='fields'>"
                       + "".join(f"<tr><th>{esc(label)}</th><td>{esc(value)}</td></tr>"
                                 for label, value in rows)
                       + "</table>")
    for item in problems:
        out.append(f"<h3><span class='kind kind-product'>引擎</span> 步骤 {esc(item.get('id', ''))} "
                   f"断言失败</h3><p class='note'>{esc(item.get('detail', ''))}</p>")
    for item in findings_pixels:
        out.append(f"<h3><span class='kind kind-product'>像素</span> "
                   f"{esc(item.get('label', item.get('check', '')))}</h3>"
                   f"<p class='note'>{esc(item.get('file', ''))}：{esc(item.get('detail', ''))}</p>")

    # 5 逐屏核对
    section = heading("逐屏核对")
    if not case_steps:
        out.append("<p class='empty'>没有步骤记录。</p>")
    for index, step in enumerate(case_steps, start=1):
        engine = verdicts.get(step["ids"][0], {}) if step["ids"] else {}
        seen = record["steps"].get(f"r{step['key']}", {})
        state = seen.get("verdict") or ENGINE_STATES.get(engine.get("status"), "未验证")
        if state not in STATES:
            state = "未验证"

        out.append(f"<details class='step' id='s{index}' open>")
        out.append("<summary><span class='step-head'>"
                   f"<span class='num'>{section}.{index}</span>"
                   f"<span class='title'>{esc(step['title'])}</span>{badge(state)}</span></summary>")

        rows = []
        action = seen.get("action") or wording.get(str(step["key"]), "")
        if action:
            rows.append(("操作", esc(action)))
        # When the case step carries no selector there is nothing to paraphrase:
        # its own wording already sits in the step header, and printing it twice
        # is the sort of padding this contract exists to remove.
        expectation = paraphrase(step["expect"])
        if expectation:
            rows.append(("期望效果", expectation))
        if seen.get("observed"):
            rows.append(("实际现象", esc(seen["observed"])))
        else:
            rows.append(("实际现象",
                         f"<span class='empty'>未记录（引擎读数：{esc(engine.get('detail') or '—')}）</span>"))
        if seen.get("evidence"):
            rows.append(("判定依据", esc(seen["evidence"])))
        rows.append(("本步结论", badge(state)))
        out.append("<table class='fields'>"
                   + "".join(f"<tr><th>{esc(name)}</th><td>{value}</td></tr>" for name, value in rows)
                   + "</table>")

        if seen.get("note"):
            out.append(f"<div class='findings' style='background:#f6f8fa'>{esc(seen['note'])}</div>")
        anomaly = (seen.get("anomaly") or "").strip()
        if anomaly and anomaly not in ("无", "-"):
            out.append("<div class='findings' style='background:#fde8e6'>"
                       + "".join(f"<div>异常：{esc(item.strip())}</div>"
                                 for item in anomaly.split(";") if item.strip())
                       + "</div>")

        shots_here = [entry for step_id in step["ids"] for entry in shots_by_step.get(step_id, [])]
        for entry in shots_here:
            findings_here = entry.get("findings") or []
            if findings_here:
                out.append("<div class='findings' style='background:#fdf3d8'>"
                           + "".join(f"<div>{esc(item.get('label', ''))}：{esc(item.get('detail', ''))}</div>"
                                     for item in findings_here)
                           + "</div>")
            preview = preview_for(run_dir, entry) or f"annotated/{entry['file']}"
            out.append("<figure>"
                       f"<a href='shots/{esc(entry['file'])}'><img src='{preview}' "
                       f"alt='{esc(entry.get('note', ''))}'></a>"
                       f"<figcaption>{esc(entry.get('note', ''))}"
                       f"　<a href='shots/{esc(entry['file'])}'>原图</a></figcaption></figure>")
        out.append("</details>")

    # 5 未覆盖与风险
    heading("未覆盖与风险")
    boundary = declaration.get("boundary")
    out.append("<table class='fields'>"
               f"<tr><th>用例步骤</th><td>{facts['steps']} 步：通过 {facts['casePass']}、"
               f"失败 {facts['caseFail']}、未验证/可疑 {facts['caseUnverified']}</td></tr>"
               f"<tr><th>引擎断言</th><td>{facts['engineTotal']} 条：通过 {facts['enginePass']}"
               f"（{rate(facts['enginePass'], facts['engineTotal'])}）</td></tr>"
               f"<tr><th>像素核对</th><td>{facts['pixelTotal']} 项：通过 {facts['pixelPass']}"
               f"（{rate(facts['pixelPass'], facts['pixelTotal'])}）</td></tr>"
               f"<tr><th>截图覆盖</th><td>{facts['shots']} 张，覆盖 {facts['stepsWithShot']}/"
               f"{facts['steps']} 步</td></tr>"
               "</table>")
    if boundary:
        out.append(f"<p class='note'><strong>覆盖边界</strong>：{esc(boundary)}</p>")
    if facts['caseUnverified']:
        out.append("<ul>"
                   + "".join(f"<li>{esc(code)}：{esc(message)}</li>" for code, message in warnings
                             if code == "uncovered")
                   + "</ul>")
    elif not boundary:
        out.append("<p class='empty'>没有声明覆盖边界——那么「没测什么」也无从判断。</p>")
    else:
        out.append("<p class='empty'>所有步骤都有结论；屏幕外内容与系统界面按边界声明不在范围内。</p>")
    shots_warnings = [message for code, message in warnings if code == "shot-missing-for-step"]
    if shots_warnings:
        out.append("<ul>" + "".join(f"<li>{esc(message)}</li>" for message in shots_warnings) + "</ul>")

    # 6 上轮问题回归
    heading("上轮问题回归")
    regression = record["regression"]
    if regression:
        rows = [(label, regression.get(key)) for key, label in
                (("previous", "上轮问题"), ("current", "本轮结论"), ("verdict", "结论"))]
        out.append("<table class='fields'>"
                   + "".join(f"<tr><th>{esc(label)}</th><td>{esc(value or '—')}</td></tr>"
                             for label, value in rows)
                   + "</table>")
    else:
        out.append("<p class='empty'>没有上轮遗留问题记录。</p>")
    open_issues = previous
    # A bare "不适用" answers nothing when an earlier run left an open issue; an
    # actual explanation (long enough to say why) does, and that is the point —
    # the report asks for the reasoning, not for a magic word.
    answered = any(len(regression.get(key) or "") > 24
                   for key in ("previous", "current", "verdict"))
    if open_issues and not answered:
        out.append("<p class='wall' style='background:#fdf3d8;border-color:#e6c76a'>"
                   "<span class='head' style='color:#9a6700'>回归未回答</span>"
                   "同用例的历史运行里还有未解决的问题，本轮没有逐条回答。</p>")
    if open_issues:
        out.append("<h3>脚本读出的未解决问题</h3><table><tr><th>运行</th><th>当时判定</th><th>说明</th></tr>")
        for item in open_issues[:6]:
            out.append(f"<tr><td><code>{esc(item['run'])}</code></td><td>{esc(item['judgement'])}</td>"
                       f"<td>{esc(item['note'])}</td></tr>")
        out.append("</table><p class='empty'>同用例的历史运行里判定为失败／可疑／报告不完整的，"
                   "都在这里；本条用例的结论要能回答它们。</p>")

    # 附
    heading("产物")
    out.append("<p class='note'>截图 <code>shots/</code>　标注图 <code>annotated/</code>　"
               "事件流与用例翻译 <code>detail/</code>　机器可读结论 <code>summary.json</code></p>")
    out.append("<footer>"
               f"由 test/tools/report.py 生成　运行 {esc(run_id)}　"
               f"报告契约见 <code>test/REPORT-CONTRACT.md</code>"
               "</footer></body></html>")

    path = os.path.join(run_dir, "report.html")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))

    # The judgement belongs in the record, not only in the rendering.
    summary["judgement"] = verdict
    summary["judgementNote"] = note
    summary["judgementBasis"] = basis
    summary["previousIssues"] = previous
    summary["history"] = history
    summary["posture"] = posture
    summary["facts"] = facts
    summary["criteriaDeclared"] = criteria_was_declared
    summary["lint"] = {"ok": not errors, "errors": [{"code": code, "message": message}
                                                    for code, message in errors],
                       "warnings": [{"code": code, "message": message}
                                    for code, message in warnings]}
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
    return path, errors, warnings


# ------------------------------------------------------------------ scaffold

SCAFFOLD_HEADER = """# 评审：{case} {title}

用例 `{case}`（版本 {version}），运行 `{run}`，代码版本 `{commit}`。
按 `test/REPORT-CONTRACT.md` 填：**声明**必须先写（跑之前就想清楚），
每步的 `实际` 要写观察到的事实，`依据` 写凭什么这么判，不能复述期望。
"""


def scaffold(run_dir):
    """Writes a review.md skeleton: every step's id, wording and expectation.

    Pre-filling is not a convenience, it is the point: the tester starts from the
    checklist instead of from a blank page, so "forgot a step" stops being a
    class of mistake, and what remains to write is exactly the part only a person
    looking at the screenshot can supply.
    """
    summary = read_json(os.path.join(run_dir, "summary.json"), {})
    plan = read_json(os.path.join(run_dir, "detail", "plan.json"), {})
    case_steps = steps_of(plan)
    wording = read_case_wording(run_dir, summary, plan)
    path = os.path.join(run_dir, "review.md")
    if os.path.exists(path):
        return None  # never overwrite what a tester already wrote
    body = [SCAFFOLD_HEADER.format(
        case=summary.get("case", ""), title=summary.get("caseTitle", ""),
        version=summary.get("caseVersion") or "—", run=summary.get("run", ""),
        commit=summary.get("gitCommit", "?"))]
    baseline = ""
    history = sibling_runs(run_dir, summary)
    if history:
        latest = history[0]
        baseline = (f"上轮同用例 {latest['run']}（{latest['commit']}）判定「{latest['judgement']}」"
                    + (f"：{latest['note']}" if latest["note"] else "")
                    + "；本轮逐条回归")
    body.append("## 声明\n")
    body.append("构建: ")
    body.append("数据: ")
    body.append("边界: ")
    body.append(f"基线: {baseline}")
    for step in case_steps:
        expectation = plain(step["expect"]) or step.get("title", "")
        body.append(f"## r{step['key']}\n")
        action = wording.get(str(step["key"]), step.get("title", ""))
        body.append(f"操作: {action}")
        # The case's own sentence *is* the expectation when there is no selector;
        # repeating it twice would just be noise in the skeleton.
        if expectation and expectation != action:
            body.append(f"期望: {expectation}")
        body.append("实际: \n依据: \n结论: \n异常: \n")
    body.append("## 发现\n")
    body.append("（无则写：无）\n")
    body.append("## 回归\n")
    body.append("（上轮没有未解决问题则写：无）\n")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(body))
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--verdict", default="")
    parser.add_argument("--note", default="")
    parser.add_argument("--basis", default="")
    parser.add_argument("--scaffold", action="store_true",
                        help="write review.md skeleton for this run and exit")
    parser.add_argument("--allow-lint-errors", action="store_true",
                        help="render anyway (debugging); verdict becomes 报告不完整")
    args = parser.parse_args()

    if args.scaffold:
        created = scaffold(args.run_dir)
        print(json.dumps({"scaffolded": created, "existed": created is None},
                         ensure_ascii=False))
        return 0

    if args.verdict not in STATES:
        print("判定必须取四态之一：" + "、".join(STATES), file=sys.stderr)
        print("（报告不再有「待审视」默认值——没判定就是没判定）", file=sys.stderr)
        return 2

    path, errors, warnings = render(args.run_dir, args.verdict, args.note,
                                    args.basis, args.allow_lint_errors)
    # One machine-readable line: the caller (dsh.mjs, or an agent reading it)
    # needs the diagnosis, not just a filename.
    print(json.dumps({
        "report": path,
        "verdict": BLOCKED_VERDICT if errors and not args.allow_lint_errors else args.verdict,
        "lint": {"ok": not errors,
                 "errors": [{"code": code, "message": message} for code, message in errors],
                 "warnings": [{"code": code, "message": message} for code, message in warnings]},
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
