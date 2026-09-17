#!/usr/bin/env bash
# Install this repo's DSH skills into the local harness.
#
# Skills live in $DSH_HOME/skills/<name>/ and are picked up by the harness on
# its next start, so re-running this is the whole deployment step.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_HOME="${DSH_HOME:-$HOME/.dsh}/skills"

step() { printf '\033[1;36m>>>\033[0m %s\n' "$1"; }

mkdir -p "$SKILLS_HOME"
for source in "$REPO"/skills/*/; do
  name="$(basename "$source")"
  step "安装 skill: $name"
  rm -rf "$SKILLS_HOME/$name"
  mkdir -p "$SKILLS_HOME/$name"
  # -p preserves the layout; the copy is explicit so nothing stray ships.
  cp -p "$source"SKILL.md "$SKILLS_HOME/$name/" 2>/dev/null || true
  if [ -d "$source/scripts" ]; then cp -Rp "$source"scripts "$SKILLS_HOME/$name/"; fi
  # Standalone .mjs entry points sit at the skill root.
  for file in "$source"*.mjs; do
    [ -e "$file" ] || continue
    # Test files are not entry points; keep them out of the installed skill.
    case "$(basename "$file")" in *.test.mjs) continue ;; esac
    cp -p "$file" "$SKILLS_HOME/$name/"
    chmod +x "$SKILLS_HOME/$name/$(basename "$file")"
  done
  ls "$SKILLS_HOME/$name"
done

step "完成"
echo "已安装到 $SKILLS_HOME"
echo "重启 DSH 后生效（技能目录在启动时读取）。"
