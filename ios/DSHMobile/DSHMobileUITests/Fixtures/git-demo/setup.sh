#!/usr/bin/env bash
# Builds the throwaway repository the Git case reads.
#
# It has to be a real repository with real commits: the whole point of the case
# is that the app can show a *baseline* — what a file said before it changed —
# which is exactly what the Host's filesystem observations could not do. Two
# commits, then a working tree with one of every kind of change, so the change
# list has something of each to render.
set -euo pipefail

ROOT="${1:-/tmp/dsh-git-demo}"
rm -rf "$ROOT"
mkdir -p "$ROOT/src"

cd "$ROOT"
git init -q -b main
git config user.email "fixture@example.com"
git config user.name "界面夹具"

cat > README.md <<'MD'
# Git 面板夹具

这是第一次提交的版本。
MD
cat > src/app.js <<'JS'
export function greet(name) {
  return `你好，${name}`
}
JS
printf '第一行\n第二行\n第三行\n' > notes.txt
git add -A
git commit -q -m "初始提交：夹具仓库"

cat > README.md <<'MD'
# Git 面板夹具

这是第二次提交的版本。
加了第二行。
MD
git add -A
git commit -q -m "第二次提交：README 补一行"

# A non-text attachment at the repository root: the cache/revalidation case
# (TC-MOB-23) needs a file whose open goes through the download path, and a
# fixed size so assertions can name an exact byte count.
python3 -c "import random; random.seed(20260918); open('附件.bin','wb').write(random.randbytes(300000))"

# Now a working tree with one of each: an unstaged edit, a staged edit, an
# untracked file and a rename. The case asserts on these names.
printf '第四行（工作区改动）\n' >> notes.txt
cat > src/app.js <<'JS'
export function greet(name) {
  return `你好，${name}！`
}
JS
git add src/app.js
git mv README.md 说明.md
printf '还没有入库的文件\n' > 新文件.txt

echo "fixture ready: $ROOT"
git status --short
