"""告警投递：队列取走、正文成型、失败放回（不丢一条）。

投递走信箱服务的 `admin.py feedback-notify`，只投给 owner 本人（同日报口径，不需要
审批）。这里用假 admin 脚本验证命令行与"取走/放回"的语义，不碰真实信箱。
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

import pytest

RELAY_DIR = pathlib.Path(__file__).resolve().parents[1]


def _load_dispatch():
    spec = importlib.util.spec_from_file_location("alert_dispatch",
                                                 RELAY_DIR / "alert-dispatch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dispatch = _load_dispatch()


def _write_queue(alert_dir: pathlib.Path, records: list[dict]) -> pathlib.Path:
    alert_dir.mkdir(parents=True, exist_ok=True)
    path = alert_dir / "alerts.jsonl"
    with path.open("a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    return path


def _record(key: str = "exc:ValueError@hub.py:1042", **overrides) -> dict:
    record = {
        "ts": 1_700_000_000,
        "key": key,
        "kind": "exception",
        "title": "中转异常：UnicodeEncodeError @ hub.py:1042",
        "summary": "/link/agent → UnicodeEncodeError: surrogates not allowed",
        "details": {"source": "http", "path": "/link/agent",
                    "place": "hub.py:1042", "frames": "link_agent ← route_from_agent"},
        "count": 143,
        "suppressedSinceLastAlert": 0,
        "newCategory": True,
    }
    record.update(overrides)
    return record


def _fake_admin(tmp_path: pathlib.Path, exit_code: int = 0) -> tuple[pathlib.Path, pathlib.Path]:
    """一个假 admin.py：把 argv 与正文落盘，然后按指定退出码结束。"""
    script = tmp_path / "fake_admin.py"
    log = tmp_path / "admin-calls.json"
    script.write_text(
        "import json, sys\n"
        f"args = sys.argv[1:]\n"
        "body = ''\n"
        "if '--body-file' in args:\n"
        "    body = open(args[args.index('--body-file') + 1], encoding='utf-8').read()\n"
        f"log = {str(log)!r}\n"
        "try:\n"
        "    calls = json.load(open(log, encoding='utf-8'))\n"
        "except Exception:\n"
        "    calls = []\n"
        "calls.append({'args': args, 'body': body})\n"
        "json.dump(calls, open(log, 'w', encoding='utf-8'), ensure_ascii=False)\n"
        f"print('{{\"ok\": true}}')\n"
        f"raise SystemExit({exit_code})\n",
        encoding="utf-8",
    )
    return script, log


def _run(tmp_path, *, account="acc_owner", fake_admin=None, extra=()) -> int:
    script = fake_admin or _fake_admin(tmp_path)[0]
    argv = ["--alert-dir", str(tmp_path / "alerts"),
            "--account", account,
            "--mail-db", str(tmp_path / "mail.db"),
            "--mail-admin", str(script),
            "--mail-python", sys.executable, *extra]
    return dispatch.main(list(argv))


def test_build_body_marks_new_categories_and_keeps_the_numbers(): 
    body = dispatch.build_body([_record(), _record(key="flap:agt_1", kind="flap",
                                                   title="连接器反复断开",
                                                   summary="Windows-PC 在 300 秒内断开 5 次",
                                                   details={"agentId": "agt_1"},
                                                   newCategory=False)])
    assert "中转异常" in body and "连接器反复断开" in body
    assert "[新类别]" in body and "[再次出现]" in body
    assert "累计 143 次" in body
    assert "hub.py:1042" in body


def test_dry_run_prints_the_body_and_keeps_the_queue(tmp_path, capsys):
    queue = _write_queue(tmp_path / "alerts", [_record()])
    status = _run(tmp_path, extra=("--dry-run",))
    assert status == 0
    assert "中转异常" in capsys.readouterr().out
    assert queue.exists(), "预演不许动队列"


def test_a_successful_delivery_clears_the_queue(tmp_path):
    _write_queue(tmp_path / "alerts", [_record()])
    script, log = _fake_admin(tmp_path)
    status = _run(tmp_path, fake_admin=script)

    assert status == 0
    calls = json.loads(log.read_text(encoding="utf-8"))
    assert len(calls) == 1
    args = calls[0]["args"]
    assert "feedback-notify" in args
    assert args[args.index("--account") + 1] == "acc_owner"
    assert "--yes" in args, "投递必须是真写，不是预演"
    assert "中转异常" in calls[0]["body"]
    assert not (tmp_path / "alerts" / "alerts.jsonl").exists(), "投递成功后队列清空"
    assert not (tmp_path / "alerts" / "alerts.taken.jsonl").exists()


def test_a_failed_delivery_puts_every_record_back(tmp_path):
    queue = _write_queue(tmp_path / "alerts", [_record(), _record(key="flap:agt_1", kind="flap")])
    before = queue.read_text(encoding="utf-8")
    script, _log = _fake_admin(tmp_path, exit_code=1)

    status = _run(tmp_path, fake_admin=script)

    assert status == 3
    assert queue.read_text(encoding="utf-8") == before, "投递失败必须一条不少地放回队列"
    assert not (tmp_path / "alerts" / "alerts.taken.jsonl").exists()


def test_without_a_recipient_nothing_is_sent(tmp_path):
    _write_queue(tmp_path / "alerts", [_record()])
    status = _run(tmp_path, account="")
    assert status == 2
    assert (tmp_path / "alerts" / "alerts.jsonl").exists()


def test_a_missing_queue_is_not_an_error(tmp_path):
    (tmp_path / "alerts").mkdir()
    assert _run(tmp_path) == 0


def test_malformed_queue_lines_are_skipped(tmp_path, capsys):
    queue = _write_queue(tmp_path / "alerts", [_record()])
    with queue.open("a", encoding="utf-8") as handle:
        handle.write("{not json\n")
    script, log = _fake_admin(tmp_path)

    assert _run(tmp_path, fake_admin=script) == 0
    assert "malformed" in capsys.readouterr().err
    calls = json.loads(log.read_text(encoding="utf-8"))
    assert "中转异常" in calls[0]["body"]
