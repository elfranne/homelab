#!/usr/bin/env bash
#
# nextcloud-install.sh — Nextcloud as a native Incus system container, behind the
# step-2 Caddy reverse proxy.
#
# Creates ONE private container on the NAT bridge (never on the LAN) running the plain
# Debian stack — nginx + PHP-FPM + PostgreSQL + Redis + the Nextcloud PHP app — with the
# user data on its OWN Incus custom ZFS volume (independent snapshots; inherits the
# pool's encryption). It then registers the site with the Caddy proxy created by
# reverse-proxy-install.sh, which terminates TLS with a real Let's Encrypt certificate
# (DNS-01 via Cloudflare) — so nothing here opens an inbound port.
#
# Layout:
#     LAN client ─▶ cloud.<domain> (DNS ─▶ proxy LAN IP) ─▶ Caddy (TLS)
#                     ─▶ http://<this container, NAT>:80  ─▶ nginx ─▶ PHP-FPM ─▶ Nextcloud
#
# Interactive, fail-fast, idempotent. Run it AFTER reverse-proxy-install.sh, from the
# box (or anywhere `incus` reaches this server) as a user in the incus-admin group (or
# root). It only talks to Incus and the containers — it changes nothing on the host.
#
#   Usage:   ./nextcloud-install.sh
#            ./nextcloud-install.sh --help
#
#   All settings are prompted at the start; the CONFIG values below are only the defaults
#   pre-filled at each prompt. The admin and database passwords are never stored in this
#   script — the admin password is prompted (hidden) and the DB password is generated.
#
set -Eeuo pipefail

####################  CONFIG — DEFAULTS (prompted interactively)  ####################
NC_NAME="nextcloud"            # Incus container name
NC_IMAGE="images:debian/13"    # base image
NC_DOMAIN=""                   # public hostname, e.g. cloud.example.com (prompted)
NC_ADMIN_USER="admin"          # Nextcloud admin account to create
NC_DATA_VOLUME="nextcloud-data" # Incus custom volume (on the 'default' pool) for user data
NC_PHONE_REGION="DK"           # default_phone_region (ISO 3166-1 alpha-2)

STORAGE_POOL="default"         # Incus storage pool created in step 1
PROXY_NAME="proxy"             # the reverse-proxy container from reverse-proxy-install.sh
PROXY_CONF_DIR="/etc/caddy/conf.d"  # where the proxy imports per-service site files

DB_NAME="nextcloud"
DB_USER="nextcloud"

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

cexec() { incus exec "$NC_NAME" -- "$@"; }                   # run in the nextcloud container
occ()   { incus exec "$NC_NAME" -- runuser -u www-data -- php /var/www/nextcloud/occ "$@"; }

ct_exists() { incus info "$1" >/dev/null 2>&1; }
ct_running() { [[ "$(incus list "$1" -c s -f csv 2>/dev/null)" == "RUNNING" ]]; }

