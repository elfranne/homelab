#!/usr/bin/env bash
#
# caddy-provision.sh — first-run setup for the Caddy ingress container.
#
# The container itself comes from caddy.yaml, built with image.sh. This script does ONLY
# the things an image cannot contain, because they are per-instance or secret:
#
#   * the answers  — LAN IP and ACME email, stored as `user.*` keys on the instance. The
#                    image's Incus templates read them back with config_get() every time the
#                    container starts, so the Caddyfile and the eth1 address regenerate
#                    themselves after an `image.sh update` with nothing re-running.
#   * the secret   — the Cloudflare API token, written to the state volume at mode 600. It
#                    is deliberately NOT a user.* key: those are visible in `incus config
#                    show` and travel inside `incus export` tarballs and instance copies.
#   * the devices  — the state volume, and the macvlan eth1 that gives the proxy its foot on
#                    the LAN. Devices are instance config, so they too survive a rebuild.
#
# Why the container is dual-homed: from step 1, macvlan guests reach the LAN but NOT the
# host, and NAT guests are private behind incusbr0. A macvlan-only proxy could not reach a
# NAT-only backend. One foot on each network makes this the single public entrypoint while
# every backend stays private — and the host's own networking is never touched.
#
# Interactive, fail-fast, idempotent. Run it ONCE after building the image; re-running is
# safe and is how you change an answer. Run as a user in the incus-admin group (or root),
# from the box or anywhere `incus` reaches it. It changes nothing on the host.
#
#   Usage:   ./caddy-provision.sh                  # normal run
#            CF_API_TOKEN=... ./caddy-provision.sh # pass the token via the environment
#            ./caddy-provision.sh --help
#
#   Build the image first:
#            "../1 - Hypervisor Install/image.sh" build "2 - Containers/caddy.yaml"
#
#   All settings are prompted at the start of the run; the CONFIG values below are only the
#   defaults pre-filled at each prompt, so editing them is optional. The Cloudflare API token
#   is never stored in this script — it is prompted for (hidden) or read from $CF_API_TOKEN.
#
set -Eeuo pipefail

####################  CONFIG — DEFAULTS (prompted interactively)  ####################
CADDY_NAME="caddy"             # Incus instance name for the ingress
CADDY_IMAGE="caddy"            # image alias, i.e. the basename of caddy.yaml
CADDY_LAN_IP=""                # STATIC LAN IP for eth1, CIDR form e.g. 192.168.1.50/24
                                # (empty -> prompted; this is your DNS target)
LAN_PROFILE="lan"              # step-1 macvlan profile; its parent NIC is reused for eth1
ACME_EMAIL=""                  # email Let's Encrypt uses for expiry notices (prompted)

STORAGE_POOL="default"         # Incus storage pool created in step 1
STATE_VOLUME="caddy-state"     # custom volume holding the token, sites, and the ACME store
STATE_PATH="/var/lib/homelab"  # where that volume is mounted inside the container

ASSUME_YES="${ASSUME_YES:-0}"  # 1 = skip per-phase pauses
#######################################################################################

# ---------- pretty output ----------
if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
else RED=""; GRN=""; YLW=""; BLU=""; BLD=""; RST=""; fi
log()  { echo "${BLU}[*]${RST} $*"; }
ok()   { echo "${GRN}[OK]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
die()  { echo "${RED}[ERROR]${RST} $*" >&2; exit 1; }
phase(){ echo; echo "${BLD}========== Phase $1: $2 ==========${RST}"; }

on_err() {
  local ec=$? ln=${BASH_LINENO[0]:-?}
  echo >&2
  echo "${RED}[FAIL]${RST} line ${ln}: exit ${ec} while running: ${BASH_COMMAND}" >&2
  echo "${RED}Aborting. Fix the cause and re-run — the script is idempotent.${RST}" >&2
  exit "$ec"
}
trap on_err ERR

# ---------- interaction ----------
confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans=""
  read -r -p "$1 [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
require_yes() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans=""
  while :; do
    read -r -p "$1 [y/N] " ans </dev/tty || ans=""
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] && return 0
    warn "Not confirmed — type 'y' to proceed, or press Ctrl-C to abort."
  done
}
pause() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  read -r -p "${1:-Press Enter to continue (Ctrl-C to abort)…}" _ </dev/tty || true
}

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

