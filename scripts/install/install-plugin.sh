#!/usr/bin/env bash
# Register a DSH plugin with the local harness profile.
#
# Editing the profile by hand is what this replaces: the bundle list and the
# link dependency have to agree, and a plugin that is linked but not listed in
# `dsh.profile.bundles` fails silently — it installs and then never loads.
#
# A plugin that is listed but declares no `dsh.bundle.patch` is worse than
# silent: every boot fails with "declares no dsh.bundle in its package.json",
# which takes the harness down with it, so the desktop app cannot start either.
# Both halves are checked below before anything is written to the profile.
#
# Usage: scripts/install/install-plugin.sh [plugin-dir ...]
#        (default: every plugin under plugins/)
#
# A restart of DSH is required afterwards; this script will not do it, because
# restarting takes the harness down.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/web}"

step() { printf '\033[1;36m>>>\033[0m %s\n' "$1"; }

if [ ! -f "$PROFILE/package.json" ]; then
  echo "找不到 profile: $PROFILE/package.json" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  PLUGINS=("$@")
else
  PLUGINS=()
  for dir in "$REPO"/plugins/*/; do
    [ -f "$dir/package.json" ] && PLUGINS+=("$dir")
  done
fi

for dir in "${PLUGINS[@]}"; do
  dir="${dir%/}"
  manifest="$dir/package.json"
  if [ ! -f "$manifest" ]; then
    echo "跳过（没有 package.json）: $dir" >&2
    continue
  fi
  name="$(node -p "require('$manifest').name")"

  # Refuse before touching the profile: a bundle-less entry bricks every boot.
  node - "$manifest" "$dir" "$name" <<'NODE'
const [manifestPath, dir, name] = process.argv.slice(2)
const fs = require('node:fs')
const path = require('node:path')
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const patch = manifest.dsh?.bundle?.patch
if (typeof patch !== 'string' || patch.length === 0) {
  console.error(`\u001b[1;31m✗\u001b[0m ${name} 的 package.json 没有 dsh.bundle.patch —— 登记进 dsh.profile.bundles 会让每次启动都失败。`)
  console.error(`  先补上 cordis.patch.yml（参考 plugins/send-image/cordis.patch.yml），再写：`)
  console.error(`  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }`)
  process.exit(1)
}
if (!fs.existsSync(path.resolve(dir, patch))) {
  console.error(`\u001b[1;31m✗\u001b[0m ${name} 的 dsh.bundle.patch 指向的 ${patch} 不存在。`)
  process.exit(1)
}
NODE

  step "注册插件: $name"

  node - "$PROFILE/package.json" "$name" "$dir" <<'NODE'
const [profilePath, name, dir] = process.argv.slice(2)
const fs = require('node:fs')
const profile = JSON.parse(fs.readFileSync(profilePath, 'utf8'))

profile.dependencies ??= {}
profile.dependencies[name] = `link:${dir}`

profile.dsh ??= {}
profile.dsh.profile ??= {}
profile.dsh.profile.bundles ??= []
// Both halves are required: linked-but-unlisted installs and never loads.
if (!profile.dsh.profile.bundles.includes(name)) profile.dsh.profile.bundles.push(name)

fs.writeFileSync(profilePath, JSON.stringify(profile, null, 2) + '\n')
console.log(`  依赖: ${name} -> link:${dir}`)
console.log(`  bundles: ${profile.dsh.profile.bundles.join(', ')}`)
NODE
done

step "链接依赖"
if command -v pnpm >/dev/null 2>&1; then
  (cd "$PROFILE" && pnpm install --silent)
else
  (cd "$PROFILE" && npm install --silent)
fi

step "完成"
echo "重启 DSH 后生效（插件在启动时加载）。"
