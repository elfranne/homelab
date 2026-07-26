#!/usr/bin/env bash
#
# reverse-proxy-install.sh — the homelab's single HTTPS ingress: a Caddy container.
#
# Creates one small Incus system container that terminates TLS for every service you
# run behind it. It is DUAL-HOMED on purpose:
#
#   eth0  incusbr0 NAT   — default route: reaches the internet (Cloudflare API for the
#                          ACME DNS-01 challenge) and the private backend containers.
#   eth1  macvlan/LAN     — a STATIC LAN IP (no gateway) that LAN clients connect *to*.
#                          This is the address you point your DNS records at.
#
# Why dual-homed: from step 1, macvlan guests can reach the LAN and each other but NOT
# the host, and NAT guests are private behind incusbr0. A macvlan-only proxy therefore
# could not reach a NAT-only backend. One foot on each network makes this the single
# public entrypoint while every backend stays private — and the host is left untouched.
#
# Caddy is built WITH the Cloudflare DNS module so it can obtain real Let's Encrypt
# certificates over the DNS-01 challenge — no inbound port is ever opened. Each service
# you add later drops one file into /etc/caddy/conf.d/<host>.caddy and gets its own
# certificate; see nextcloud-install.sh for the first one.
#
# Interactive, fail-fast, idempotent. Run it ONCE, from the box (or anywhere `incus`
# talks to this server) as a user in the incus-admin group (or root). It only talks to
# Incus and to the container it creates — it changes nothing on the host.
#
#   Usage:   ./reverse-proxy-install.sh                 # normal run
#            CF_API_TOKEN=... ./reverse-proxy-install.sh # pass the token via env
#            ./reverse-proxy-install.sh --help
#
#   All settings are prompted at the start of the run; the CONFIG values below are only
#   the defaults pre-filled at each prompt, so editing them is optional. The Cloudflare
#   API token is never stored in this script — it is prompted for (hidden) or read from
#   $CF_API_TOKEN, and lands only in /etc/caddy/caddy.env (mode 600) inside the container.
#
set -Eeuo pipefail

####################  CONFIG — DEFAULTS (prompted interactively)  ####################
PROXY_NAME="proxy"             # Incus container name for the ingress
PROXY_IMAGE="images:debian/13" # base image for the container
PROXY_LAN_IP=""                # STATIC LAN IP for eth1, CIDR form e.g. 192.168.1.50/24
                                # (empty -> prompted; this is your DNS target)
LAN_PROFILE="lan"              # step-1 macvlan profile; its parent NIC is reused for eth1
ACME_EMAIL=""                  # email Let's Encrypt uses for expiry notices (prompted)
CONF_DIR="/etc/caddy/conf.d"   # per-service Caddy site files live here (imported)

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

cexec() { incus exec "$PROXY_NAME" -- "$@"; }                 # run a command in the container
cwrite() { # cwrite PATH [MODE]   — write stdin to PATH inside the container (default 600)
  incus exec "$PROXY_NAME" -- sh -c "umask 077; cat > '$1' && chmod '${2:-600}' '$1'"
}

ct_exists() { incus info "$PROXY_NAME" >/dev/null 2>&1; }
ct_running() { [[ "$(incus list "$PROXY_NAME" -c s -f csv 2>/dev/null)" == "RUNNING" ]]; }

wait_for_net() { # wait until the container can resolve + reach the internet (apt/curl)
  local tries=0
  while (( tries < 30 )); do
    cexec sh -c 'getent hosts deb.debian.org >/dev/null 2>&1' && return 0
    sleep 2; tries=$((tries+1))
  done
  die "Container '$PROXY_NAME' has no working network/DNS after ~60s (check the NAT bridge / DNS)."
}

valid_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }

