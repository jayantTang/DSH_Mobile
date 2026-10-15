#!/usr/bin/env python3
"""把信件 4 张表从中转 state.db 迁到 mail 的库（DESIGN-20261015 M3，一次性切换用）。

    python3 mail/deploy/migrate_from_relay.py --from /var/lib/dsh-relay/state.db \
        --to /var/lib/dsh-mail/mail.db [--dry-run]

行为：

- 按列名拷贝（`PRAGMA table_info` 读目标库的列序，两边列序一致有测试钉住），
  `INSERT OR REPLACE` 幂等：切换窗口内重跑不会翻倍，只会补齐。
- `--dry-run` 只数源库行数、打印将拷什么，一个字都不写。
- 不删源库的任何行：中转那边的 4 张表原样保留，作为回滚窗口的退路
  （设计文档：回滚 = 切回 Caddy 旧片段，旧数据仍在）。
- 源库缺表（还没跑过带信件的中转）不算错误：打印 0 行继续——这让它可以
  在"全新机器装 mail"的 L3 演练里原样运行。
"""

from __future__ import annotations

import argparse
import sqlite3
import sys

TABLES = ("feedbackThreads", "feedbackMessages", "notices", "noticeDeliveries")


def table_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                       (table,)).fetchone()
    return row is not None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="migrate_from_relay.py",
                                     description="copy the four letter tables from the relay DB")
    parser.add_argument("--from", dest="source", required=True, help="relay state.db")
    parser.add_argument("--to", dest="target", required=True, help="mail mail.db")
    parser.add_argument("--dry-run", action="store_true", help="count only; write nothing")
    args = parser.parse_args(argv)

    source = sqlite3.connect(f"file:{args.source}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    target = sqlite3.connect(args.target)

    copied = 0
    for table in TABLES:
        if not table_exists(source, table):
            print(f"{table}: 源库没有这张表（按 0 行处理）")
            continue
        rows = source.execute(f"SELECT * FROM {table}").fetchall()
        print(f"{table}: {len(rows)} 行")
        if args.dry_run or not rows:
            copied += len(rows)
            continue
        columns = table_columns(target, table)
        if not columns:
            print(f"{table}: 目标库没有这张表（mail 服务先启动过一次才会建表）", file=sys.stderr)
            return 1
        marks = ",".join("?" * len(columns))
        target.executemany(
            f"INSERT OR REPLACE INTO {table}({','.join(columns)}) VALUES({marks})",
            [tuple(row[column] for column in columns) for row in rows])
        copied += len(rows)

    if args.dry_run:
        print(f"（预演）共 {copied} 行；去掉 --dry-run 才真正写入")
        return 0

    target.commit()
    target.close()
    source.close()
    print(f"完成：共拷 {copied} 行；源库未做任何改动（回滚退路保留）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
