#!/bin/bash
# ============================================================
# DSH 中转（relay-go）受控升级
#
# 构建 Linux 静态二进制 → 上传 → 目标机冒烟 → 留档/备份 → 替换 →
# 45 秒内等新版本健康 → 再观察 60 秒。任何一步不健康，目标机自动把上一份
# 二进制与 build.json 放回去并重启；回滚后再次失败会明确报错，不掩盖。
#
# 用法:
#   ./scripts/release/deploy-relay.sh [--version go-0.3.5] [--no-build] [--dry-run] [--observe 60]
#
# 前置：.env.local 里有 DSH_OTA_HOST；本机能 ssh root@$DSH_OTA_HOST。
# 回滚：升级时会把上一份留在 /opt/dsh-relay-go/bin/history/<version>/；
#       自动回滚失败时按 README §5 手工把该目录的二进制与 build.json 放回。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${RELAY_VERSION:-go-0.3.5}"
NO_BUILD=0
DRY_RUN=0
OBSERVE=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version 需要值}"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --observe) OBSERVE="${2:?--observe 需要秒数}"; shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) printf 'error: 未知参数 %s\n' "$1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 2; }

# shellcheck disable=SC1091
[ -f "$ROOT/.env.local" ] && . "$ROOT/.env.local"
HOST="${DSH_OTA_HOST:?没有 DSH_OTA_HOST：在 .env.local 里配置}"
[[ "$HOST" == *example.com ]] && die "DSH_OTA_HOST 还是占位符"

BIN="$ROOT/relay-go/bin/dsh-relay-linux-amd64"
BUILD_JSON="$ROOT/relay-go/bin/build.json"

if [[ "$NO_BUILD" == 0 ]]; then
  step "构建 Linux 静态二进制（${VERSION}）"
  (
    cd "$ROOT/relay-go"
    GOMODCACHE="$PWD/.gocache/mod" GOCACHE="$PWD/.gocache/build" \
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags "-s -w" -o bin/dsh-relay-linux-amd64 ./cmd/dsh-relay
  )
else
  step "复用已有二进制（--no-build）"
fi
[[ -x "$BIN" ]] || die "二进制不存在：$BIN"
file "$BIN" | grep -q 'ELF 64-bit' || die "不是 Linux ELF：$BIN"

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$BUILD_JSON" <<EOF
{"version":"$VERSION","commit":"$COMMIT","deployedAt":"$DEPLOYED_AT"}
EOF
SHA256="$(shasum -a 256 "$BIN" | awk '{print $1}')"
printf '   提交 %s\n   二进制 %s（%s）\n   sha256 %s\n' "$COMMIT" "$BIN" "$(du -h "$BIN" | cut -f1)" "$SHA256"

if [[ "$DRY_RUN" == 1 ]]; then
  step "预演：不 ssh、不上传、不重启"
  printf '   目标 %s\n   版本 %s\n   观察 %s 秒\n' "$HOST" "$VERSION" "$OBSERVE"
  exit 0
fi

STAGE="/opt/dsh-relay-go/incoming/${VERSION}-$(date +%Y%m%dT%H%M%S)"
step "上传到 $HOST:$STAGE"
ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST" "install -d -m 0755 '$STAGE'"
scp -q "$BIN" "root@$HOST:$STAGE/dsh-relay"
scp -q "$BUILD_JSON" "root@$HOST:$STAGE/build.json"
scp -q "$ROOT/relay-go/deploy/remote-upgrade.sh" "root@$HOST:$STAGE/remote-upgrade.sh"

step "目标机受控升级（失败自动回滚）"
set +e
ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST" \
  "STAGED_BIN='$STAGE/dsh-relay' STAGED_BUILD='$STAGE/build.json' VERSION='$VERSION' OBSERVE='$OBSERVE' bash '$STAGE/remote-upgrade.sh'"
status=$?
set -e
if [[ "$status" == 0 ]]; then
  step "完成：$VERSION 已上线并通过观察期"
  printf '   健康检查：https://%s/dsh-link/healthz\n' "$HOST"
else
  step "升级未成功（退出码 $status）；见上方 ROLLBACK 记录"
  printf '   上一版本已自动恢复则服务继续可用；若为 ROLLBACK-FAILED，按 README §5 手工恢复。\n'
fi
exit "$status"