# =====================================================================================
run() {
  echo "${BLD}Reverse-proxy (Caddy) ingress installer — Incus container${RST}"

  # ---- Phase 0: preflight ----
  phase 0 "Preflight checks"
  need_cmd incus
  incus info >/dev/null 2>&1 || die "'incus info' failed — is Incus installed (step 1) and are you in the incus-admin group (log out/in) or root?"
  incus profile list -f csv 2>/dev/null | grep -q '^default,' \
    || die "Incus 'default' profile missing — run step 1 (incus-install.sh) first."
  incus profile list -f csv 2>/dev/null | grep -q "^${LAN_PROFILE}," \
    || die "Incus '$LAN_PROFILE' profile missing — run step 1 (incus-install.sh) first."

  # The macvlan parent for eth1: reuse the parent the step-1 'lan' profile already uses,
  # so the LAN attachment is identical to the rest of the homelab.
  local UPLINK
  UPLINK="$(incus profile device get "$LAN_PROFILE" eth0 parent 2>/dev/null || true)"
  [[ -n "$UPLINK" ]] || die "Could not read the macvlan parent NIC from the '$LAN_PROFILE' profile (incus profile device get $LAN_PROFILE eth0 parent)."
  ok "Incus reachable; macvlan parent for the LAN side (eth1): $UPLINK"

  if ct_exists; then
    warn "Container '$PROXY_NAME' already exists — it will be reused/reconfigured (idempotent)."
  fi

  # ---- Phase 1: settings ----
  phase 1 "Settings"
  # LAN IP (static, no gateway — clients connect to this; it's your DNS target).
  while :; do
    if [[ -n "$PROXY_LAN_IP" ]]; then
      read -r -p "Static LAN IP for the proxy (CIDR, e.g. 192.168.1.50/24) [${PROXY_LAN_IP}]: " _in </dev/tty || _in=""
      _in="${_in:-$PROXY_LAN_IP}"
    else
      read -r -p "Static LAN IP for the proxy (CIDR, e.g. 192.168.1.50/24): " _in </dev/tty || _in=""
    fi
    valid_cidr "$_in" && { PROXY_LAN_IP="$_in"; break; }
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

  # Cloudflare API token: from $CF_API_TOKEN, else prompted hidden. Never echoed/stored here.
  local CF_TOKEN="${CF_API_TOKEN:-}"
  if [[ -z "$CF_TOKEN" ]]; then
    echo "Cloudflare API token (scoped Zone → DNS → Edit for your zone). Input is hidden."
    read -rs -p "  Token: " CF_TOKEN </dev/tty || CF_TOKEN=""
    echo
  else
    log "Using Cloudflare API token from \$CF_API_TOKEN."
  fi
  [[ -n "$CF_TOKEN" ]] || die "No Cloudflare API token provided (prompt or \$CF_API_TOKEN)."

  echo
  echo "Settings:"
  printf '  %-16s %s\n' "Container:"   "$PROXY_NAME ($PROXY_IMAGE)"
  printf '  %-16s %s\n' "NAT nic:"     "eth0 (default profile, incusbr0)"
  printf '  %-16s %s\n' "LAN nic:"     "eth1 (macvlan on $UPLINK) — static $PROXY_LAN_IP"
  printf '  %-16s %s\n' "ACME email:"  "$ACME_EMAIL"
  printf '  %-16s %s\n' "CF token:"    "(provided, hidden)"
  printf '  %-16s %s\n' "Sites dir:"   "$CONF_DIR/*.caddy"
  require_yes "Proceed with these settings?"

  # ---- Phase 2: create the dual-homed container ----
  phase 2 "Create the proxy container (NAT eth0 + macvlan eth1)"
  pause
  if ! ct_exists; then
    incus launch "$PROXY_IMAGE" "$PROXY_NAME" -p default
  else
    ct_running || incus start "$PROXY_NAME"
  fi
  # Second NIC on the LAN via macvlan. Idempotent: only add if absent.
  if ! incus config device list "$PROXY_NAME" 2>/dev/null | grep -qx eth1; then
    incus config device add "$PROXY_NAME" eth1 nic nictype=macvlan parent="$UPLINK" name=eth1 >/dev/null
    ok "Added macvlan eth1 (parent $UPLINK)."
  else
    log "eth1 already present on '$PROXY_NAME'."
  fi

  wait_for_net

  # Static config for eth1 ONLY (no gateway/DNS — eth0/DHCP on incusbr0 supplies those).
  # Named 10-eth1.network so networkd evaluates it before the image's generic eth0.network
  # and the [Match] keeps it from touching eth0.
  cwrite /etc/systemd/network/10-eth1.network 644 <<EOF
[Match]
Name=eth1

[Network]
Address=${PROXY_LAN_IP}
# No Gateway= / DNS= on purpose: eth0 (incusbr0 DHCP) carries the default route + DNS.
EOF
  cexec systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
  cexec networkctl reload >/dev/null 2>&1 || cexec systemctl restart systemd-networkd
  # Confirm the LAN address actually landed on eth1.
  local ipbare="${PROXY_LAN_IP%/*}"
  local tries=0
  while (( tries < 15 )); do
    cexec sh -c "ip -4 addr show dev eth1 2>/dev/null | grep -qw '$ipbare'" && break
    sleep 1; tries=$((tries+1))
  done
  cexec sh -c "ip -4 addr show dev eth1 2>/dev/null | grep -qw '$ipbare'" \
    || die "Static LAN IP $PROXY_LAN_IP did not appear on eth1 (check systemd-networkd in the container)."
  ok "Proxy container up: eth0 on NAT, eth1 static $PROXY_LAN_IP on the LAN."

  # ---- Phase 3: install Caddy (with the Cloudflare DNS module) ----
  phase 3 "Install Caddy with the Cloudflare DNS module"
  pause
  cexec sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null'
  # The stock Caddy binary has no DNS providers; fetch a static build that bundles the
  # Cloudflare module from Caddy's official download API (dl.caddy has the plugin baked in).
  if ! cexec sh -c 'caddy version >/dev/null 2>&1 && caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare'; then
    cexec sh -c 'curl -fsSL -o /usr/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/cloudflare" && chmod +x /usr/bin/caddy'
    cexec sh -c 'caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare' \
      || die "Downloaded Caddy binary is missing the Cloudflare DNS module (dns.providers.cloudflare)."
  else
    log "Caddy with the Cloudflare DNS module already installed."
  fi
  ok "Caddy $(cexec caddy version | awk '{print $1}') installed (Cloudflare DNS module present)."

  # caddy system user + dirs + the standard systemd unit (with an EnvironmentFile for the token).
  cexec sh -c 'id -u caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy'
  cexec sh -c "install -d -o caddy -g caddy -m 750 /etc/caddy '$CONF_DIR' /var/lib/caddy"
  cwrite /etc/systemd/system/caddy.service 644 <<'EOF'
[Unit]
Description=Caddy reverse proxy (homelab ingress)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/caddy.env
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

  # ---- Phase 4: base config + secret + start ----
  phase 4 "Base Caddy config + token, then start"
  # Global options (ACME email) + import the per-service site files. Services add their
  # own <host>.caddy under conf.d and reload — this file rarely changes again.
  cexec sh -c "cat > /etc/caddy/Caddyfile" <<EOF
{
	email ${ACME_EMAIL}
}

# Per-service sites (one file per host, each with its own DNS-01 certificate).
import ${CONF_DIR}/*.caddy
EOF
  cexec chown caddy:caddy /etc/caddy/Caddyfile
  # The Cloudflare token — only here, mode 600, referenced by the unit's EnvironmentFile.
  printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN" | cwrite /etc/caddy/caddy.env 600
  cexec chown caddy:caddy /etc/caddy/caddy.env
  # An empty include is a Caddyfile error; drop a harmless placeholder until a real site exists.
  cexec sh -c "[ -n \"\$(ls -A '$CONF_DIR' 2>/dev/null)\" ] || printf '# Add services here: one <host>.caddy file per service.\n' > '$CONF_DIR/00-placeholder.caddy'"

  cexec systemctl daemon-reload
  cexec caddy validate --config /etc/caddy/Caddyfile >/dev/null \
    || die "caddy validate failed on the base config."
  cexec systemctl enable --now caddy >/dev/null 2>&1 || cexec systemctl restart caddy
  cexec systemctl is-active --quiet caddy || die "caddy service is not active (journalctl -u caddy inside the container)."
  ok "Caddy is running."

  # ---- finish ----
  echo
  ok "Reverse-proxy ingress installed."
  echo
  echo "${BLD}Next:${RST}"
  echo "  - This proxy is your single HTTPS entrypoint at ${BLD}${PROXY_LAN_IP%/*}${RST} on the LAN."
  echo "  - Point each service's DNS record (e.g. cloud.example.com) at ${PROXY_LAN_IP%/*}"
  echo "    as a ${BLD}DNS-only${RST} (grey-cloud) A record. DNS-01 issues a real cert with no open port."
  echo "  - Add a service by dropping a file in ${CONF_DIR} inside the container, then"
  echo "    'incus exec $PROXY_NAME -- systemctl reload caddy'. nextcloud-install.sh does this for you."
  echo "  - The Cloudflare token lives only in /etc/caddy/caddy.env (mode 600) in the container."
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
