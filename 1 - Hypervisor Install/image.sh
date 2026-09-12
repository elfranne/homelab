#!/usr/bin/env bash
#
# image.sh — build, deploy, update, and destroy Incus system-container images built
# with distrobuilder.
#
# This is the GENERIC, image-agnostic mechanism that belongs to the hypervisor layer.
# The per-image definitions are one distrobuilder YAML each, kept next to their service
# in ../2 - Containers/ (e.g. example.yaml). This script turns such a YAML into a
# versioned Incus image and manages its lifecycle:
#
#   build    <path/to/image.yaml>                         create/refresh the image
#   deploy   <alias> <instance> [-p profile …] [--volume <pool>/<vol>:<path>]
#                               [--config <key>=<value> …]
#   update   <alias> <instance>                           swap rootfs from a new image
#   destroy  <instance> [--image <alias>] [--volume <pool>/<vol>]
#   status                                                images / instances / volumes
#
# Root is needed ONLY at build time (distrobuilder does debootstrap/chroot); the
# container it produces still runs UNPRIVILEGED, exactly like the other step-1/2
# containers. Persistent state belongs on a --volume, so the image rootfs stays
# disposable: `update` rebuilds the rootfs from a fresh image via `incus rebuild` while
# keeping the instance's config and attached volumes.
#
# Per-instance settings belong in --config user.* keys rather than in the image: an image
# is shared by every instance built from it, while `user.*` keys survive a rebuild and can
# be read back by the Incus templates baked into the image (config_get). That is what lets
# an updated container regenerate its own configuration without re-running a provisioner.
#
# Run as a user in the incus-admin group (or root). Only the distrobuilder build (and,
# if needed, installing distrobuilder itself) uses sudo.
#
#   Usage:   ./image.sh <command> [args]
#            ./image.sh --help
#
set -Eeuo pipefail

