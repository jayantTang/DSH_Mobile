#!/usr/bin/env bash
#
# 把三个插件包发到 npm —— 一次跑完，失败即停。
#
#   scripts/release/publish-plugins.sh                 # 只自检 + 干跑，不发布
#   scripts/release/publish-plugins.sh --publish       # 真的发布（需要先 npm login）
#   scripts/release/publish-plugins.sh --publish --otp 123456   # 账号开了两步验证时
#   scripts/release/publish-plugins.sh --publish --only mobile-link
#
# 为什么要有这个脚本：
#   * 三个包的元数据必须一致（repository / homepage / bugs / keywords / files），
#     手工改容易漏一个，而 npm 上的元数据发出去就改不回来了（只能发新版本）。
#   * `dsh plugin add` 装的就是 npm 上的东西，包内容错了等于安装路径坏了——
#     所以发布前先 `npm pack` 干跑，把**将被打包的文件**逐个打出来。
#
# 前置：`npm login`（registry 指向 npmmirror 时，发布仍需登录 npmjs，见脚本尾部说明）。
#
# 踩过的坑，两次都花在同一个地方，写在这里省下一次：
#   1. `npm login --registry=…npmjs.org` 的 token 是**按 registry 存**的，所以每条命令
#      （whoami / view / publish）都必须显式带 --registry，否则会去问 npmmirror 那个只读镜像，
#      报「未登录」。脚本里已经统一成 ${NPM_REGISTRY}。
#   2. **不要用 `NPM_CONFIG__AUTH` 环境变量传 token**：它看起来生效（whoami 通过），但发布时
#      会被忽略，registry 回 401 `OTP required for authentication`，而 token 明明是带
#      bypass_2fa 的（可在 https://registry.npmjs.org/-/npm/v1/tokens 用 `bypass_2fa: true` 核实）。
#      可靠做法是把它写进 ~/.npmrc 的 `//registry.npmjs.org/:_authToken=…`。
#   3. 账号没开 2FA 时，npm 不给生成带 bypass 的 token（创建页上那个勾选框不出现），
#      所以先开 2FA —— 现在只提供 security key（Mac 的 Touch ID / 通行密钥即可），
#      没有 authenticator app 选项，于是也没有 6 位码可用，--otp 那条路走不通。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGES=(mobile-link send-image doubao-image)
#: 发布目标。本机 registry 指向 npmmirror（只读镜像），而 `npm login` 的 token 是按 registry
#: 存的，所以每条命令都要显式带上官方源，否则会命中镜像并报「未登录」。
NPM_REGISTRY="https://registry.npmjs.org"
PUBLISH=0
ONLY=""
OTP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    # 账号开了两步验证时，npm 要求每次发布带一次性验证码。三个包要在同一个 30 秒窗口里
    # 发完（本脚本按顺序发，通常够），所以码从命令行传进来，命令里不留痕。
    --otp) OTP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'publish-plugins: 不认识的参数 %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }
die() { printf 'publish-plugins: %s\n' "$*" >&2; exit 1; }

# ── 1. 每个包：元数据齐全 + 测试通过 + 打包内容正确 ─────────────────────────

for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  dir="$ROOT/plugins/$name"
  say "$name"

  node - "$dir/package.json" <<'NODE'
const [path] = process.argv.slice(2)
const data = require(path)
const need = ['name', 'version', 'description', 'keywords', 'license', 'author',
              'repository', 'homepage', 'bugs', 'files']
const missing = need.filter((key) => !data[key] || (Array.isArray(data[key]) && !data[key].length))
if (missing.length) {
  console.error(`  缺字段: ${missing.join(', ')}`)
  process.exit(1)
}
if (data.private === true) {
  console.error('  private: true —— npm 会拒绝发布')
  process.exit(1)
}
// `dsh plugin add` 的加载路径依赖这两个声明，缺一个装上去也不生效。
if (!data.dsh?.bundle?.patch) {
  console.error('  缺 dsh.bundle.patch —— 装上去不会成为 profile 的一层')
  process.exit(1)
}
if (!data.files.includes('cordis.patch.yml')) {
  console.error('  files 里没有 cordis.patch.yml —— 打出来的包里缺这个文件')
  process.exit(1)
}
console.log(`  ${data.name}@${data.version}  metadata ok`)
NODE

  ( cd "$dir" && npm test >/dev/null 2>&1 ) && printf '  tests ok\n' || die "$name 的测试没过"

  # What actually goes into the tarball, printed rather than assumed.
  ( cd "$dir" && npm pack --dry-run --json 2>/dev/null ) | node -e '