cexec() { incus exec "$CADDY_NAME" -- "$@"; }                 # run a command in the container
cwrite() { # cwrite PATH [MODE] [OWNER] — write stdin to PATH inside the container
  incus exec "$CADDY_NAME" -- sh -c \
    "umask 077; cat > '$1' && chmod '${2:-600}' '$1' && chown '${3:-root:root}' '$1'"
}

ct_exists()  { incus info "$CADDY_NAME" >/dev/null 2>&1; }
ct_running() { [[ "$(incus list "$CADDY_NAME" -c s -f csv 2>/dev/null)" == "RUNNING" ]]; }
vol_exists() { incus storage volume list "$STORAGE_POOL" -f csv 2>/dev/null | grep -q "^custom,${1},"; }
dev_exists() { incus config device list "$CADDY_NAME" 2>/dev/null | grep -qx "$1"; }

wait_for_net() { # wait until the container can resolve + reach the internet (ACME/apt)
  local tries=0
  while (( tries < 30 )); do
    cexec sh -c 'getent hosts deb.debian.org >/dev/null 2>&1' && return 0
    sleep 2; tries=$((tries+1))
  done
  die "Container '$CADDY_NAME' has no working network/DNS after ~60s (check the NAT bridge / DNS)."
}

valid_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }

# =====================================================================================
run() {
  echo "${BLD}Caddy ingress — first-run provisioning${RST}"

  # ---- Phase 0: preflight ----
  phase 0 "Preflight checks"
  need_cmd incus
  incus info >/dev/null 2>&1 || die "'incus info' failed — is Incus installed (step 1) and are you in the incus-admin group (log out/in) or root?"
  incus profile list -f csv 2>/dev/null | grep -q '^default,' \
    || die "Incus 'default' profile missing — run step 1 (incus-install.sh) first."
  incus profile list -f csv 2>/dev/null | grep -q "^${LAN_PROFILE}," \
    || die "Incus '$LAN_PROFILE' profile missing — run step 1 (incus-install.sh) first."
  incus storage list -f csv 2>/dev/null | grep -q "^${STORAGE_POOL}," \
    || die "Incus storage pool '$STORAGE_POOL' missing — run step 1 (incus-install.sh) first."
  incus image info "$CADDY_IMAGE" >/dev/null 2>&1 \
    || die "No image alias '$CADDY_IMAGE' — build it first:
  \"../1 - Hypervisor Install/image.sh\" build \"2 - Containers/caddy.yaml\""

  # The macvlan parent for eth1: reuse the parent the step-1 'lan' profile already uses,
  # so the LAN attachment is identical to the rest of the homelab.
  local UPLINK
  UPLINK="$(incus profile device get "$LAN_PROFILE" eth0 parent 2>/dev/null || true)"
  [[ -n "$UPLINK" ]] || die "Could not read the macvlan parent NIC from the '$LAN_PROFILE' profile (incus profile device get $LAN_PROFILE eth0 parent)."
  ok "Incus reachable; image '$CADDY_IMAGE' present; macvlan parent for eth1: $UPLINK"

  # Pre-fill the prompts from what the instance already answers, so a re-run is a review
  # rather than a re-entry.
  if ct_exists; then
    warn "Instance '$CADDY_NAME' already exists — reusing and re-applying (idempotent)."
    [[ -n "$CADDY_LAN_IP" ]] || CADDY_LAN_IP="$(incus config get "$CADDY_NAME" user.lan_ip 2>/dev/null || true)"
    [[ -n "$ACME_EMAIL"   ]] || ACME_EMAIL="$(incus config get "$CADDY_NAME" user.acme_email 2>/dev/null || true)"
  fi

  # ---- Phase 1: settings ----
  phase 1 "Settings"
  # LAN IP (static, no gateway — clients connect to this; it's your DNS target).
  while :; do
    if [[ -n "$CADDY_LAN_IP" ]]; then
      read -r -p "Static LAN IP for the proxy (CIDR, e.g. 192.168.1.50/24) [${CADDY_LAN_IP}]: " _in </dev/tty || _in=""
      _in="${_in:-$CADDY_LAN_IP}"
    else
      read -r -p "Static LAN IP for the proxy (CIDR, e.g. 192.168.1.50/24): " _in </dev/tty || _in=""
    fi
    valid_cidr "$_in" && { CADDY_LAN_IP="$_in"; break; }
    warn "Enter an IPv4 address in CIDR form, e.g. 192.168.1.50/24."
  done

  # ACME contact email.
  while :; do
    if [[ -n "$ACME_EMAIL" ]]; then
      read -r -p "Email for Let's Encrypt expiry notices [${ACME_EMAIL}]: " _in </dev/tty || _in=""
      _in="${_in:-$ACME_EMAIL}"
    else
      read -r -p "Email for Let's Encrypt expiry notices: " _in </dev/tty || _in=""
    fi
    [[ "$_in" == *@*.* ]] && { ACME_EMAIL="$_in"; break; }
    warn "Enter a valid email address."
  done

  # Cloudflare API token: from $CF_API_TOKEN, else prompted hidden. On a re-run the token
  # already on the volume is kept if you just press Enter.
  local CF_TOKEN="${CF_API_TOKEN:-}"
  local have_token=0
  if ct_exists && ct_running && cexec test -s "$STATE_PATH/caddy.env" 2>/dev/null; then have_token=1; fi
  if [[ -z "$CF_TOKEN" ]]; then
    if (( have_token )); then
      echo "Cloudflare API token — press Enter to keep the one already on the volume."
      read -rs -p "  Token: " CF_TOKEN </dev/tty || CF_TOKEN=""
      echo
    else
      echo "Cloudflare API token (scoped Zone → DNS → Edit for your zone). Input is hidden."
      read -rs -p "  Token: " CF_TOKEN </dev/tty || CF_TOKEN=""
      echo
    fi
  else
    log "Using Cloudflare API token from \$CF_API_TOKEN."
  fi
  [[ -n "$CF_TOKEN" || $have_token -eq 1 ]] \
    || die "No Cloudflare API token provided (prompt or \$CF_API_TOKEN)."

  echo
  echo "Settings:"
  printf '  %-16s %s\n' "Instance:"   "$CADDY_NAME (image '$CADDY_IMAGE')"
  printf '  %-16s %s\n' "NAT nic:"    "eth0 (default profile, incusbr0)"
  printf '  %-16s %s\n' "LAN nic:"    "eth1 (macvlan on $UPLINK) — static $CADDY_LAN_IP"
  printf '  %-16s %s\n' "ACME email:" "$ACME_EMAIL"
  printf '  %-16s %s\n' "CF token:"   "$( [[ -n "$CF_TOKEN" ]] && echo '(provided, hidden)' || echo '(keeping the existing one)')"
  printf '  %-16s %s\n' "State:"      "$STORAGE_POOL/$STATE_VOLUME mounted at $STATE_PATH"
  require_yes "Proceed with these settings?"

  # ---- Phase 2: instance, volume, devices ----
  phase 2 "Create the instance, state volume, and macvlan eth1"
  pause
  # The answers go on the instance BEFORE first start, so the image's templates render
  # correctly the very first time the container boots.
  if ! ct_exists; then
    incus init "$CADDY_IMAGE" "$CADDY_NAME" -p default \
      -c "user.lan_ip=$CADDY_LAN_IP" -c "user.acme_email=$ACME_EMAIL"
    ok "Initialised '$CADDY_NAME' from image '$CADDY_IMAGE'."
  else
    incus config set "$CADDY_NAME" user.lan_ip    "$CADDY_LAN_IP"
    incus config set "$CADDY_NAME" user.acme_email "$ACME_EMAIL"
    log "Re-applied user.lan_ip / user.acme_email."
  fi

  # State volume: the token, the per-service site files, and Caddy's ACME store. Everything
  # that must outlive an `image.sh update` lives here.
  if ! vol_exists "$STATE_VOLUME"; then
    incus storage volume create "$STORAGE_POOL" "$STATE_VOLUME" >/dev/null
    ok "Created custom volume $STORAGE_POOL/$STATE_VOLUME."
  else
    log "Custom volume $STORAGE_POOL/$STATE_VOLUME already exists."
  fi
  if ! dev_exists state; then
    incus config device add "$CADDY_NAME" state disk \
      pool="$STORAGE_POOL" source="$STATE_VOLUME" path="$STATE_PATH" >/dev/null
    ok "Attached $STORAGE_POOL/$STATE_VOLUME at $STATE_PATH."
  else
    log "State volume already attached."
  fi

  # The LAN foot. Devices are instance config, so this survives a rebuild.
  if ! dev_exists eth1; then
    incus config device add "$CADDY_NAME" eth1 nic \
      nictype=macvlan parent="$UPLINK" name=eth1 >/dev/null
    ok "Added macvlan eth1 (parent $UPLINK)."
  else
    log "eth1 already present on '$CADDY_NAME'."
  fi

  # Restart rather than start: the Incus templates re-render on every start, so this is what
  # makes a changed answer take effect.
  if ct_running; then incus restart "$CADDY_NAME"; else incus start "$CADDY_NAME"; fi
  wait_for_net
  ok "Container running; NAT reachable."

  # ---- Phase 3: the secret, then verify ----
  phase 3 "Install the Cloudflare token and start Caddy"
  if [[ -n "$CF_TOKEN" ]]; then
    printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN" | cwrite "$STATE_PATH/caddy.env" 600 caddy:caddy
    ok "Wrote $STATE_PATH/caddy.env (mode 600, on the state volume)."
  else
    log "Keeping the existing $STATE_PATH/caddy.env."
  fi

  # Caddy may have been up-and-retrying since boot without a token; restart it now that the
  # environment file is in place.
  cexec systemctl restart caddy
  cexec caddy validate --config /etc/caddy/Caddyfile >/dev/null \
    || die "caddy validate failed — inspect /etc/caddy/Caddyfile in '$CADDY_NAME'."
  cexec systemctl is-active --quiet caddy \
    || die "caddy is not active (incus exec $CADDY_NAME -- journalctl -u caddy)."

  # Confirm the templated pieces actually rendered from the user.* keys.
  local ipbare="${CADDY_LAN_IP%/*}"
  local tries=0
  while (( tries < 15 )); do
    cexec sh -c "ip -4 addr show dev eth1 2>/dev/null | grep -qw '$ipbare'" && break
    sleep 1; tries=$((tries+1))
  done
  cexec sh -c "ip -4 addr show dev eth1 2>/dev/null | grep -qw '$ipbare'" \
    || die "Static LAN IP $CADDY_LAN_IP did not appear on eth1 — check user.lan_ip and systemd-networkd in the container."
  cexec grep -q "$ACME_EMAIL" /etc/caddy/Caddyfile \
    || die "The Caddyfile template did not render user.acme_email — check 'incus config get $CADDY_NAME user.acme_email'."
  ok "Templates rendered: eth1 is $CADDY_LAN_IP, Caddyfile carries the ACME email."

  # ---- finish ----
  echo
  ok "Caddy ingress provisioned."
  echo
  echo "${BLD}Next:${RST}"
  echo "  - This proxy is your single HTTPS entrypoint at ${BLD}${ipbare}${RST} on the LAN."
  echo "  - Point each service's DNS record (e.g. cloud.example.com) at ${ipbare}"
  echo "    as a ${BLD}DNS-only${RST} (grey-cloud) A record. DNS-01 issues a real cert with no open port."
  echo "  - Add a service by dropping a file in ${STATE_PATH}/conf.d inside the container, then"
  echo "    'incus exec $CADDY_NAME -- systemctl reload caddy'. nextcloud-install.sh does this for you."
  echo "  - Everything that must survive an update lives on ${STORAGE_POOL}/${STATE_VOLUME}:"
  echo "    the token, ${STATE_PATH}/conf.d/*.caddy, and the ACME store at ${STATE_PATH}/caddy."
  echo "  - To ship a new base image: bump 'serial' in caddy.yaml, rebuild, then"
  echo "    \"../1 - Hypervisor Install/image.sh\" update $CADDY_IMAGE $CADDY_NAME"
}

usage() {
  sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
}

main() {
  case "${1:-}" in
    --help|-h) usage ;;
    "")        run ;;
    *)         die "Unknown argument: $1 (use --help)";;
  esac
}
main "$@"
