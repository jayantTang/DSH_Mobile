#!/usr/bin/env bash
#
# Idempotent install/refresh for the DLP relay on an Alibaba Cloud Linux 3 host.
#
#   sudo relay/deploy/deploy.sh              install or update
#   sudo relay/deploy/deploy.sh --uninstall  remove this host's wiring
#
# What it does, in order:
#   1. creates the dedicated `dsh-relay` system user and its directories
#   2. copies the relay sources and builds/refreshes a venv (Python 3.12)
#   3. installs and (re)starts the sandboxed systemd unit
#   4. splices a marked /dsh-link/* route fragment INSIDE the existing "$SITE"
#      site block of /etc/caddy/Caddyfile (before the first handle / handle_path
#      / route directive), validates the result with `caddy validate`, and only
#      then reloads Caddy
#   5. health-checks the loopback port (both path forms) and the public
#      https://$SITE$BASE_PATH/healthz
#
# The relay is published as a path prefix on an existing, already-certified
# site: no new DNS record and no new certificate. Nothing else in the Caddyfile
# is rewritten, reordered or deleted — the fragment lives between two marker
# comments, so re-running replaces it in place and `--uninstall` (or deleting
# the two marked lines) reverts the file byte for byte. Caddy's configuration is
# validated before every reload, so a bad edit cannot take the existing site down.
#
# Overridable via environment: DSH_RELAY_USER, DSH_RELAY_DIR, DSH_RELAY_DATA,
# DSH_RELAY_PORT, DSH_RELAY_SITE, DSH_RELAY_BASE_PATH, DSH_RELAY_PYTHON,
# CADDYFILE.

set -euo pipefail

SERVICE_USER="${DSH_RELAY_USER:-dsh-relay}"
APP_DIR="${DSH_RELAY_DIR:-/opt/dsh-relay}"
DATA_DIR="${DSH_RELAY_DATA:-/var/lib/dsh-relay}"
PORT="${DSH_RELAY_PORT:-8787}"
SITE="${DSH_RELAY_SITE:-relay.example.com}"
BASE_PATH="${DSH_RELAY_BASE_PATH:-/dsh-link}"
PYTHON="${DSH_RELAY_PYTHON:-/usr/local/bin/python3.12}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
UNIT_PATH="/etc/systemd/system/dsh-relay.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLICER="$SRC_DIR/deploy/caddy_splice.py"
SNIPPET="$SRC_DIR/deploy/Caddyfile.snippet"
PUBLIC_URL="https://${SITE}${BASE_PATH}"
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

