#!/usr/bin/env bash
#
# Idempotent install/refresh for the DSH mail service (DESIGN-20261015 M3).
# Copied from relay/deploy/deploy.sh and adapted: same structure, mail's own
# user / dirs / unit / Caddy markers. The two deploy scripts are deliberately
# NOT parameterized into one — the split exists so each service can be
# deployed without touching the other.
#
#   sudo mail/deploy/deploy.sh              install or update
#   sudo mail/deploy/deploy.sh --uninstall  remove this service's wiring
#
# What it does, in order:
#   1. creates the dedicated `dsh-mail` system user and its directories
#   2. copies the mail sources and builds/refreshes a venv (Python 3.12)
#   3. installs and (re)starts the sandboxed systemd unit
#   4. splices a SECOND marked /dsh-link/feedback/* route fragment into the
#      existing "$SITE" site block of /etc/caddy/Caddyfile (independent
#      markers from the relay's fragment), validates with `caddy validate`,
#      and only then reloads Caddy
#   5. health-checks the loopback port (both path forms) and the public
#      /dsh-link/feedback/* route (a 400 from the mail service proves the
#      route arrived; a 404 would mean Caddy is not routing)
#
# The mail service NEVER touches the relay's unit, fragment or database.
# Data migration from the relay's state.db is a separate, explicit step:
# mail/deploy/migrate_from_relay.py (run it once, in the cutover window).

set -euo pipefail

SERVICE_USER="${DSH_MAIL_USER:-dsh-mail}"
APP_DIR="${DSH_MAIL_DIR:-/opt/dsh-mail}"
DATA_DIR="${DSH_MAIL_DATA:-/var/lib/dsh-mail}"
PORT="${DSH_MAIL_PORT:-8788}"
SITE="${DSH_MAIL_SITE:-relay.example.com}"
BASE_PATH="${DSH_MAIL_BASE_PATH:-/dsh-link}"
PYTHON="${DSH_MAIL_PYTHON:-/usr/local/bin/python3.12}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
UNIT_PATH="/etc/systemd/system/dsh-mail.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLICER="$SRC_DIR/deploy/caddy_splice.py"
SNIPPET="$SRC_DIR/deploy/Caddyfile.snippet"
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

say() { printf 'deploy.sh: %s\n' "$*"; }
note() { printf 'deploy.sh: %s\n' "$*" >&2; }
die() { printf 'deploy.sh: error: %s\n' "$*" >&2; exit 1; }

# ── 团队收件箱开关的渲染（2026-10-17 生产事故后加固） ───────────────────────
#
# MAIL_TEAM_ACCOUNT 是团队收件箱的开关，真值 = owner 账号（本机 `.env.local` 的
# DSH_ACCOUNT_ID）。2026-10-17 01:47 的一次部署没有导出 `DSH_MAIL_TEAM_ACCOUNT`，
# 单元被渲染成空的开关；而线程的团队绑定（teamAccountId 列）不归它管——于是
# owner 的 App 照旧收到用户的来信，却被判成"用户侧视角"，那些信显示在他的
# 「已发送」里。两条规矩从此写死：
#
#   1. 只有**显式**给了 `DSH_MAIL_TEAM_ACCOUNT` 才改这一行；没给就沿用已装单元
#      里的现值（首次安装 = 空）。要关掉就显式给空值，别靠"忘导出"。
#   2. 值不是账号 id 的形状（或模板里没有那一行）直接拒部署，不留下半个单元。
#
# `--render-unit <path>` 是给测试用的旁路：不需要 root，只渲染单元（同一份代码路径）。

EXISTING_UNIT="${DSH_MAIL_EXISTING_UNIT:-$UNIT_PATH}"
UNIT_TEMPLATE="$SRC_DIR/deploy/dsh-mail.service"

existing_team_account() {
  [ -f "$EXISTING_UNIT" ] || return 0
  sed -n 's/^Environment=MAIL_TEAM_ACCOUNT=//p' "$EXISTING_UNIT" | head -n 1
}

