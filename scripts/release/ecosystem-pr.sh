#!/usr/bin/env bash
#
# 把 DSH Mobile 提交到生态目录 —— 三个目标，各生成一个可直接推送的分支。
#
#   scripts/release/ecosystem-pr.sh --list                 看目标和状态
#   scripts/release/ecosystem-pr.sh radar                  生成分支（不推送）
#   scripts/release/ecosystem-pr.sh all --push             生成并推送，打印开 PR 的链接
#
# 为什么要这个脚本：三个上游仓库都要求「只加一行 / 一段」，但格式各不相同，
# 而且上游每天都在动（雷达每 6 小时刷新星标）。把**改动**固化成脚本 + 断言，
# 上游漂移时会直接报错，而不是悄悄改错地方。
#
# 前置：
#   * GitHub SSH 已可用（`ssh -T git@github.com` 能认出你的账号）。脚本用 ssh 推送，
#     不需要 token。
#   * **先给 jayantTang/DSH_Mobile 加 `dsh-plugin` topic**：雷达与 Oh-My-DSH 按 topic
#     自动发现，8 小时内自动收录，这条比 PR 还快，且不需要 fork。
#
# 目标仓库：
#   radar     AdamPlatin123/dsh-plugin-radar   PLUGINS.md 的「📡 远程渠道」表追加一行
#   awesome   Dominic789654/awesome-deepseek-harness   UI / Clients 一节追加一行
#   plugins   Anil-matcha/awesome-dsh-plugin   客户端一节追加一行（结构每日可能变）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${DSH_PR_WORK:-/tmp/dsh-mobile-prs}"
REPO_URL="https://github.com/jayantTang/DSH_Mobile"

# ── 三份条目文案 ────────────────────────────────────────────────────────────
# 口径统一：先说「是什么」，再说「和已有的差别」，最后给可核对的链接。
# 不写夸张形容词——目录的读者是开发者，夸大一次就没人再点第二次。