ct_ip() { # ct_ip CONTAINER DEV  — first IPv4 on DEV, or empty
  incus exec "$1" -- sh -c "ip -4 -o addr show dev '$2' 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true
}
wait_for_ip() { # wait_for_ip CONTAINER DEV -> prints the IP or dies
  local tries=0 ip=""
  while (( tries < 30 )); do
    ip="$(ct_ip "$1" "$2")"; [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    sleep 2; tries=$((tries+1))
  done
  die "Container '$1' did not get an IPv4 on '$2' within ~60s."
}
wait_for_net() {
  local tries=0
  while (( tries < 30 )); do
    cexec sh -c 'getent hosts deb.debian.org >/dev/null 2>&1' && return 0
    sleep 2; tries=$((tries+1))
  done
  die "Container '$NC_NAME' has no working network/DNS after ~60s."
}
gen_secret() { openssl rand -hex 24 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c48; }

# =====================================================================================
run() {
  echo "${BLD}Nextcloud installer — native Incus container behind the Caddy proxy${RST}"

  # ---- Phase 0: preflight ----
  phase 0 "Preflight checks"
  need_cmd incus
  incus info >/dev/null 2>&1 || die "'incus info' failed — Incus (step 1) not reachable, or you're not in incus-admin/root."
  incus storage list -f csv 2>/dev/null | grep -q "^${STORAGE_POOL}," \
    || die "Incus storage pool '$STORAGE_POOL' missing — run step 1 (incus-install.sh) first."
  ct_exists "$PROXY_NAME" \
    || die "Proxy container '$PROXY_NAME' not found — run reverse-proxy-install.sh first."
  incus exec "$PROXY_NAME" -- systemctl is-active --quiet caddy \
    || die "Caddy is not running in '$PROXY_NAME' — fix reverse-proxy-install.sh before adding a service."
  local PROXY_NAT_IP; PROXY_NAT_IP="$(ct_ip "$PROXY_NAME" eth0)"
  [[ -n "$PROXY_NAT_IP" ]] || die "Could not read the proxy's NAT (eth0) IP — is '$PROXY_NAME' running?"
  ok "Incus reachable; proxy '$PROXY_NAME' up (NAT IP $PROXY_NAT_IP), Caddy active."

  if ct_exists "$NC_NAME" && incus exec "$NC_NAME" -- test -f /var/www/nextcloud/occ 2>/dev/null \
     && occ status 2>/dev/null | grep -q 'installed: true'; then
    warn "Nextcloud already installed in '$NC_NAME' — re-applying config + proxy registration only (idempotent)."
  fi

  # ---- Phase 1: settings ----
  phase 1 "Settings"
  while :; do
    if [[ -n "$NC_DOMAIN" ]]; then
      read -r -p "Public hostname for Nextcloud (e.g. cloud.example.com) [${NC_DOMAIN}]: " _in </dev/tty || _in=""
      _in="${_in:-$NC_DOMAIN}"
    else
      read -r -p "Public hostname for Nextcloud (e.g. cloud.example.com): " _in </dev/tty || _in=""
    fi
    [[ "$_in" == *.*.* || "$_in" == *.* ]] && { NC_DOMAIN="$_in"; break; }
    warn "Enter a fully-qualified hostname, e.g. cloud.example.com."
  done
  read -r -p "Nextcloud admin username [${NC_ADMIN_USER}]: " _in </dev/tty || _in=""
  NC_ADMIN_USER="${_in:-$NC_ADMIN_USER}"
  read -r -p "Default phone region (ISO 3166-1 alpha-2) [${NC_PHONE_REGION}]: " _in </dev/tty || _in=""
  NC_PHONE_REGION="${_in:-$NC_PHONE_REGION}"

  # Admin password (hidden, confirmed) — only needed for a fresh install.
  local NC_ADMIN_PASS=""
  local fresh_install=1
  if ct_exists "$NC_NAME" && incus exec "$NC_NAME" -- test -f /var/www/nextcloud/occ 2>/dev/null \
     && occ status 2>/dev/null | grep -q 'installed: true'; then
    fresh_install=0
  fi
  if (( fresh_install )); then
    while :; do
      read -rs -p "Nextcloud admin password: " NC_ADMIN_PASS </dev/tty || NC_ADMIN_PASS=""; echo
      local pw2=""; read -rs -p "Repeat admin password: " pw2 </dev/tty || pw2=""; echo
      [[ -n "$NC_ADMIN_PASS" && "$NC_ADMIN_PASS" == "$pw2" && ${#NC_ADMIN_PASS} -ge 8 ]] && break
      warn "Passwords must match and be at least 8 characters."
    done
  fi

  echo
  echo "Settings:"
  printf '  %-16s %s\n' "Container:"    "$NC_NAME ($NC_IMAGE), NAT only"
  printf '  %-16s %s\n' "Hostname:"     "$NC_DOMAIN"
  printf '  %-16s %s\n' "Admin user:"   "$NC_ADMIN_USER"
  printf '  %-16s %s\n' "Data volume:"  "$STORAGE_POOL/$NC_DATA_VOLUME (Incus custom ZFS volume)"
  printf '  %-16s %s\n' "Database:"     "PostgreSQL ($DB_NAME / $DB_USER)"
  printf '  %-16s %s\n' "Proxy:"        "$NC_NAME → Caddy '$PROXY_NAME' ($PROXY_CONF_DIR/${NC_DOMAIN}.caddy)"
  printf '  %-16s %s\n' "Phone region:" "$NC_PHONE_REGION"
  require_yes "Proceed with these settings?"

  # ---- Phase 2: container + data volume ----
  phase 2 "Create the container and data volume"
  pause
  if ! ct_exists "$NC_NAME"; then
    incus launch "$NC_IMAGE" "$NC_NAME" -p default
  else
    ct_running "$NC_NAME" || incus start "$NC_NAME"
  fi
  # Dedicated custom volume for user data (own snapshots, inherits pool encryption).
  if ! incus storage volume list "$STORAGE_POOL" -f csv 2>/dev/null | grep -q "^custom,${NC_DATA_VOLUME},"; then
    incus storage volume create "$STORAGE_POOL" "$NC_DATA_VOLUME" >/dev/null
    ok "Created custom volume $STORAGE_POOL/$NC_DATA_VOLUME."
  else
    log "Custom volume $STORAGE_POOL/$NC_DATA_VOLUME already exists."
  fi
  if ! incus config device list "$NC_NAME" 2>/dev/null | grep -qx ncdata; then
    incus config device add "$NC_NAME" ncdata disk \
      pool="$STORAGE_POOL" source="$NC_DATA_VOLUME" path=/var/www/nextcloud/data >/dev/null
    ok "Attached data volume at /var/www/nextcloud/data."
  else
    log "Data device already attached."
  fi
  local NC_NAT_IP; NC_NAT_IP="$(wait_for_ip "$NC_NAME" eth0)"
  wait_for_net
  ok "Container up (NAT IP $NC_NAT_IP), network reachable."

  # ---- Phase 3: install the stack ----
  phase 3 "Install nginx + PHP-FPM + PostgreSQL + Redis"
  pause
  cexec sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq \
    nginx postgresql redis-server curl ca-certificates bzip2 \
    php-fpm php-gd php-mbstring php-xml php-zip php-curl php-intl php-bcmath php-gmp \
    php-pgsql php-apcu php-redis php-imagick imagemagick php-bz2 >/dev/null'
  local PHPV; PHPV="$(cexec sh -c 'ls -1 /etc/php 2>/dev/null | sort -V | tail -1')"
  [[ -n "$PHPV" ]] || die "Could not determine the installed PHP version (no /etc/php/<ver>)."
  local SOCK="/run/php/php${PHPV}-fpm.sock"
  ok "Stack installed (PHP $PHPV, FPM socket $SOCK)."

  # PHP tuning for both FPM and CLI (occ/cron): memory, uploads, OPcache, APCu on CLI.
  local phpini
  for phpini in "/etc/php/${PHPV}/fpm/conf.d/90-nextcloud.ini" "/etc/php/${PHPV}/cli/conf.d/90-nextcloud.ini"; do
    cexec sh -c "cat > '$phpini'" <<'PHPINI'
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 3600
apc.enable_cli = 1
opcache.enable = 1
opcache.enable_cli = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 60
PHPINI
  done

  # PostgreSQL role + database (idempotent).
  local DB_PASS
  if (( fresh_install )); then
    DB_PASS="$(gen_secret)"
    cexec runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END \$\$;
SQL
    if ! cexec runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
      cexec runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"
    fi
    ok "PostgreSQL role '$DB_USER' + database '$DB_NAME' ready."
  fi

  # ---- Phase 4: deploy Nextcloud ----
  phase 4 "Deploy the Nextcloud release"
  if ! cexec test -f /var/www/nextcloud/occ 2>/dev/null; then
    # Download the current release + its checksum, verify by hash (the .sha256 filename
    # differs from latest.tar.bz2, so compare digests rather than `sha256sum -c`).
    cexec sh -c 'cd /var/www && curl -fSL -o nextcloud.tar.bz2 https://download.nextcloud.com/server/releases/latest.tar.bz2 \
      && curl -fSL -o nextcloud.sha256 https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256'
    cexec sh -c 'cd /var/www && exp=$(awk "{print \$1}" nextcloud.sha256) && act=$(sha256sum nextcloud.tar.bz2 | awk "{print \$1}") \
      && [ -n "$exp" ] && [ "$exp" = "$act" ] || { echo "checksum mismatch (exp=$exp act=$act)"; exit 1; }'
    cexec sh -c 'cd /var/www && tar -xjf nextcloud.tar.bz2 && rm -f nextcloud.tar.bz2 nextcloud.sha256'
    ok "Nextcloud unpacked to /var/www/nextcloud."
  else
    log "Nextcloud code already present at /var/www/nextcloud."
  fi
  cexec chown -R www-data:www-data /var/www/nextcloud

  # nginx vhost (plain HTTP :80 — TLS is the proxy's job). Official Nextcloud config,
  # with the FPM socket + server_name substituted.
  render_nginx | sed -e "s|__DOMAIN__|${NC_DOMAIN}|g" -e "s|__SOCK__|${SOCK}|g" \
    | cexec sh -c 'cat > /etc/nginx/sites-available/nextcloud'
  cexec ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
  cexec rm -f /etc/nginx/sites-enabled/default
  cexec nginx -t
  cexec systemctl restart "php${PHPV}-fpm" nginx
  ok "nginx + PHP-FPM configured and restarted."

  # ---- Phase 5: occ install + reverse-proxy config + cron ----
  phase 5 "Install Nextcloud (occ) and configure it"
  if (( fresh_install )); then
    occ maintenance:install \
      --database pgsql --database-name "$DB_NAME" --database-user "$DB_USER" \
      --database-pass "$DB_PASS" --database-host localhost \
      --admin-user "$NC_ADMIN_USER" --admin-pass "$NC_ADMIN_PASS" \
      --data-dir /var/www/nextcloud/data
    ok "Nextcloud core installed."
  fi

  # Trusted domain + reverse-proxy awareness (Caddy terminates TLS; nginx sees HTTP).
  occ config:system:set trusted_domains 1 --value="$NC_DOMAIN"
  occ config:system:set overwrite.cli.url --value="https://${NC_DOMAIN}"
  occ config:system:set overwriteprotocol --value=https
  occ config:system:set overwritehost --value="$NC_DOMAIN"
  occ config:system:set trusted_proxies 0 --value="$PROXY_NAT_IP"
  # Redis (locking + distributed) + APCu (local) caching.
  occ config:system:set memcache.local --value='\OC\Memcache\APCu'
  occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
  occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
  occ config:system:set redis host --value=localhost
  occ config:system:set redis port --value=6379 --type=integer
  # Maintenance window (1 = 01:00–05:00 UTC) + phone region (clears admin warnings).
  occ config:system:set maintenance_window_start --type=integer --value=1
  occ config:system:set default_phone_region --value="$NC_PHONE_REGION"
  ok "Reverse-proxy + caching + regional config applied."

  # Background jobs via a systemd timer running cron.php every 5 minutes.
  cexec sh -c 'cat > /etc/systemd/system/nextcloudcron.service' <<'UNIT'
[Unit]
Description=Nextcloud cron.php
After=network-online.target
[Service]
User=www-data
ExecStart=/usr/bin/php -f /var/www/nextcloud/cron.php
UNIT
  cexec sh -c 'cat > /etc/systemd/system/nextcloudcron.timer' <<'UNIT'
[Unit]
Description=Run Nextcloud cron.php every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=nextcloudcron.service
[Install]
WantedBy=timers.target
UNIT
  cexec systemctl daemon-reload
  cexec systemctl enable --now nextcloudcron.timer >/dev/null 2>&1 || cexec systemctl restart nextcloudcron.timer
  occ background:cron
  ok "Background cron (systemd timer, every 5 min) enabled."

  # ---- Phase 6: register with the Caddy proxy ----
  phase 6 "Register the site with the Caddy proxy"
  render_caddy_site | sed -e "s|__DOMAIN__|${NC_DOMAIN}|g" -e "s|__TARGET__|${NC_NAT_IP}:80|g" \
    | incus exec "$PROXY_NAME" -- sh -c "umask 022; cat > '${PROXY_CONF_DIR}/${NC_DOMAIN}.caddy' && chown caddy:caddy '${PROXY_CONF_DIR}/${NC_DOMAIN}.caddy'"
  incus exec "$PROXY_NAME" -- rm -f "${PROXY_CONF_DIR}/00-placeholder.caddy"
  incus exec "$PROXY_NAME" -- caddy validate --config /etc/caddy/Caddyfile >/dev/null \
    || die "Caddy config invalid after adding ${NC_DOMAIN}.caddy — check the site file in '$PROXY_NAME'."
  incus exec "$PROXY_NAME" -- systemctl reload caddy
  ok "Proxy now serves https://${NC_DOMAIN} → ${NC_NAT_IP}:80 (its own DNS-01 certificate)."

  # ---- finish ----
  echo
  occ status || true
  echo
  ok "Nextcloud installed."
  echo
  echo "${BLD}Next:${RST}"
  local PROXY_LAN_IP; PROXY_LAN_IP="$(ct_ip "$PROXY_NAME" eth1)"
  echo "  1. Create the DNS record:  ${BLD}${NC_DOMAIN}  A  ${PROXY_LAN_IP:-<proxy LAN IP>}${RST}  (DNS-only / grey-cloud)."
  echo "  2. Browse to  ${BLD}https://${NC_DOMAIN}${RST}  and log in as '${NC_ADMIN_USER}'."
  echo "  3. First hit may take a few seconds while Caddy fetches the certificate (DNS-01)."
  echo "  4. Check Settings → Administration → Overview for a clean bill of health."
  echo "  -  Data lives on the Incus volume ${STORAGE_POOL}/${NC_DATA_VOLUME}; snapshot it with:"
  echo "       incus storage volume snapshot ${STORAGE_POOL} ${NC_DATA_VOLUME}"
  echo "  -  Note: the proxy target is pinned to ${NC_NAT_IP}. If you ever rebuild '$NC_NAME'"
  echo "     and its NAT IP changes, re-run this script to refresh the proxy site file."
}

# The official Nextcloud nginx configuration (plain HTTP :80). Placeholders __DOMAIN__
# and __SOCK__ are substituted by the caller. Emitted via a quoted heredoc so the many
# $nginx_variables stay literal.
render_nginx() {
  cat <<'NGINX'
upstream php-handler {
    server unix:__SOCK__;
}

map $arg_v $asset_immutable {
    "" "";
    default ", immutable";
}

server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    root /var/www/nextcloud;
    index index.php index.html /index.php$request_uri;

    client_max_body_size 512M;
    client_body_timeout 300s;
    fastcgi_buffers 64 4K;
    fastcgi_hide_header X-Powered-By;

    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml text/javascript application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    location = /robots.txt { allow all; log_not_found off; access_log off; }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation    { try_files $uri $uri/ =404; }
        return 301 /index.php$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)               { return 404; }

    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_max_temp_file_size 0;
    }

    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|jpeg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463$asset_immutable";
        access_log off;
        location ~ \.wasm$ { default_type application/wasm; }
    }
    location ~ \.woff2?$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }

    location /remote { return 301 /remote.php$request_uri; }

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
}
NGINX
}

# The per-service Caddy site file. Placeholders __DOMAIN__ and __TARGET__ substituted by
# the caller; emitted via a quoted heredoc so {env.CF_API_TOKEN} stays literal.
render_caddy_site() {
  cat <<'CADDY'
__DOMAIN__ {
	tls {
		dns cloudflare {env.CF_API_TOKEN}
	}
	encode zstd gzip
	header Strict-Transport-Security "max-age=15552000; includeSubDomains"
	reverse_proxy __TARGET__
}
CADDY
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
