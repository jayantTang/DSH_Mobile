#!/usr/bin/env bash
# 推送后确认 CI 通过。
#
# 为什么要它：本地门禁（pre-push）只覆盖能在这台 Mac 上跑的用例；CI 还跑 Linux 上的
# 中转、邮件服务与干净环境的 App 构建，红灯只有推上去才看得到。推完就切下一个任务，
# 等于把红灯留给下一次提交——所以把「确认 CI 通过」做成一条命令。
#
#   ./scripts/dev/check-ci.sh                  # 等当前 HEAD 的 CI，最多 30 分钟
#   ./scripts/dev/check-ci.sh --timeout 600    # 改等待上限（秒）
#   ./scripts/dev/check-ci.sh --commit <sha>   # 查指定提交
#
# 退出码：0 通过；1 失败或有作业被取消；2 超时/无法判断（没推上去、gh 未登录等）。
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

COMMIT="$(git rev-parse HEAD)"
TIMEOUT=1800
INTERVAL=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# gh 的 `--commit` 只认完整 SHA；短 SHA 会静默返回空列表。
COMMIT="$(git rev-parse --verify --quiet "$COMMIT")" || { echo "[check-ci] 认不出提交：$COMMIT" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "[check-ci] 找不到 gh（GitHub CLI）" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "[check-ci] gh 未登录" >&2; exit 2; }

echo "[check-ci] 等 $COMMIT 的 CI（最多 ${TIMEOUT}s）"
started=$(date +%s)

while :; do
  line="$(gh run list --workflow ci.yml --commit "$COMMIT" --limit 1 \
            --json databaseId,status,conclusion,url \
            --jq '.[0] | [(.databaseId // ""), (.status // ""), (.conclusion // ""), (.url // "")] | join(" ")' \
            2>/dev/null)"

  if [ -n "$line" ]; then
    # shellcheck disable=SC2086
    set -- $line
    id="${1:-}"; status="${2:-}"; conclusion="${3:-}"; url="${4:-}"

    if [ "$status" = "completed" ]; then
      if [ "$conclusion" = "success" ]; then
        echo "[check-ci] 通过：$url"
        exit 0
      fi
      echo "[check-ci] 未通过（${conclusion:-unknown}）：$url" >&2
      if [ -n "$id" ]; then
        gh run view "$id" --json jobs \
          --jq '.jobs[] | select(.conclusion != "success") | "  ✗ \(.name) — \(.conclusion // "running")"' >&2
      fi
      exit 1
    fi
    echo "[check-ci] 进行中（${status}）"
  else
    echo "[check-ci] 还没有登记这次提交的运行（可能刚落库，或没触发）"
  fi

  now=$(date +%s)
  if [ $((now - started)) -ge "$TIMEOUT" ]; then
    echo "[check-ci] 超时：${TIMEOUT}s 内没有结论" >&2
    exit 2
  fi
  sleep "$INTERVAL"
done
