#!/usr/bin/env bash
# 把本仓库 skills/ 下的项目级技能链接进 .dsh/skills（该目录不入库）。
# 只链接本地还没有的技能：send-image、dsh-restart 这类已装到 ~/.dsh/skills 的不重复挂。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLOBAL_SKILLS="${DSH_HOME:-$HOME/.dsh}/skills"
PROJECT_SKILLS="$REPO/.dsh/skills"

mkdir -p "$PROJECT_SKILLS"

for source in "$REPO"/skills/*/; do
  name="$(basename "$source")"
  if [ -e "$GLOBAL_SKILLS/$name" ] && [ ! -L "$GLOBAL_SKILLS/$name" ]; then
    echo "跳过 ${name}：已安装在 $GLOBAL_SKILLS"
    continue
  fi
  ln -sfn "../../skills/$name" "$PROJECT_SKILLS/$name"
  echo "链接 $name -> $PROJECT_SKILLS/$name"
done

echo "完成。技能目录（${PROJECT_SKILLS}）由 DSH 监视，保存后自动生效。"
