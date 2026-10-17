#!/usr/bin/env python3
"""把中转写下的告警队列投进我们的信箱（systemd timer 跑，默认每 2 分钟一次）。

为什么投递独立成一个进程（而不是在 relay 里发）：

    中转是转发进程，它的责任只有"转发"，不该持有发信凭据、也不该因为发信慢/失败而
    影响转发（`dsh-relay.service` 还是 ProtectSystem=strict 的沙箱）。所以两边只用
    一个文件交接：relay 追加 ``alerts.jsonl``，本脚本取走、投递、删除。

行为：

1. **先取后投**：把队列 ``rename`` 成 ``alerts.taken.jsonl``（原子），再开始拼正文。
   投递失败就把它追加回队列，下次重试；投递成功才删除。任何一步都不会丢告警。
2. **只投给我们自己**：收件账号取 ``--account`` 或 ``DLP_ALERT_ACCOUNT``，两者都没有
   就报错退出——不猜、不群发。只发给 owner 本人不需要审批（同日报口径）。
3. ``--dry-run`` 只打印正文，不动队列。

用法：

    alert-dispatch.py --alert-dir /var/lib/dsh-relay/alerts \
        --mail-db /var/lib/dsh-mail/mail.db \
        --mail-admin /opt/dsh-mail/admin.py \
        --mail-python /opt/dsh-mail/.venv/bin/python

退出码：0 = 没告警或投递成功；2 = 用法/配置错误；3 = 投递失败（队列已放回）。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Any

QUEUE_NAME = "alerts.jsonl"
TAKEN_NAME = "alerts.taken.jsonl"

#: 一封告警最多带多少条明细；再多就只报总数（队列里其余的留给下一轮或丢弃）。
MAX_RECORDS = 40

#: 正文上限（字符）。信箱通知是给人看的，不是日志备份。
MAX_BODY_CHARS = 12_000

KIND_LABELS = {
    "exception": "未处理异常",
    "flap": "连接反复断开",
    "corrupt-frame": "上游坏字符",
}


def _read_queue(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    bad = 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if isinstance(value, dict):
                records.append(value)
            else:
                bad += 1
    if bad:
        print(f"alert-dispatch: skipped {bad} malformed queue line(s)", file=sys.stderr)
    return records


def _format_details(details: Any) -> str:
    if not isinstance(details, dict):
        return ""
    parts = []
    for key, value in details.items():
        if key == "context":
            # 上下文是唯一可能与用户内容有关的一小段（24 字符窗口），单独换行放在最后。
            continue
        parts.append(f"{key}={value}")
    text = "，".join(parts)
    context = details.get("context")
    if isinstance(context, str) and context:
        text = f"{text}\n     片段：{context}"
    return text


def build_body(records: list[dict[str, Any]], *, now: float | None = None) -> str:
    """把队列记录拼成一封信的 Markdown 正文。"""
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(now if now is not None else time.time()))
    lines = [f"中转在 {stamp} 前后报出 {len(records)} 类事件（同类只留最近一条）。", ""]
    for index, record in enumerate(records, start=1):
        kind = str(record.get("kind") or "unknown")
        label = KIND_LABELS.get(kind, kind)
        title = str(record.get("title") or record.get("key") or "").strip()
        summary = str(record.get("summary") or "").strip()
        count = record.get("count")
        new_category = record.get("newCategory")
        badge = "新类别" if new_category else "再次出现"
        lines.append(f"{index}. [{badge}] {label}：{title}")
        if summary:
            lines.append(f"   {summary}")
        if count:
            lines.append(f"   累计 {count} 次")
        details = _format_details(record.get("details"))
        if details:
            lines.append(f"   {details}")
        lines.append("")
    body = "\n".join(lines).strip() + "\n"
    if len(body) > MAX_BODY_CHARS:
        body = body[:MAX_BODY_CHARS] + "\n…（正文已截断，完整记录在服务器 "
        body += "/var/lib/dsh-relay/alerts/alerts.taken.jsonl）\n"
    return body


def deliver(*, subject: str, body: str, account: str, mail_db: str, mail_admin: str,
            mail_python: str, format_name: str = "text") -> int:
    """调信箱服务的 admin.py 投一条通知。返回退出码。"""
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False)
    try:
        handle.write(body)
        handle.close()
        command = [mail_python, mail_admin, "--db", mail_db, "feedback-notify",
                   "--account", account, "--subject", subject,
                   "--body-file", handle.name, "--format", format_name, "--yes"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return 0 if result.returncode == 0 else 3
    except (OSError, subprocess.SubprocessError) as error:
        print(f"alert-dispatch: could not run the mail admin: {error}", file=sys.stderr)
        return 3
    finally:
        try:
            os.unlink(handle.name)
        except OSError:
            pass


def _restore(queue_path: str, taken_path: str) -> None:
    """投递失败：把取走的记录追加回队列，一条都不丢。"""
    try:
        with open(taken_path, encoding="utf-8", errors="replace") as source:
            payload = source.read()
        with open(queue_path, "a", encoding="utf-8") as target:
            target.write(payload)
    finally:
        try:
            os.unlink(taken_path)
        except OSError:
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="alert-dispatch.py",
                                     description="投递中转的异常告警到我们的信箱")
    parser.add_argument("--alert-dir", default=os.environ.get("DLP_ALERT_DIR", ""),
                        help="relay 写告警的目录（与 relay 的 DLP_ALERT_DIR 同一个）")
    parser.add_argument("--account", action="append", default=[],
                        help="收件账号；不给则用 DLP_ALERT_ACCOUNT。只投给 owner 本人")
    parser.add_argument("--mail-db", default=os.environ.get("DLP_ALERT_MAIL_DB", ""))
    parser.add_argument("--mail-admin", default=os.environ.get("DLP_ALERT_MAIL_ADMIN", ""))
    parser.add_argument("--mail-python", default=os.environ.get("DLP_ALERT_MAIL_PYTHON", ""))
    parser.add_argument("--format", dest="format_name", default="text", choices=("text", "html"))
    parser.add_argument("--dry-run", action="store_true", help="只打印正文，不动队列、不发信")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    alert_dir = str(args.alert_dir or "").strip()
    if not alert_dir:
        print("alert-dispatch: --alert-dir (or DLP_ALERT_DIR) is required", file=sys.stderr)
        return 2
    queue_path = os.path.join(alert_dir, QUEUE_NAME)
    taken_path = os.path.join(alert_dir, TAKEN_NAME)

    if args.dry_run:
        if not os.path.exists(queue_path):
            print("alert-dispatch: queue is empty")
            return 0
        records = _read_queue(queue_path)[:MAX_RECORDS]
        if not records:
            print("alert-dispatch: queue is empty")
            return 0
        print(build_body(records))
        return 0

    accounts = [str(item).strip() for item in args.account if str(item).strip()]
    if not accounts:
        accounts = [item.strip() for item in os.environ.get("DLP_ALERT_ACCOUNT", "").split(",")
                    if item.strip()]
    if not accounts:
        print("alert-dispatch: no recipient account (--account or DLP_ALERT_ACCOUNT)",
              file=sys.stderr)
        return 2
    for label, value in (("--mail-db", args.mail_db), ("--mail-admin", args.mail_admin),
                         ("--mail-python", args.mail_python)):
        if not str(value or "").strip():
            print(f"alert-dispatch: {label} is required", file=sys.stderr)
            return 2

    try:
        os.rename(queue_path, taken_path)
    except FileNotFoundError:
        return 0
    except OSError as error:
        print(f"alert-dispatch: could not take the queue: {error}", file=sys.stderr)
        return 3

    try:
        records = _read_queue(taken_path)
        if not records:
            os.unlink(taken_path)
            return 0
        batch = records[:MAX_RECORDS]
        subject = time.strftime("中转告警 %Y-%m-%d %H:%M", time.localtime())
        if len(records) > len(batch):
            subject += f"（另有 {len(records) - len(batch)} 条未展开）"
        body = build_body(batch)
        status = 0
        for account in accounts:
            status = deliver(subject=subject, body=body, account=account,
                             mail_db=args.mail_db, mail_admin=args.mail_admin,
                             mail_python=args.mail_python, format_name=args.format_name)
            if status != 0:
                break
        if status == 0:
            os.unlink(taken_path)
        else:
            _restore(queue_path, taken_path)
        return status
    except Exception as error:  # noqa: BLE001 - 任何异常都要把队列放回去
        print(f"alert-dispatch: failed: {error}", file=sys.stderr)
        if os.path.exists(taken_path):
            _restore(queue_path, taken_path)
        return 3


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
