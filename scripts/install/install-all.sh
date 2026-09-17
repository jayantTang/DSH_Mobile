#!/usr/bin/env bash
# Install everything this repository ships to the local machine.
#
# One entry point on purpose: installing the skill but forgetting the plugin —
# or the reverse — produces a half-working setup whose symptoms look like bugs.
# The connector and the skill only take effect after DSH restarts, and that step
# is called out rather than performed, because restarting takes the harness down.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

step() { printf '\n\033[1;36m>>>\033[0m %s\n' "$1"; }

step "1/3 安装 skill"
"$REPO/scripts/install/install-skills.sh"

step "2/3 注册插件"
"$REPO/scripts/install/install-plugin.sh"

step "3/3 检查"
node -e "
const { existsSync } = require('node:fs')
const { homedir } = require('node:os')
const { join } = require('node:path')
const home = process.env.DSH_HOME || join(homedir(), '.dsh')
const profile = JSON.parse(require('node:fs').readFileSync(join(home, 'profiles', 'web', 'package.json'), 'utf8'))
const bundles = profile.dsh.profile.bundles
const wanted = ['dsh-plugin-mobile-link', 'dsh-plugin-send-image']
for (const name of wanted) {
  const linked = existsSync(join(home, 'profiles', 'web', 'node_modules', name))
  const listed = bundles.includes(name)
  const ok = linked && listed
  console.log(\`  \${ok ? '✅' : '❌'} \${name}  已链接=\${linked} 已登记=\${listed}\`)
  if (!ok) process.exitCode = 1
}
const skill = join(home, 'skills', 'send-image', 'SKILL.md')
console.log(\`  \${existsSync(skill) ? '✅' : '❌'} skill send-image\`)
if (!existsSync(skill)) process.exitCode = 1
"

printf '\n\033[1;33m需要重启 DSH 才会生效\033[0m（插件与 skill 在启动时加载）。\n'
echo "重启后验证：node $REPO/scripts/dev/dsh-probe.mjs status"