read -r -d '' RADAR_ROW <<EOF || true
| dsh-mobile-link | [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) | 电脑侧连接器 + 原生 iOS 客户端 + 自建公网中转（DLP v1）：手机在 4G/5G 上连自己电脑的 DSH，不用公网 IP、不用 Tailscale；中转只鉴权与转发、不解析会话内容；npm \`dsh-plugin-mobile-link\` | 待测 |
EOF

read -r -d '' AWESOME_ROW <<EOF || true
- [jayantTang/DSH_Mobile]($REPO_URL) — 原生 iOS 客户端 + 电脑侧连接器 + 公网中转：手机不用公网 IP、4G/5G 就能连上电脑上的 DSH，同一批会话与同一条消息流。Native SwiftUI client, a DSH connector plugin, and a self-hosted relay (Python/aiohttp).
EOF

read -r -d '' PLUGINS_ROW <<EOF || true
- [jayantTang/DSH_Mobile]($REPO_URL) — DSH Mobile：把电脑上的 DSH 装进 iPhone。原生 SwiftUI 客户端 + 电脑侧连接器（npm \`dsh-plugin-mobile-link\`）+ 可自建的公网中转；手机在 4G/5G 上直连自己电脑的 DSH，不需要公网 IP 或 Tailscale。
EOF

PR_BODY=$(cat <<EOF
### 这个项目做什么

把电脑上的 DSH 装进手机：原生 iOS 客户端 + 电脑侧连接器（DSH 插件）+ 可自建的公网中转。

和已有移动端方案的区别在**连接方式**：不需要公网 IP，手机在 4G/5G 上直接连自己电脑的
DSH；不依赖 Tailscale 之类的组网，也不用在手机上跑一个 DSH 本体。中转只做鉴权与转发，
不解析会话内容，可以自建（\`relay/deploy/deploy.sh\` 幂等安装）。

- 仓库：$REPO_URL
- 协议：\`docs/RELAY-PROTOCOL.md\`（自研 DLP v1）、\`docs/DSH-PROTOCOL.md\`
- 测试：协议层 58 项、连接器 104 项、中转 107 项，CI 在干净仓库上跑；clone 下来即可
  \`swift test\` / \`npm test\`
EOF
)

# ── 目标 ────────────────────────────────────────────────────────────────────

declare -a TARGETS=(radar awesome plugins)

upstream_of() {
  case "$1" in
    radar)   echo "git@github.com:AdamPlatin123/dsh-plugin-radar.git" ;;
    awesome) echo "git@github.com:Dominic789654/awesome-deepseek-harness.git" ;;
    plugins) echo "git@github.com:Anil-matcha/awesome-dsh-plugin.git" ;;
  esac
}

file_of() {
  case "$1" in
    radar)   echo "PLUGINS.md" ;;
    awesome) echo "README.md" ;;
    plugins) echo "README.md" ;;
  esac
}

# 上游文件里用来定位插入点的锚点，以及插入到它的前面还是后面。
# 锚点必须**足够长**：`Remote` 这种短词会先命中目录（Contents）里的那一行，
# 结果条目被插进目录里。第一版就是这么错的，所以这里用的是完整标题。
anchor_of() {
  case "$1" in
    radar)   echo "## 📡 远程渠道|after" ;;
    awesome) echo "## UI / Clients|after" ;;
    plugins) echo "### Remote Access & Mobile|after" ;;
  esac
}

title_of() {
  case "$1" in
    radar)   echo "docs: 登记 dsh-mobile-link" ;;
    awesome) echo "Add DSH_Mobile to UI / Clients" ;;
    plugins) echo "Add DSH Mobile (iOS client + relay) to the list" ;;
  esac
}

branch_of() {
  case "$1" in
    radar)   echo "docs/register-dsh-mobile-link" ;;
    awesome) echo "add-dsh-mobile" ;;
    plugins) echo "add-dsh-mobile" ;;
  esac
}

row_of() {
  case "$1" in
    radar)   printf '%s\n' "$RADAR_ROW" ;;
    awesome) printf '%s\n' "$AWESOME_ROW" ;;
    plugins) printf '%s\n' "$PLUGINS_ROW" ;;
  esac
}

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

# ── 生成 ────────────────────────────────────────────────────────────────────

prepare() {
  local name="$1" push="${2:-0}"
  local upstream file anchor mode dir branch title
  upstream="$(upstream_of "$name")"
  file="$(file_of "$name")"
  anchor="$(anchor_of "$name")"
  branch="$(branch_of "$name")"
  title="$(title_of "$name")"
  mode="${anchor##*|}"
  anchor="${anchor%|*}"

  dir="$WORK/$name"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone --depth 1 -q "$upstream" "$dir"
  cd "$dir"
  git switch -q -c "$branch"

  if ! grep -qF "$anchor" "$file"; then
    printf 'ecosystem-pr: %s 里找不到锚点「%s」——上游结构变了，需要人工看一眼\n' "$file" "$anchor" >&2
    return 1
  fi
  if grep -qF "jayantTang/DSH_Mobile" "$file"; then
    printf 'ecosystem-pr: %s 里已经有 DSH_Mobile 了，跳过\n' "$name" >&2
    return 0
  fi

  local line row at
  line="$(grep -nF "$anchor" "$file" | head -1 | cut -d: -f1)"
  row="$(row_of "$name")"
  if [ "$mode" = "after" ]; then
    at=$((line + 1))
    # Skip the blank line between a heading and whatever follows, so the next
    # check asks about real content.
    while [ -z "$(sed -n "${at}p" "$file" | tr -d '[:space:]')" ] && [ "$at" -lt "$(wc -l < "$file")" ]; do
      at=$((at + 1))
    done
    # A table starts with its header row and then a `|---|---|` separator: an
    # entry belongs after both, otherwise the row lands above the header and
    # reads as a stray line. A section heading has neither, and there the entry
    # goes under the heading — with the blank line kept.
    if sed -n "${at}p" "$file" | grep -qE '^[[:space:]]*\|'; then
      at=$((at + 1))
      if sed -n "${at}p" "$file" | grep -qE '^[[:space:]]*\|[ :|-]+\|'; then at=$((at + 1)); fi
      { head -n "$((at - 1))" "$file"; printf '%s\n' "$row"; tail -n +"$at" "$file"; } > "$file.new"
    else
      # A section, not a table. The blank line after a heading is already part of
      # the file, so the entry goes into it rather than after another one — two
      # blank lines is not what the neighbours look like.
      local into=$line
      if [ -z "$(sed -n "$((line + 1))p" "$file" | tr -d '[:space:]')" ]; then into=$((line + 1)); fi
      { head -n "$into" "$file"; printf '%s\n' "$row"; tail -n +"$((into + 1))" "$file"; } > "$file.new"
    fi
  else
    { head -n "$line" "$file"; printf '%s\n' "$row"; tail -n +"$((line + 1))" "$file"; } > "$file.new"
  fi
  mv "$file.new" "$file"

  git add "$file"
  git -c user.name="$(git config user.name || echo jayantTang)" \
      -c user.email="$(git config user.email || echo jayantTang@users.noreply.github.com)" \
      commit -q -m "$title" -m "$PR_BODY"

  local count
  count="$(git diff --stat HEAD~1 | tail -1)"
  printf '\n=== %s ===\n' "$name"
  printf '  仓库：%s\n' "$upstream"
  printf '  分支：%s\n' "$branch"
  printf '  改动：%s\n' "$count"
  printf '  差异：\n'
  git diff HEAD~1 | sed 's/^/    /'

  if [ "$push" = "1" ]; then
    # 推到**自己的 fork**：没有 token 就建不了 fork，所以先检查它在不在。
    local fork="git@github.com:jayantTang/$(basename "${upstream%.git}").git"
    if git ls-remote "$fork" >/dev/null 2>&1; then
      git push -q "$fork" "HEAD:refs/heads/$branch"
      printf '  已推送：%s（分支 %s）\n' "$fork" "$branch"
    else
      printf '  ⚠️  fork 不存在，无法推送。先打开 %s 点 Fork，再跑一次 --push\n' \
        "${upstream/git@github.com:/https://github.com/}"
    fi
    printf '  开 PR：%s/compare/main...jayantTang:%s?expand=1\n' \
      "${upstream/git@github.com:/https://github.com/}" "$branch"
  fi
}

list_targets() {
  printf '目标仓库（改动 = 一行/一段，脚本会先断言锚点存在）：\n\n'
  for name in "${TARGETS[@]}"; do
    printf '  %-8s %s\n          文件 %s，锚点「%s」\n          PR 标题：%s\n\n' \
      "$name" "$(upstream_of "$name" | sed 's|git@github.com:|https://github.com/|')" \
      "$(file_of "$name")" "$(anchor_of "$name")" "$(title_of "$name")"
  done
  printf '本机工作目录：%s\n' "$WORK"
}

main() {
  local push=0
  local -a wanted=()
  for arg in "$@"; do
    case "$arg" in
      --push) push=1 ;;
      --list|-h|--help) usage; echo; list_targets; exit 0 ;;
      all) wanted=("${TARGETS[@]}") ;;
      radar|awesome|plugins) wanted+=("$arg") ;;
      *) printf 'ecosystem-pr: 不认识的参数 %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
  done
  [ "${#wanted[@]}" -gt 0 ] || { usage; exit 2; }
  for name in "${wanted[@]}"; do prepare "$name" "$push"; done
}

main "$@"