let raw = ""
process.stdin.on("data", (chunk) => { raw += chunk })
process.stdin.on("end", () => {
  const [info] = JSON.parse(raw)
  console.log(`  ${info.filename}  ${info.files.length} files  ${(info.size / 1024).toFixed(1)} KB`)
  for (const file of info.files) console.log(`    ${file.path}`)
  const wanted = ["package.json", "cordis.patch.yml", "README.md", "lib"]
  for (const item of wanted) {
    if (!info.files.some((file) => file.path === item || file.path.startsWith(`${item}/`))) {
      console.error(`  包里缺 ${item}`)
      process.exit(1)
    }
  }
})'
done

# ── 2. 名字有没有被占（发了才发现重名就白跑了） ─────────────────────────────

say "检查 npm 上的名字"
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  pkg="$(node -p "require('$ROOT/plugins/$name/package.json').name")"
  version="$(node -p "require('$ROOT/plugins/$name/package.json').version")"
  published="$(npm view "$pkg" version --registry="$NPM_REGISTRY" 2>/dev/null || true)"
  if [ -z "$published" ]; then
    printf '  %s：尚未发布，可以发 %s\n' "$pkg" "$version"
  elif [ "$published" = "$version" ]; then
    die "$pkg@$version 已经发过了 —— 先升 version 再发（npm 不允许覆盖已发布的版本）"
  else
    printf '  %s：线上是 %s，本次将发 %s\n' "$pkg" "$published" "$version"
  fi
done

if [ "$PUBLISH" != "1" ]; then
  say "干跑结束（没有发布）。要真的发：scripts/release/publish-plugins.sh --publish"
  cat <<'NOTE'

发布前确认：
  * npm login 用的是 npmjs 官方源。本机 registry 指向 npmmirror（只读镜像），
    发布要显式指定：npm publish --registry=https://registry.npmjs.org
  * 三个包都没有 scope，所以不会遇到「scope 需要付费组织」的问题。
  * 发完检查一遍：npm view <name> dist.tarball，再在一台干净机器上
    `dsh plugin --profile web add <name>` 走一次真实安装路径。
NOTE
  exit 0
fi

# ── 3. 发布 ────────────────────────────────────────────────────────────────

# The registry has to be named here too. This machine's default registry is
# npmmirror (a read-only mirror), and `npm login --registry=…npmjs.org` stores
# the token **scoped to that registry** — so a bare `npm whoami` asks the mirror,
# which has no credentials for it, and reports "not logged in" while the login is
# perfectly good. That false negative is what made the first run of this script
# stop right after a successful login.
# 凭据检查只做**打包**那半（`--dry-run`）：它证明包能装对，不证明能发上去。
# 为什么不用 `npm whoami`：npm 现在限制 bypass-2FA token 访问账号类接口，whoami 回 401
# **而发布能不能成功是另一回事**——拿它当门槛会直接劝退。反过来，dry-run 通过也不等于
# 能发布：2026-09 起 npm 明确收紧「bypass-2FA token 直接发布」，本机那个 token 就是
# 被这条挡下的（真发布回 404 not found / no permission）。所以真正的发布权限只能靠
# 交互式认证拿到：`npm login --auth-type=web`（Touch ID）之后再跑本脚本。
if ! ( cd "$ROOT/plugins/${PACKAGES[0]}" && npm publish --registry="$NPM_REGISTRY" --dry-run >/dev/null 2>&1 ); then
  die "打不出包（$NPM_REGISTRY）：先看 npm pack 的输出"
fi
printf '  打包检查通过（%s 的 dry-run）\n' "${PACKAGES[0]}"
printf '  提醒：真发布需要交互式认证——npm 已收紧 bypass-2FA token；失败时先 npm login --auth-type=web\n' 

say "发布"
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  ( cd "$ROOT/plugins/$name" && npm publish --registry="$NPM_REGISTRY" --access public ${OTP:+--otp="$OTP"} )
done

say "完成"
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  pkg="$(node -p "require('$ROOT/plugins/$name/package.json').name")"
  printf '  %s → https://www.npmjs.com/package/%s\n' "$pkg" "$pkg"
done
cat <<'NOTE'

别忘了：插件包装上之后，`dsh plugin --profile web add <name>` 才是真正给用户的路。
建议立刻在一台干净的机器（或临时 DSH_HOME）上试一次安装，确认它能成为 profile 的一层。
NOTE
