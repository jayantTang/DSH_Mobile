#!/usr/bin/env python3
"""从 DSH 的 workspace 存储里把会话移出「已归档」。

背景：这个 DSH 版本的 `workspace/archiveSession` 是单向的——注册表只有 archiveSession
一个方法，`archived:false` 会被接受但忽略，客户端也没有取消归档的入口。误归档只能改
存储文件，并让 host 重新读取。

host 在运行时以内存状态为准，并且会随时把内存写回文件，所以顺序必须是：
**先退出 DSH → 改文件 → 再启动 DSH**。

用法：
    python3 scripts/dev/restore-archived.py --list
    python3 scripts/dev/restore-archived.py --remove <sessionId> [<sessionId> ...]
"""

import datetime
import json
import os
import shutil
import sys

STORE = os.path.expanduser("~/.dsh/storages/workspace.json")


def load():
    return json.load(open(STORE))


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    state = load()
    archived = state["global"]["archivedSessionIds"]

    if args[0] == "--list":
        print(f"归档集合 {len(archived)} 条：")
        for sid in archived:
            print("  ", sid)
        return 0

    if args[0] == "--remove":
        targets = [a for a in args[1:] if a]
        if not targets:
            print("要给出至少一个 sessionId", file=sys.stderr)
            return 2
        keep = [sid for sid in archived if sid not in targets]
        removed = len(archived) - len(keep)
        if removed == 0:
            print("这些 id 本来就不在归档集合里，没改动。")
            return 0
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(STORE, f"{STORE}.bak-{stamp}")
        state["global"]["archivedSessionIds"] = keep
        json.dump(state, open(STORE, "w"), ensure_ascii=False, indent=2)
        print(f"移出 {removed} 条；备份 {STORE}.bak-{stamp}")
        print("启动 DSH 后生效。")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
