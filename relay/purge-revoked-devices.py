#!/usr/bin/env python3
"""清理中转库里"已撤销 / 已过期"的设备行。

为什么要清：中转在每次连接器连上时，会把该 agent 名下所有"永远回不来的设备"
逐条通知连接器（`hub.py:_tell_agent_about_the_gone`）。2026-10-12 那次"重连风暴"
就是库里攒了 2012 条调试/用例留下的已撤销记录，每次重连灌 2012 帧，把连接器的
处理链堵住，手机跟着断断续续（分析见 maintainers/20261012-连接器断续分析.md）。
所以这件事现在有两条腿：`hub.py` 在条数超阈值时记 WARNING（见 `Limits.dead_device_warn_threshold`），
`deploy/dsh-relay-purge.timer` 每天调本脚本 `--all-agents --apply` 真删。
为什么这个数字会涨、怎么清：`README.md` 的「Dead device records」一节。

安全约定：
  * 默认只预演（dry-run），不改库；要真删必须显式 --apply。
  * 只删 `revokedAt IS NOT NULL OR expiresAt <= now` 的行；在用的设备（未撤销且未
    过期）一行都不碰，并在输出里单独列出来核对。
  * 一条待删行都没有时**不写备份、不动库**：定时任务天天跑，不能每天复制一份库。
  * --apply 时先做一份 SQLite 备份（`.backup` API，带 WAL 内容）并把将要删除的
    行导出成 JSON，落在 --backup-dir 下，删完再核对行数。
  * 不碰 feedbackThreads / usageDaily：它们按 deviceId 关联，设备行没了只是留下孤立引用，
    账目与用户反馈必须保住。
  * noticeDeliveries 从 019（2026-10-13）起按 **accountId** 关联，与设备行无关，所以
    "清设备行会不会带走通知"不再是问题；本脚本依旧不碰它（通知属于账号的历史）。
  * 没有外键约束（schema 里没有 REFERENCES），所以删除不会级联或失败。
  * `--keep N` 只删 `--backup-dir` 里**本脚本自己写的**备份（`state-*.db` /
    `purged-devices-*.json`）里最老的几份，留下最近 N 组；默认 0 = 不清理。

用法（服务器上）：
  python3 purge-revoked-devices.py --db /var/lib/dsh-relay/state.db --agent agt_xxx
  python3 purge-revoked-devices.py --db /var/lib/dsh-relay/state.db --all-agents --apply
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time

#: 本脚本自己写出来的备份文件名（`--keep` 只认这些，绝不碰目录里别的东西）。
_BACKUP_RE = re.compile(r"^(?:state|purged-devices-.+)-(20\d{6}-\d{6})\.(?:db|json)$")

#: 待删/保留的判据。撤销是**不可逆**的产品状态，过期是配对满 TTL（365 天）；
#: `device_by_token` 两种都拒，所以两种都回不来。
_DOOMED = "revokedAt IS NOT NULL OR expiresAt <= ?"
_KEEPING = "revokedAt IS NULL AND expiresAt > ?"


def summarize(rows: list[sqlite3.Row]) -> list[str]:
    counts: dict[str, int] = {}
    for row in rows:
        name = row["name"] or "(无名)"
        counts[name] = counts.get(name, 0) + 1
    return [f"{name} × {count}" for name, count in sorted(counts.items(), key=lambda kv: -kv[1])]


def prune_backups(directory: str, keep: int) -> list[str]:
    """删掉最老的备份，留下最近 ``keep`` 组（``keep <= 0`` = 什么都不删）。

    一组 = 同一个时间戳的 `state-<stamp>.db` 与 `purged-devices-<agent>-<stamp>.json`。
    只匹配本脚本的命名，所以备份目录里放别的东西不会被误删。
    """
    if keep <= 0:
        return []
    stamps: dict[str, list[str]] = {}
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    for name in names:
        match = _BACKUP_RE.match(name)
        if match:
            stamps.setdefault(match.group(1), []).append(name)
    doomed_stamps = sorted(stamps)[:-keep] if len(stamps) > keep else []
    removed: list[str] = []
    for stamp in doomed_stamps:
        for name in sorted(stamps[stamp]):
            path = os.path.join(directory, name)
            try:
                os.remove(path)
            except OSError as error:      # 删不掉不该让清理本身失败
                print(f"！删不掉旧备份 {path}：{error}", file=sys.stderr)
                continue
            removed.append(path)
    return removed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--backup-dir", default=None,
                        help="备份与待删行导出的目录；默认是库文件旁边的 backups/")
    parser.add_argument("--apply", action="store_true", help="真的删；不给就是预演")
    parser.add_argument("--keep", type=int, default=0,
                        help="只留最近 N 组备份（0 = 不清理）")
    targets = parser.add_mutually_exclusive_group(required=True)
    targets.add_argument("--agent", help="只清这一个 agent 的设备行")
    targets.add_argument("--all-agents", action="store_true",
                         help="清库里所有 agent 的设备行（定时任务用这个）")
    args = parser.parse_args()

    now = int(time.time() * 1000)
    backup_dir = args.backup_dir or os.path.join(
        os.path.dirname(os.path.abspath(args.db)), "backups")
    conn = sqlite3.connect(args.db, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")

    if args.all_agents:
        agents = [row["agentId"] for row in conn.execute(
            "SELECT DISTINCT agentId FROM devices ORDER BY agentId")]
    else:
        agents = [args.agent]

    reports: list[dict] = []
    doomed_all: list[sqlite3.Row] = []
    for agent_id in agents:
        total = conn.execute("SELECT COUNT(*) FROM devices WHERE agentId=?",
                             (agent_id,)).fetchone()[0]
        doomed = conn.execute(
            f"SELECT * FROM devices WHERE agentId=? AND ({_DOOMED})", (agent_id, now)).fetchall()
        keep = conn.execute(
            f"SELECT * FROM devices WHERE agentId=? AND ({_KEEPING})", (agent_id, now)).fetchall()
        if len(doomed) + len(keep) != total:
            print(f"！agent {agent_id} 计算不自洽（有行既不算在用也不算待删），停手", file=sys.stderr)
            conn.close()
            return 2
        reports.append({"agentId": agent_id, "total": total, "doomed": doomed, "keep": keep})
        doomed_all.extend(doomed)

    for report in reports:
        print(f"agent {report['agentId']}：共 {report['total']} 行")
        print(f"  将删除 {len(report['doomed'])} 行（已撤销或已过期）")
        print(f"  保留 {len(report['keep'])} 行（在用）")
        for row in report["keep"]:
            print(f"    KEEP {row['deviceId']} {row['name']} "
                  f"revokedAt={row['revokedAt']} expiresAt={row['expiresAt']}")
        print("  将删除的名字分布：")
        for line in summarize(report["doomed"])[:40]:
            print(f"    {line}")

    if not args.apply:
        print("预演结束（未改库）。加 --apply 才真删。")
        return 0

    if not doomed_all:
        print("没有待删行，不动库、不写备份。")
        for path in prune_backups(backup_dir, args.keep):
            print(f"清理旧备份：{path}")
        conn.close()
        return 0

    os.makedirs(backup_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = os.path.join(backup_dir, f"state-{stamp}.db")
    scope = "all" if args.all_agents else args.agent
    dump_path = os.path.join(backup_dir, f"purged-devices-{scope}-{stamp}.json")
    dest = sqlite3.connect(backup_path)
    conn.backup(dest)
    dest.close()
    with open(dump_path, "w", encoding="utf-8") as handle:
        json.dump([dict(row) for row in doomed_all], handle, ensure_ascii=False, indent=1)
    print(f"备份：{backup_path}")
    print(f"待删行导出：{dump_path}")

    check = sqlite3.connect(backup_path)
    backup_rows = sum(check.execute("SELECT COUNT(*) FROM devices WHERE agentId=?",
                                    (report["agentId"],)).fetchone()[0]
                      for report in reports)
    check.close()
    expected = sum(report["total"] for report in reports)
    if backup_rows != expected:
        print(f"！备份行数 {backup_rows} 与源库 {expected} 不符，停手", file=sys.stderr)
        conn.close()
        return 2

    for report in reports:
        conn.execute(f"DELETE FROM devices WHERE agentId=? AND ({_DOOMED})",
                     (report["agentId"], now))
    conn.commit()

    exit_code = 0
    for report in reports:
        left = conn.execute("SELECT COUNT(*) FROM devices WHERE agentId=?",
                            (report["agentId"],)).fetchone()[0]
        stale_left = conn.execute(
            f"SELECT COUNT(*) FROM devices WHERE agentId=? AND ({_DOOMED})",
            (report["agentId"], now)).fetchone()[0]
        print(f"agent {report['agentId']} 删除完成：{report['total']} -> {left} 行，"
              f"剩余待清理 {stale_left} 行")
        if left != len(report["keep"]) or stale_left != 0:
            exit_code = 1
    conn.close()

    for path in prune_backups(backup_dir, args.keep):
        print(f"清理旧备份：{path}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
