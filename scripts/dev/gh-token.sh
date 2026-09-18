#!/usr/bin/env bash
#
# 取 GitHub token —— 从 macOS 钥匙串读，不落盘、不进仓库、不写进 shell 历史。
#
#   scripts/dev/gh-token.sh            # 打印 token（给命令替换用）
#   scripts/dev/gh-token.sh --check    # 只确认能不能读到，不打印
#
# 为什么要有这个脚本：token 是凭据，最忌讳的是"为了方便"复制到 .env、配置文件或
# 某段脚本里——那些地方会被同步、被备份、被顺手 commit。钥匙串是这台机器上原本就
# 用来放这类东西的地方，`security` 是系统自带的读取方式。
#
# 存法（只需做一次）：
#   security add-generic-password -a "$USER" -s dsh-github-token -w '<token>' -U
#
# 用法示例：
#   TOKEN=$(scripts/dev/gh-token.sh)
#   curl -s -H "Authorization: Bearer $TOKEN" https://api.github.com/user
#
# 注意：`--check` 只验证存在性；任何调用都会把 token 交给当前进程，所以别把它
# 打到日志里（不要 `echo $TOKEN`，也不要 `set -x`）。
set -euo pipefail

SERVICE="${GH_TOKEN_SERVICE:-dsh-github-token}"

# 条目名（-a）可能是 macOS 用户也可能是 GitHub 用户名，两者大小写还不一样，
# 所以按服务名找、不按账号找：一个服务名下只会有我们这一条。
token="$(security find-generic-password -s "$SERVICE" -w 2>/dev/null || true)"

if [ -z "$token" ]; then
  printf 'gh-token: 钥匙串里没有 %s。存一个：\n' "$SERVICE" >&2
  printf "  security add-generic-password -a \"\$USER\" -s %s -w '<token>' -U\n" "$SERVICE" >&2
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  printf 'gh-token: 钥匙串里有 %s（长度 %d），可用\n' "$SERVICE" "${#token}"
  exit 0
fi

printf '%s' "$token"