render_unit() {
  local out="$1" team
  [ -n "$out" ] || die "--render-unit needs an output path"
  [ -f "$UNIT_TEMPLATE" ] || die "$UNIT_TEMPLATE is missing"
  grep -q '^Environment=MAIL_TEAM_ACCOUNT=$' "$UNIT_TEMPLATE" \
    || die "$UNIT_TEMPLATE has no empty MAIL_TEAM_ACCOUNT line; refusing to render blind"
  if [ -n "${DSH_MAIL_TEAM_ACCOUNT+x}" ]; then
    team="$DSH_MAIL_TEAM_ACCOUNT"
  else
    team="$(existing_team_account)"
    if [ -n "$team" ]; then
      note "DSH_MAIL_TEAM_ACCOUNT is not set; keeping the installed value ($team)"
    else
      note "DSH_MAIL_TEAM_ACCOUNT is not set and no installed value exists; team inbox stays off"
    fi
  fi
  case "$team" in
    "") ;;
    # 账号 id 的形状；任何别的字符（空白、换行、shell 元字符）都拒部署。
    # 用 case 而不是 grep：grep 是逐行匹配，带换行的值能骗过它。
    *[!A-Za-z0-9_.:@-]*) die "DSH_MAIL_TEAM_ACCOUNT is not an account id: $team" ;;
  esac
  sed -e "s/8788/$PORT/g" \
      -e "s|^Environment=MAIL_TEAM_ACCOUNT=$|Environment=MAIL_TEAM_ACCOUNT=$team|" \
      "$UNIT_TEMPLATE" > "$out"
  grep -q "^Environment=MAIL_TEAM_ACCOUNT=$team\$" "$out" \
    || die "the rendered unit does not carry MAIL_TEAM_ACCOUNT=$team"
  printf '%s' "$team"
}

case "${1:-}" in
  -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --render-unit)
    rendered="$(render_unit "${2:-}")"
    say "rendered ${2:-} (MAIL_TEAM_ACCOUNT=${rendered:-<empty: team inbox off>})"
    exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "run me as root (sudo $0)"
[ -x "$PYTHON" ] || die "$PYTHON not found; set DSH_MAIL_PYTHON"
[ -f "$SPLICER" ] || die "$SPLICER is missing (run this script from the mail checkout)"
[ -f "$SNIPPET" ] || die "$SNIPPET is missing (run this script from the mail checkout)"
"$PYTHON" -c 'import venv' >/dev/null 2>&1 || die "$PYTHON cannot create venvs (install python3.12-venv)"

# ── uninstall ───────────────────────────────────────────────────────────────

if [ "$UNINSTALL" -eq 1 ]; then
  say "stopping and removing the systemd unit"
  systemctl disable --now dsh-mail.service >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload

  if [ -f "$CADDYFILE" ]; then
    action="$("$PYTHON" "$SPLICER" remove "$CADDYFILE")" || die "could not edit $CADDYFILE"
    if [ "$action" = "removed" ]; then
      say "removed the mail route from $CADDYFILE"
      if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        say "$SITE keeps serving the relay's original configuration"
      else
        die "the Caddyfile did not validate after removal; fix it before reloading Caddy"
      fi
    else
      say "no mail marked block in $CADDYFILE; nothing to remove"
    fi
  fi
  say "done; $APP_DIR and $DATA_DIR (the letters database) were left in place"
  exit 0
fi

# ── 1. user and directories ─────────────────────────────────────────────────

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  say "creating the $SERVICE_USER system user"
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin --comment "DSH mail" "$SERVICE_USER"
fi

install -d -m 0755 -o root -g root "$APP_DIR"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"

# ── 2. sources and venv ─────────────────────────────────────────────────────

say "installing mail sources into $APP_DIR"
for module in mail.py api.py store.py internal.py admin.py; do
  [ -f "$SRC_DIR/$module" ] || die "$SRC_DIR/$module is missing"
  install -m 0644 -o root -g root "$SRC_DIR/$module" "$APP_DIR/$module"
done
install -m 0644 -o root -g root "$SRC_DIR/requirements.txt" "$APP_DIR/requirements.txt"

if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
  say "creating the virtualenv"
  "$PYTHON" -m venv "$APP_DIR/.venv"
fi
say "installing Python dependencies"
"$APP_DIR/.venv/bin/python" -m pip install --quiet --upgrade pip
"$APP_DIR/.venv/bin/python" -m pip install --quiet --upgrade -r "$APP_DIR/requirements.txt"
chown -R root:root "$APP_DIR/.venv"

# ── 3. systemd unit ─────────────────────────────────────────────────────────