# ---------- pretty output ----------
if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
else RED=""; GRN=""; YLW=""; BLU=""; BLD=""; RST=""; fi
log()  { echo "${BLU}[*]${RST} $*"; }
ok()   { echo "${GRN}[OK]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
die()  { echo "${RED}[ERROR]${RST} $*" >&2; exit 1; }

on_err() {
  local ec=$? ln=${BASH_LINENO[0]:-?}
  echo >&2
  echo "${RED}[FAIL]${RST} line ${ln}: exit ${ec} while running: ${BASH_COMMAND}" >&2
  exit "$ec"
}
trap on_err ERR

confirm() {
  local ans=""
  read -r -p "$1 [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
ct_exists() { incus info "$1" >/dev/null 2>&1; }
ct_running() { incus list "$1" -c ns -f csv 2>/dev/null | grep -qx "$1,RUNNING"; }
image_exists() { incus image info "$1" >/dev/null 2>&1; }

wait_for_ip() { # wait_for_ip INSTANCE -> prints first IPv4 on eth0 (or empty after ~60s)
  local tries=0 ip=""
  while (( tries < 30 )); do
    ip="$(incus exec "$1" -- sh -c "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    sleep 2; tries=$((tries+1))
  done
  return 0
}

alias_from_yaml() { local b; b="$(basename "$1")"; printf '%s' "${b%.*}"; }

ensure_distrobuilder() {
  if command -v distrobuilder >/dev/null 2>&1; then
    command -v debootstrap >/dev/null 2>&1 \
      || die "debootstrap is missing — sudo apt install debootstrap debian-archive-keyring"
    return 0
  fi
  warn "distrobuilder is not installed (it is not packaged in Debian main)."
  echo "  It can be installed by building it with Go into /usr/local/bin:"
  echo "    sudo apt install golang-go debootstrap debian-archive-keyring"
  echo "    sudo env GOBIN=/usr/local/bin go install github.com/lxc/distrobuilder/distrobuilder@latest"
  confirm "Do that now (installs a Go toolchain + distrobuilder on the host)?" \
    || die "distrobuilder is required to build images — install it and re-run."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y golang-go debootstrap debian-archive-keyring
  sudo env GOBIN=/usr/local/bin go install github.com/lxc/distrobuilder/distrobuilder@latest
  command -v distrobuilder >/dev/null 2>&1 \
    || die "distrobuilder still not on PATH after install — check /usr/local/bin and the go build output."
  ok "distrobuilder installed."
}

# ---------- commands ----------
cmd_build() {
  local yaml="${1:-}"
  [[ -n "$yaml" ]] || die "usage: image.sh build <path/to/image.yaml>"
  [[ -f "$yaml" ]] || die "No such image definition: $yaml"
  need_cmd incus
  need_cmd sudo
  ensure_distrobuilder

  local alias; alias="$(alias_from_yaml "$yaml")"
  local out; out="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$out'" RETURN

  log "Building image '${BLD}$alias${RST}' from $yaml (distrobuilder needs root)…"
  sudo distrobuilder build-incus "$yaml" "$out"
  sudo chown -R "$(id -u):$(id -g)" "$out"
  [[ -f "$out/incus.tar.xz" && -f "$out/rootfs.squashfs" ]] \
    || die "distrobuilder did not produce incus.tar.xz + rootfs.squashfs in $out."

  # Re-point the alias: delete the old image (instances already have their own copy, so
  # this is safe) then import the fresh one under the same alias.
  incus image delete "$alias" >/dev/null 2>&1 || true
  incus image import "$out/incus.tar.xz" "$out/rootfs.squashfs" --alias "$alias"
  ok "Image '$alias' built and imported. See 'incus image list'."
}

cmd_deploy() {
  local alias="" instance="" vol_spec=""
  local -a profiles=() configs=()
  while (( $# )); do
    case "$1" in
      -p|--profile) profiles+=("-p" "${2:?profile name}"); shift 2;;
      --volume)     vol_spec="${2:?<pool>/<vol>:<path>}"; shift 2;;
      --config)     configs+=("-c" "${2:?<key>=<value>}"); shift 2;;
      -*)           die "deploy: unknown option '$1'";;
      *) if   [[ -z "$alias"    ]]; then alias="$1"
         elif [[ -z "$instance" ]]; then instance="$1"
         else die "deploy: unexpected argument '$1'"; fi; shift;;
    esac
  done
  [[ -n "$alias" && -n "$instance" ]] \
    || die "usage: image.sh deploy <alias> <instance> [-p profile …] [--volume <pool>/<vol>:<path>] [--config <key>=<value> …]"
  need_cmd incus
  image_exists "$alias" || die "No image alias '$alias' — build it first (image.sh build …)."
  (( ${#profiles[@]} )) || profiles=("-p" "default")

  if ! ct_exists "$instance"; then
    incus init "$alias" "$instance" "${profiles[@]}" ${configs[@]+"${configs[@]}"}
    ok "Initialised '$instance' from image '$alias'."
  else
    warn "Instance '$instance' already exists — reusing it."
    # Re-apply the keys on an existing instance too, so deploy stays idempotent and a
    # changed answer takes effect on the next start (the templates re-render then).
    local kv
    for kv in ${configs[@]+"${configs[@]}"}; do
      [[ "$kv" == "-c" ]] && continue
      incus config set "$instance" "${kv%%=*}" "${kv#*=}"
    done
  fi

  if [[ -n "$vol_spec" ]]; then
    [[ "$vol_spec" == */*:* ]] || die "--volume must be <pool>/<vol>:<path>, e.g. default/demo-data:/srv/data"
    local pool="${vol_spec%%/*}" rest="${vol_spec#*/}"
    local vol="${rest%%:*}" path="${rest#*:}"
    incus storage volume list "$pool" -f csv 2>/dev/null | grep -q "^custom,${vol}," \
      || { incus storage volume create "$pool" "$vol" >/dev/null; ok "Created volume $pool/$vol."; }
    incus config device list "$instance" 2>/dev/null | grep -qx data \
      || { incus config device add "$instance" data disk pool="$pool" source="$vol" path="$path" >/dev/null; ok "Attached $pool/$vol at $path."; }
  fi

  ct_running "$instance" || incus start "$instance"
  local ip; ip="$(wait_for_ip "$instance")"
  ok "Deployed '$instance' (privileged: $(incus config get "$instance" security.privileged | grep -q true && echo yes || echo 'no — runs unprivileged'))."
  [[ -n "$ip" ]] && echo "  NAT IP: $ip   (e.g. curl http://$ip)"
}

cmd_update() {
  local alias="${1:-}" instance="${2:-}"
  [[ -n "$alias" && -n "$instance" ]] || die "usage: image.sh update <alias> <instance>"
  need_cmd incus
  ct_exists "$instance"  || die "No such instance: '$instance'."
  image_exists "$alias"  || die "No image alias '$alias' — build the new image first."

  # `incus rebuild` refuses outright on an instance that has snapshots. Catch it here so
  # the reason is obvious, rather than letting the ERR trap print a bare incus failure.
  # Snapshot the state VOLUME instead — that is where anything worth keeping lives:
  #   incus storage volume snapshot <pool> <volume>
  local snaps
  snaps="$(incus snapshot list "$instance" -f csv 2>/dev/null | wc -l)"
  (( snaps == 0 )) || die "Instance '$instance' has $snaps snapshot(s); 'incus rebuild' cannot run.
  Delete them (incus snapshot delete $instance <name>) and snapshot the state volume instead."

  ct_running "$instance" && { log "Stopping '$instance'…"; incus stop "$instance"; }
  log "Rebuilding '$instance' rootfs from image '$alias' (config + volumes are kept)…"
  incus rebuild "$alias" "$instance"
  incus start "$instance"
  ok "Updated '$instance': rootfs is fresh from '$alias'; attached volumes and config preserved."
}

cmd_destroy() {
  local instance="" image_alias="" vol_spec=""
  while (( $# )); do
    case "$1" in
      --image)  image_alias="${2:?alias}"; shift 2;;
      --volume) vol_spec="${2:?<pool>/<vol>}"; shift 2;;
      -*)       die "destroy: unknown option '$1'";;
      *) [[ -z "$instance" ]] && instance="$1" || die "destroy: unexpected argument '$1'"; shift;;
    esac
  done
  [[ -n "$instance" ]] || die "usage: image.sh destroy <instance> [--image <alias>] [--volume <pool>/<vol>]"
  need_cmd incus

  if ct_exists "$instance"; then incus delete -f "$instance"; ok "Deleted instance '$instance'."
  else warn "Instance '$instance' not found."; fi

  if [[ -n "$vol_spec" ]]; then
    local pool="${vol_spec%%/*}" vol="${vol_spec#*/}"
    if incus storage volume delete "$pool" "$vol" >/dev/null 2>&1; then ok "Deleted volume $pool/$vol."
    else warn "Volume '$vol' not found in pool '$pool'."; fi
  fi
  if [[ -n "$image_alias" ]]; then
    if incus image delete "$image_alias" >/dev/null 2>&1; then ok "Deleted image '$image_alias'."
    else warn "Image '$image_alias' not found."; fi
  fi
}

cmd_status() {
  need_cmd incus
  echo "${BLD}== Images ==${RST}";                 incus image list
  echo; echo "${BLD}== Instances ==${RST}";        incus list
  echo; echo "${BLD}== Custom volumes (default pool) ==${RST}"; incus storage volume list default
}

usage() {
  sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    build)     cmd_build    "$@";;
    deploy)    cmd_deploy   "$@";;
    update)    cmd_update   "$@";;
    destroy)   cmd_destroy  "$@";;
    status)    cmd_status   "$@";;
    --help|-h|"") usage;;
    *)         die "Unknown command: '$cmd' (use --help)";;
  esac
}
main "$@"