say() { printf 'deploy.sh: %s\n' "$*"; }
die() { printf 'deploy.sh: error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "run me as root (sudo $0)"
[ -x "$PYTHON" ] || die "$PYTHON not found; set DSH_RELAY_PYTHON"
[ -f "$SPLICER" ] || die "$SPLICER is missing (run this script from the relay checkout)"
[ -f "$SNIPPET" ] || die "$SNIPPET is missing (run this script from the relay checkout)"
"$PYTHON" -c 'import venv' >/dev/null 2>&1 || die "$PYTHON cannot create venvs (install python3.12-venv)"

# ── uninstall ───────────────────────────────────────────────────────────────

if [ "$UNINSTALL" -eq 1 ]; then
  say "stopping and removing the systemd unit"
  systemctl disable --now dsh-relay.service >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload

  if [ -f "$CADDYFILE" ]; then
    action="$("$PYTHON" "$SPLICER" remove "$CADDYFILE")" || die "could not edit $CADDYFILE"
    if [ "$action" = "removed" ]; then
      say "removed the $BASE_PATH route from $CADDYFILE"
      if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        say "$SITE keeps serving its original configuration"
      else
        die "the Caddyfile did not validate after removal; fix it before reloading Caddy"
      fi
    else
      say "no marked block in $CADDYFILE; nothing to remove"
    fi
  fi
  say "done; $APP_DIR and $DATA_DIR (the database) were left in place"
  exit 0
fi

# ── 1. user and directories ─────────────────────────────────────────────────

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  say "creating the $SERVICE_USER system user"
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin --comment "DSH relay" "$SERVICE_USER"
fi

install -d -m 0755 -o root -g root "$APP_DIR"
# Static root for over-the-air iOS installs, served by the same Caddy block.
install -d -m 0755 -o root -g root "$APP_DIR/public"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"

# ── 2. sources and venv ─────────────────────────────────────────────────────

say "installing relay sources into $APP_DIR"
for module in relay.py api.py dlp.py store.py hub.py admin.py; do
  [ -f "$SRC_DIR/$module" ] || die "$SRC_DIR/$module is missing"
  install -m 0644 -o root -g root "$SRC_DIR/$module" "$APP_DIR/$module"
done
install -m 0644 -o root -g root "$SRC_DIR/requirements.txt" "$APP_DIR/requirements.txt"
[ -f "$SRC_DIR/README.md" ] && install -m 0644 -o root -g root "$SRC_DIR/README.md" "$APP_DIR/README.md" || true
[ -f "$SRC_DIR/../docs/notes/relay.md" ] && install -m 0644 -o root -g root "$SRC_DIR/../docs/notes/relay.md" "$APP_DIR/NOTES.md" || true

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
install -m 0644 -o root -g root "$SRC_DIR/deploy/dsh-relay.service" "$UNIT_PATH"
systemctl daemon-reload
systemctl enable dsh-relay.service >/dev/null
if systemctl is-active --quiet dsh-relay.service; then
  systemctl restart dsh-relay.service
else
  systemctl start dsh-relay.service
fi

# ── 4. Caddy ────────────────────────────────────────────────────────────────

[ -f "$CADDYFILE" ] || die "$CADDYFILE not found; is Caddy installed?"
command -v caddy >/dev/null || die "the caddy binary is not on PATH"

say "adding the $BASE_PATH route to the $SITE site in $CADDYFILE"
BACKUP="$(mktemp "${CADDYFILE}.deploy.XXXXXX")"
cp -a "$CADDYFILE" "$BACKUP"
trap 'rm -f "$BACKUP"' EXIT

action="$("$PYTHON" "$SPLICER" insert "$CADDYFILE" "$SNIPPET" "$SITE")" \
  || die "could not insert the managed block; $CADDYFILE was left untouched"
say "$action the $BASE_PATH route (between 'dsh-relay managed block' markers)"

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  cp -a "$BACKUP" "$CADDYFILE"
  die "the spliced Caddyfile is invalid; the original was restored untouched"
fi
say "Caddy configuration validates"
systemctl reload caddy 2>/dev/null || systemctl restart caddy

# ── 5. health checks ────────────────────────────────────────────────────────

if command -v curl >/dev/null; then
  say "waiting for the relay on 127.0.0.1:$PORT"
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT/healthz" || die "the relay is not answering on 127.0.0.1:$PORT"
  # Exercise the prefixed form too: a front end may either strip the prefix
  # (Caddy's handle_path) or forward it verbatim, and both must work.
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT$BASE_PATH/healthz" >/dev/null \
    || die "the relay does not answer the prefixed form $BASE_PATH/healthz"
  printf '\n'

  if getent hosts "$SITE" >/dev/null 2>&1; then
    if curl -fsS --max-time 15 "$PUBLIC_URL/healthz" >/dev/null 2>&1; then
      say "$PUBLIC_URL/healthz is live"
    else
      say "WARNING: $PUBLIC_URL/healthz did not answer; check 'journalctl -u caddy -n 50'"
    fi
  else
    say "note: $SITE does not resolve here; the relay still works on 127.0.0.1:$PORT"
  fi
else
  say "note: curl is not installed; skipping the health checks"
  systemctl is-active --quiet dsh-relay.service || die "dsh-relay.service is not running"
fi

cat <<EOF

deploy.sh: done.

Public URL:  $PUBLIC_URL        (health: $PUBLIC_URL/healthz)
Connector relay URL:  wss://$SITE$BASE_PATH

Next steps:
  1. provision your PC (run the --write-config step as *your* desktop user):
       sudo -u $SERVICE_USER $APP_DIR/.venv/bin/python $APP_DIR/admin.py \
           --db $DATA_DIR/state.db account-create --name "Your name"
       $APP_DIR/.venv/bin/python $APP_DIR/admin.py \
           --db $DATA_DIR/state.db agent-register --account <acc_...> --name "MacBook Pro" \
           --relay wss://$SITE$BASE_PATH --write-config ~/.dsh/mobile-link/agent.json
  2. mint a pairing code:
       $APP_DIR/.venv/bin/python $APP_DIR/admin.py --db $DATA_DIR/state.db code-mint --agent <agt_...>
  3. install the DSH plugin on the PC (dsh plugin --profile web add ./plugins/mobile-link),
     restart DSH, then scan the dsh://pair?... QR payload.

To revert ONLY the Caddy change:   sudo $0 --uninstall
Both marked lines can also simply be deleted from $CADDYFILE by hand.
Logs: journalctl -u dsh-relay -f    /    journalctl -u caddy -f
EOF