say "installing $UNIT_PATH"
# 端口参数化：模板里的 8788 是默认值，同机可能被别的服务占用（2026-10-15 切换时
# 8788 就被另一个 node 服务占着）。单元与片段一起替换，保证三处（env、ExecStart、
# reverse_proxy）永远一致。团队收件箱开关由 render_unit 决定（见上面的两条规矩）。
TEAM_ACCOUNT_RENDERED="$(render_unit "$UNIT_PATH.rendered")"
install -m 0644 -o root -g root "$UNIT_PATH.rendered" "$UNIT_PATH"
rm -f "$UNIT_PATH.rendered"
say "team inbox switch: ${TEAM_ACCOUNT_RENDERED:-off}"
systemctl daemon-reload
systemctl enable dsh-mail.service >/dev/null
if systemctl is-active --quiet dsh-mail.service; then
  systemctl restart dsh-mail.service
else
  systemctl start dsh-mail.service
fi

# ── 4. Caddy ────────────────────────────────────────────────────────────────

[ -f "$CADDYFILE" ] || die "$CADDYFILE not found; is Caddy installed?"
command -v caddy >/dev/null || die "the caddy binary is not on PATH"

say "adding the $BASE_PATH/feedback/* route to the $SITE site in $CADDYFILE"
BACKUP="$(mktemp "${CADDYFILE}.deploy.XXXXXX")"
cp -a "$CADDYFILE" "$BACKUP"
trap 'rm -f "$BACKUP"' EXIT

SNIPPET_RENDERED="$(mktemp)"
sed "s/127.0.0.1:8788/127.0.0.1:$PORT/g" "$SNIPPET" > "$SNIPPET_RENDERED"
action="$("$PYTHON" "$SPLICER" insert "$CADDYFILE" "$SNIPPET_RENDERED" "$SITE")" \
  || die "could not insert the managed block; $CADDYFILE was left untouched"
say "$action the mail route (between 'dsh-mail managed block' markers)"

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  cp -a "$BACKUP" "$CADDYFILE"
  die "the spliced Caddyfile is invalid; the original was restored untouched"
fi
say "Caddy configuration validates"
systemctl reload caddy 2>/dev/null || systemctl restart caddy

# ── 5. health checks ────────────────────────────────────────────────────────

if command -v curl >/dev/null; then
  say "waiting for the mail service on 127.0.0.1:$PORT"
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT/healthz" || die "the mail service is not answering on 127.0.0.1:$PORT"
  # The prefixed form must work too (MAIL_BASE_PATH keeps it alive).
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT$BASE_PATH/healthz" >/dev/null \
    || die "the mail service does not answer the prefixed form $BASE_PATH/healthz"
  printf '\n'

  if getent hosts "$SITE" >/dev/null 2>&1; then
    # Public proof that the route arrived: an empty submit is a 400 from the
    # mail service ("text is required"). A 404 would mean Caddy is not routing
    # /dsh-link/feedback/* to us — the one failure this check exists to catch.
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -X POST "https://$SITE$BASE_PATH/feedback/submit" \
      -H 'content-type: application/json' -d '{}' || true)"
    if [ "$status" = "400" ]; then
      say "https://$SITE$BASE_PATH/feedback/* is live (400 = the service answered)"
    else
      # 2026-10-15 切换实测：端口被同机另一个服务占用时，路由会把信件打进
      # 别人的后端（公网提交回 200 而不是 400）。这条检查必须**硬失败**——
      # 警告会被部署输出刷过去，而这是"路由进错服务"的唯一现场信号。
      die "public submit returned HTTP $status (expected 400): the route is NOT reaching this service; check the port and 'journalctl -u caddy -n 50'"
    fi
  else
    say "note: $SITE does not resolve here; the mail service still works on 127.0.0.1:$PORT"
  fi
else
  say "note: curl is not installed; skipping the health checks"
  systemctl is-active --quiet dsh-mail.service || die "dsh-mail.service is not running"
fi

cat <<EOF

deploy.sh: done.
  service : dsh-mail.service (loopback :$PORT)
  route   : https://$SITE$BASE_PATH/feedback/* -> 127.0.0.1:$PORT
  data    : $DATA_DIR/mail.db
  rollback: sudo mail/deploy/deploy.sh --uninstall
EOF
