#!/usr/bin/env bash
#
# zbm-install.sh — Debian Trixie on encrypted root-on-ZFS (3+ disks, raidz1)
#                  with ZFSBootMenu + remote SSH unlock (dropbear).
#
# Interactive, fail-fast installer. Run from a Debian Trixie LIVE USB (UEFI).
# It runs Stage 1 in the live environment, then copies itself into the new
# system and re-runs Stage 2 inside the chroot automatically.
#
#   Usage:   sudo ./zbm-install.sh            # normal run
#            sudo ASSUME_YES=1 ./zbm-install.sh   # skip per-phase pauses (wipe gate still prompts)
#            ./zbm-install.sh --help
#
#   All settings are prompted interactively at the start of the run; the values
#   in the CONFIG block below are only the defaults pre-filled at each prompt, so
#   editing them is optional. You DO need to place your SSH PUBLIC key (a *.pub
#   file) in the directory you run this from — the script reads it, shows it, and
#   asks you to confirm. It is installed for ZFSBootMenu remote unlock.
#e
# WARNING: This ERASES the three configured disks completely.
#
set -Eeuo pipefail

####################  CONFIG — DEFAULTS (prompted interactively)  ####################
# Every value below is only a DEFAULT: at the start of the run the script prompts
# for each one with the value here pre-filled in [brackets], so you can just press
# Enter to accept it or type a replacement. Editing this block changes the defaults;
# it is not required.
#
# Disks: NOT set here. The script lists the disks it detects and asks you to pick
# which ones to use (minimum 3, for raidz1). The 'p' partition suffix for NVMe is
# handled automatically.

# Hostname and admin username are prompted interactively at the start of the run.
TIMEZONE="Etc/UTC"              # e.g. "Europe/Copenhagen"
KEYMAP="dk"                     # console keymap: installed OS's TTY (via /etc/vconsole.conf
                                 # AND /etc/default/keyboard) *and* baked into the
                                 # ZFSBootMenu image (via dracut's i18n module) so the
                                 # passphrase prompt on the local console matches your
                                 # physical keyboard. Must be a vconsole keymap name
                                 # (validated at runtime against 'localectl list-keymaps'),
                                 # e.g. "us", "dk", "de", "uk"; this equals the X11 layout
                                 # code for most layouts.

POOL_NAME="zroot"
EFI_SIZE="+1g"                  # per-disk EFI partition size

COMPRESSION="zstd"
ENCRYPTION_ALG="aes-256-gcm"
ZPOOL_COMPAT="openzfs-2.2-linux"
ARC_MAX_BYTES=""                # empty = no cap (ZFS default: up to ~50% of RAM). Set a byte value to cap it.

# Remote unlock (ZFSBootMenu dropbear)
DROPBEAR_PORT="222"
# Networking is NOT set here. ZFSBootMenu's remote unlock only has a static
# IP available this early in boot, so the script detects the NIC with an
# active link and interactively prompts for IP/gateway/netmask, confirming
# before proceeding.

# Pinned boot components (frozen for reproducible, known-good boot images).
# dracut-crypt-ssh is only lightly maintained, so it is pinned to an exact commit;
# bump these deliberately after testing, not automatically.
ZBM_VERSION="v3.1.0"            # ZFSBootMenu release tag: github.com/zbm-dev/zfsbootmenu/releases
CRYPT_SSH_COMMIT="17b567750fd28e50f22dec999acf4f8d3688d5bf"  # dracut-crypt-ssh, tag v1.0.8

# Remote-unlock SSH key: the script reads an SSH PUBLIC key (*.pub) from the
# directory you run it in, shows it, and asks you to confirm. Nothing to set here.

ASSUME_YES="${ASSUME_YES:-0}"   # 1 = skip per-phase pauses (wipe gate always prompts)
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
  echo "${RED}Aborting. System is in a PARTIAL state — review before re-running.${RST}" >&2
  exit "$ec"
}
trap on_err ERR

# ---------- interaction ----------
confirm() { # confirm "prompt"   -> 0 if yes (used for genuinely optional yes/no choices)
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans=""
  read -r -p "$1 [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
require_yes() { # ask until the user answers yes; never returns non-zero — Ctrl-C to abort
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans=""
  while :; do
    read -r -p "$1 [y/N] " ans </dev/tty || ans=""
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] && return 0
    warn "Not confirmed — type 'y' to proceed, or press Ctrl-C to abort."
  done
}
pause() { # gate before a phase: wait for Enter (Ctrl-C to abort)
  [[ "$ASSUME_YES" == "1" ]] && return 0
  read -r -p "${1:-Press Enter to continue (Ctrl-C to abort)…}" _ </dev/tty || true
}

set_password() { # set_password USER — retry passwd instead of aborting the install on a typo
  local u="$1" tries=0
  until passwd "$u" </dev/tty; do
    tries=$((tries+1))
    (( tries < 5 )) || die "Failed to set password for '$u' after 5 attempts."
    warn "Password not set for '$u' — try again."
  done
}

# ---------- helpers ----------
part() { # part DISK N  -> partition device path
  # Devices whose name ends in a digit (nvme0n1, mmcblk0, loop0, nbd0) need a 'p'
  # separator before the partition number; classic sdX / vdX names do not.
  local d="$1" n="$2"
  if [[ "$d" =~ [0-9]$ ]]; then echo "${d}p${n}"; else echo "${d}${n}"; fi
}
assert_block() { [[ -b "$1" ]] || die "Expected block device not found: $1"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

find_pubkey() { # discover an SSH *.pub in the current directory, confirm, set global SSH_PUBKEY
  local dir="$PWD" f key chosen="" sel="" fp
  local -a candidates=()
  shopt -s nullglob
  for f in "$dir"/*.pub; do candidates+=("$f"); done
  shopt -u nullglob
  [[ ${#candidates[@]} -gt 0 ]] || die "No *.pub SSH public key found in current directory ($dir). Put one there and re-run."

  if [[ ${#candidates[@]} -eq 1 ]]; then
    chosen="${candidates[0]}"
  elif [[ "$ASSUME_YES" == "1" ]]; then
    die "Multiple *.pub files in $dir; leave exactly one (or run without ASSUME_YES to choose)."
  else
    echo "Multiple public keys found in $dir:"
    local i
    for i in "${!candidates[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${candidates[$i]##*/}"; done
    while :; do
      read -r -p "Select key [1-${#candidates[@]}]: " sel </dev/tty || sel=""
      [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#candidates[@]} )) && break
      warn "Enter a number between 1 and ${#candidates[@]}."
    done
    chosen="${candidates[$((sel-1))]}"
  fi

  # take the first recognizable public-key line from the file
  key="$(tr -d '\r' < "$chosen" | grep -m1 -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)' || true)"
  [[ -n "$key" ]] || die "$chosen does not contain a recognizable SSH public key."

  echo
  echo "Public key to authorize for ZFSBootMenu remote unlock:"
  echo "  file: $chosen"
  echo "  key : $key"
  if command -v ssh-keygen >/dev/null 2>&1; then
    fp="$(ssh-keygen -lf "$chosen" 2>/dev/null | head -n1 || true)"
    [[ -n "$fp" ]] && echo "  fp  : $fp"
  fi
  echo
  require_yes "Authorize THIS key for remote unlock?"
  SSH_PUBKEY="$key"
}

live_disk() { # best-effort: print the whole-disk device backing the live medium, else nothing
  local m src pk
  for m in /run/live/medium /lib/live/mount/medium /run/initramfs/live /cdrom; do
    mountpoint -q "$m" 2>/dev/null || continue
    src="$(findmnt -no SOURCE "$m" 2>/dev/null)" || true
    [[ -n "$src" ]] || continue
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null | grep -m1 . || true)"
    [[ -n "$pk" ]] && { printf '/dev/%s' "$pk"; return 0; }
  done
  return 0
}

detect_disks() { # populate global CANDIDATES with whole-disk device paths (type 'disk'), excluding the live USB
  CANDIDATES=()
  LIVE_DISK="$(live_disk)"   # global: the whole-disk device backing the live medium, if found
  local name type
  while read -r name type; do
    [[ "$type" == "disk" ]] || continue
    case "$name" in
      /dev/zram*|/dev/loop*|/dev/sr*|/dev/md*|/dev/dm-*|/dev/ram*|/dev/fd*) continue ;;
    esac
    # never offer the live USB as an install target (so 'all' can't select it either)
    [[ -n "$LIVE_DISK" && "$name" == "$LIVE_DISK" ]] && continue
    CANDIDATES+=("$name")
  done < <(lsblk -dpno NAME,TYPE)
}

select_disks() { # list detected disks, let the user pick (>=3), confirm; set global DISKS
  detect_disks
  [[ ${#CANDIDATES[@]} -gt 0 ]] || die "No installable whole disks detected (lsblk reported none of type 'disk', excluding the live USB)."
  [[ -n "$LIVE_DISK" ]] && log "Excluding live USB ($LIVE_DISK) from the disk list."

  echo "Disks detected on this machine:"
  local i dev info
  for i in "${!CANDIDATES[@]}"; do
    dev="${CANDIDATES[$i]}"
    info="$(lsblk -dpno SIZE,TRAN,MODEL "$dev" 2>/dev/null | sed 's/  */ /g; s/^ //; s/ $//')"
    printf '  [%d] %-16s %s\n' "$((i+1))" "$dev" "$info"
  done
  echo
  echo "raidz1 needs at least 3 disks and survives a single disk failure."

  local input picks=() d n
  while :; do
    read -r -p "Enter the disk numbers to use (e.g. '1 2 3'), or 'all' [all]: " input </dev/tty || input=""
    input="${input:-all}"
    picks=()
    if [[ "$input" == "all" ]]; then
      picks=("${CANDIDATES[@]}")
    else
      local toks bad=0 t
      read -ra toks <<< "${input//,/ }"
      for t in "${toks[@]}"; do
        if [[ "$t" =~ ^[0-9]+$ ]] && (( t>=1 && t<=${#CANDIDATES[@]} )); then
          picks+=("${CANDIDATES[$((t-1))]}")
        else
          warn "Invalid entry: '$t'"; bad=1; break
        fi
      done
      [[ "$bad" == "0" ]] || continue
    fi
    # de-duplicate, preserving order
    local -A seen=(); local uniq=()
    for d in "${picks[@]}"; do [[ -n "${seen[$d]:-}" ]] || { uniq+=("$d"); seen["$d"]=1; }; done
    picks=("${uniq[@]}"); n=${#picks[@]}
    (( n>=3 )) || { warn "Select at least 3 disks (you chose $n)."; continue; }
    break
  done

  echo
  echo "${BLD}These disks will form the encrypted raidz1 pool — ALL DATA ON THEM WILL BE ERASED:${RST}"
  for d in "${picks[@]}"; do
    printf '   - %-16s %s\n' "$d" "$(lsblk -dpno SIZE,MODEL "$d" 2>/dev/null | sed 's/  */ /g; s/^ //')"
  done
  echo
  require_yes "Use these $n disks?"
  DISKS=("${picks[@]}")
}

detect_ifaces() { # populate global IFACES with candidate NIC names (excludes virtual/loopback)
  IFACES=()
  local name
  while read -r name; do
    name="${name%%@*}"   # strip "@ifN" suffix ip -o link show adds for some virtual types
    case "$name" in
      lo|veth*|docker*|br-*|virbr*|tun*|tap*|wg*|zt*|tailscale*|bond*|dummy*) continue ;;
    esac
    IFACES+=("$name")
  done < <(ip -o link show | awk -F': ' '{print $2}')
}

iface_has_link() { # iface_has_link NAME -> 0 if an active carrier is detected
  local c; c="$(cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0)"
  [[ "$c" == "1" ]]
}

iface_ipv4() { # iface_ipv4 NAME -> first IPv4/prefix assigned, or empty
  ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1
}

prefix_to_netmask() { # prefix_to_netmask N -> dotted-quad mask for CIDR prefix N (0-32), or empty
  local p="$1" i octet=() ; [[ "$p" =~ ^[0-9]+$ ]] && (( p<=32 )) || return 1
  for i in 0 1 2 3; do
    if   (( p >= 8 )); then octet+=(255); p=$((p-8))
    elif (( p >  0 )); then octet+=($(( 256 - 2**(8-p) ))); p=0
    else                    octet+=(0); fi
  done
  local IFS=.; echo "${octet[*]}"
}

netmask_to_prefix() { # netmask_to_prefix DOTTED -> CIDR prefix length (bit count), or empty
  local m="$1" a b c d o bits=0
  valid_ipv4 "$m" || return 1
  IFS=. read -r a b c d <<<"$m"
  for o in "$a" "$b" "$c" "$d"; do
    while (( o )); do bits=$(( bits + (o & 1) )); o=$(( o >> 1 )); done
  done
  echo "$bits"
}

valid_netmask() { # valid_netmask DOTTED -> 0 if a contiguous IPv4 subnet mask (255.255.255.0, not 255.255.0.255)
  local m="$1" a b c d val host
  valid_ipv4 "$m" || return 1
  IFS=. read -r a b c d <<<"$m"
  val=$(( (a<<24) | (b<<16) | (c<<8) | d ))
  # A valid mask is a run of high 1-bits then low 0-bits, so the host part
  # (inverted mask) must be all-ones in its low bits: host & (host+1) == 0.
  host=$(( (~val) & 0xFFFFFFFF ))
  (( (host & (host + 1)) == 0 ))
}

select_iface() { # list NICs, prefer one with an active link, confirm; sets global NET_IFACE
  detect_ifaces
  [[ ${#IFACES[@]} -gt 0 ]] || die "No network interfaces detected (ip link show reported none)."

  echo "Network interfaces detected on this machine:"
  local i dev link ip4 default=""
  for i in "${!IFACES[@]}"; do
    dev="${IFACES[$i]}"
    if iface_has_link "$dev"; then link="UP"; [[ -z "$default" ]] && default="$dev"; else link="down"; fi
    ip4="$(iface_ipv4 "$dev")"
    printf '  [%d] %-10s link:%-4s %s\n' "$((i+1))" "$dev" "$link" "${ip4:-no address}"
  done
  echo

  local input sel=""
  if [[ -n "$default" ]]; then
    read -r -p "Interface for ZFSBootMenu remote-unlock networking [${default}]: " input </dev/tty || input=""
    input="${input:-$default}"
  else
    warn "No interface with an active link detected — pick one manually."
    read -r -p "Interface for ZFSBootMenu remote-unlock networking: " input </dev/tty || input=""
  fi

  # accept either a list index or a literal interface name
  if [[ "$input" =~ ^[0-9]+$ ]] && (( input>=1 && input<=${#IFACES[@]} )); then
    sel="${IFACES[$((input-1))]}"
  else
    sel="$input"
  fi
  [[ -n "$sel" && -d "/sys/class/net/$sel" ]] || die "Unknown interface: '${input:-<empty>}'"

  require_yes "Use interface '$sel' for ZFSBootMenu remote-unlock networking?"
  NET_IFACE="$sel"
  # Record the MAC so downstream config can match the NIC by hardware address
  # instead of by name — interface names can differ between the live ISO, the
  # ZFSBootMenu initramfs, and the installed system, but the MAC does not.
  NET_MAC="$(cat "/sys/class/net/$sel/address" 2>/dev/null || true)"
  [[ "$NET_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
    || die "Could not read a valid MAC address for interface '$sel' (got '${NET_MAC:-<empty>}')."
}

valid_ipv4() { # valid_ipv4 STR -> 0 if STR is a dotted-quad IPv4 address
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
  return 0
}

prompt_network() { # interactively collect the static IP config for NET_IFACE; sets NET_IP/NET_GW/NET_MASK
  # Defaults are taken from the live environment's current (typically DHCP-assigned)
  # lease on this NIC, so pressing Enter reuses the DHCP address/gateway/netmask as a
  # static config for pre-boot remote unlock.
  local cur_ip cur_gw cur_mask ip gw mask
  cur_ip="$(iface_ipv4 "$NET_IFACE" | cut -d/ -f1)"
  cur_gw="$(ip route show dev "$NET_IFACE" 2>/dev/null | awk '/^default/{print $3; exit}')"
  cur_mask="$(prefix_to_netmask "$(iface_ipv4 "$NET_IFACE" | cut -s -d/ -f2)" 2>/dev/null || true)"
  local mask_default="${cur_mask:-255.255.255.0}"

  echo
  echo "Static IP config for ZFSBootMenu remote-unlock networking on '$NET_IFACE'"
  echo "(defaults below are this NIC's current DHCP lease; used only pre-boot to reach"
  echo " dropbear — the installed OS's own networking is separate)."
  while :; do
    read -r -p "IP address${cur_ip:+ [$cur_ip]}: " ip </dev/tty || ip=""
    ip="${ip:-$cur_ip}"
    valid_ipv4 "$ip" && break
    warn "Enter a valid IPv4 address, e.g. 192.168.1.50."
  done
  while :; do
    read -r -p "Gateway${cur_gw:+ [$cur_gw]}: " gw </dev/tty || gw=""
    gw="${gw:-$cur_gw}"
    valid_ipv4 "$gw" && break
    warn "Enter a valid IPv4 gateway address, e.g. 192.168.1.1."
  done
  while :; do
    read -r -p "Netmask [${mask_default}]: " mask </dev/tty || mask=""
    mask="${mask:-$mask_default}"
    valid_netmask "$mask" && break
    warn "Enter a valid contiguous IPv4 netmask, e.g. 255.255.255.0."
  done

  echo
  echo "  IP:      $ip"
  echo "  Gateway: $gw"
  echo "  Netmask: $mask"
  require_yes "Use this static network config for remote unlock?"
  NET_IP="$ip"; NET_GW="$gw"; NET_MASK="$mask"
}

prompt_identity() { # Stage 1: prompt for hostname/FQDN + admin username with validation; set globals
  local h u
  # A single label: 1-63 chars of letters/digits/hyphen, no leading/trailing hyphen.
  local label='[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
  # Accept either a bare hostname or a dot-separated FQDN (one or more labels).
  local hostname_re="^${label}(\\.${label})*\$"
  local user_re='^[a-z_][a-z0-9_-]{0,31}$'
  while :; do
    read -r -p "Hostname or FQDN [nas]: " h </dev/tty || h=""
    h="${h:-nas}"
    [[ ${#h} -le 253 && "$h" =~ $hostname_re ]] && break
    warn "Invalid hostname (labels of letters/digits/hyphens, no leading/trailing hyphen, dot-separated for an FQDN; max 253 chars)."
  done
  while :; do
    read -r -p "Admin username (lowercase, gets sudo): " u </dev/tty || u=""
    [[ "$u" =~ $user_re ]] || { warn "Invalid username (start a-z or _, then a-z 0-9 _ -, max 32 chars)."; continue; }
    [[ "$u" == "root" ]] && { warn "Pick a non-root username."; continue; }
    break
  done
  NEW_HOSTNAME="$h"
  ADMIN_USER="$u"
}

prompt_config() { # Stage 1: review the tunable settings, using the CONFIG-block values as defaults
  echo
  echo "${BLD}Configuration — press Enter to accept each default shown in [brackets].${RST}"
  local in

  # Timezone: must resolve to a zoneinfo file in the live environment.
  while :; do
    read -r -p "Timezone [${TIMEZONE}]: " in </dev/tty || in=""
    in="${in:-$TIMEZONE}"
    [[ -e "/usr/share/zoneinfo/$in" ]] && { TIMEZONE="$in"; break; }
    warn "Unknown timezone '$in' (no /usr/share/zoneinfo/$in). Try e.g. Europe/Copenhagen."
  done

  # Console keymap. Restrict to a safe token here so it can't corrupt
  # /etc/default/keyboard or the echo-back grep checks in Phase 8. That it names a
  # REAL keymap is verified later, in Stage 2 Phase 8, once console-setup/kbd (and
  # thus the keymap data) are installed — this live env is too early: the keymap
  # list isn't populated yet, so a check here would only ever warn "unverified".
  local keymap_re='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
  while :; do
    read -r -p "Console keymap [${KEYMAP}]: " in </dev/tty || in=""
    in="${in:-$KEYMAP}"
    [[ "$in" =~ $keymap_re ]] && { KEYMAP="$in"; break; }
    warn "Invalid keymap name '$in' (letters, digits, and . _ - only; no spaces or quotes)."
  done

  # ZFS pool name: ZFS naming rules — start with a letter, then letters/digits/_-.:
  local pool_re='^[A-Za-z][A-Za-z0-9_.:-]*$'
  while :; do
    read -r -p "ZFS pool name [${POOL_NAME}]: " in </dev/tty || in=""
    in="${in:-$POOL_NAME}"
    [[ "$in" =~ $pool_re ]] && { POOL_NAME="$in"; break; }
    warn "Invalid pool name (start with a letter, then letters/digits/_ - . :)."
  done

  read -r -p "Per-disk EFI partition size (sgdisk syntax) [${EFI_SIZE}]: " in </dev/tty || in=""
  EFI_SIZE="${in:-$EFI_SIZE}"

  read -r -p "ZFS compression [${COMPRESSION}]: " in </dev/tty || in=""
  COMPRESSION="${in:-$COMPRESSION}"

  read -r -p "ZFS encryption algorithm [${ENCRYPTION_ALG}]: " in </dev/tty || in=""
  ENCRYPTION_ALG="${in:-$ENCRYPTION_ALG}"

  read -r -p "zpool compatibility set [${ZPOOL_COMPAT}]: " in </dev/tty || in=""
  ZPOOL_COMPAT="${in:-$ZPOOL_COMPAT}"

  # ARC cap: empty = no cap; otherwise a byte count.
  while :; do
    read -r -p "ARC max in bytes (blank = no cap) [${ARC_MAX_BYTES}]: " in </dev/tty || in=""
    in="${in:-$ARC_MAX_BYTES}"
    [[ -z "$in" || "$in" =~ ^[0-9]+$ ]] && { ARC_MAX_BYTES="$in"; break; }
    warn "Enter a plain byte count (digits only) or leave blank for no cap."
  done

  # Dropbear remote-unlock port.
  while :; do
    read -r -p "Dropbear remote-unlock port [${DROPBEAR_PORT}]: " in </dev/tty || in=""
    in="${in:-$DROPBEAR_PORT}"
    [[ "$in" =~ ^[0-9]+$ ]] && (( in >= 1 && in <= 65535 )) && { DROPBEAR_PORT="$in"; break; }
    warn "Enter a TCP port between 1 and 65535."
  done

  read -r -p "ZFSBootMenu release tag [${ZBM_VERSION}]: " in </dev/tty || in=""
  ZBM_VERSION="${in:-$ZBM_VERSION}"

  read -r -p "dracut-crypt-ssh commit [${CRYPT_SSH_COMMIT}]: " in </dev/tty || in=""
  CRYPT_SSH_COMMIT="${in:-$CRYPT_SSH_COMMIT}"

  echo
  echo "Settings:"
  printf '  %-16s %s\n' "Timezone:"    "$TIMEZONE"
  printf '  %-16s %s\n' "Keymap:"      "$KEYMAP"
  printf '  %-16s %s\n' "Pool name:"   "$POOL_NAME"
  printf '  %-16s %s\n' "EFI size:"    "$EFI_SIZE"
  printf '  %-16s %s\n' "Compression:" "$COMPRESSION"
  printf '  %-16s %s\n' "Encryption:"  "$ENCRYPTION_ALG"
  printf '  %-16s %s\n' "zpool compat:" "$ZPOOL_COMPAT"
  printf '  %-16s %s\n' "ARC max:"     "${ARC_MAX_BYTES:-<no cap>}"
  printf '  %-16s %s\n' "Dropbear port:" "$DROPBEAR_PORT"
  printf '  %-16s %s\n' "ZBM version:" "$ZBM_VERSION"
  printf '  %-16s %s\n' "crypt-ssh:"   "$CRYPT_SSH_COMMIT"
  require_yes "Proceed with these settings?"
}

load_state() { # Stage 2: recover identity + network config + disk list recorded by Stage 1
  local f=/root/zbm-install.env d
  [[ -f "$f" ]] || die "State file $f missing (Stage 1 should have written it)."
  # shellcheck disable=SC1090
  . "$f"
  # ARC_MAX_BYTES is deliberately not required here: empty means "no cap".
  [[ -n "${NEW_HOSTNAME:-}" && -n "${ADMIN_USER:-}" && -n "${NET_IFACE:-}" && -n "${NET_MAC:-}" \
     && -n "${NET_IP:-}" && -n "${NET_GW:-}" && -n "${NET_MASK:-}" && -n "${ZBM_DISKS:-}" ]] \
    || die "State file missing NEW_HOSTNAME/ADMIN_USER/NET_IFACE/NET_MAC/NET_IP/NET_GW/NET_MASK/ZBM_DISKS."
  [[ -n "${TIMEZONE:-}" && -n "${KEYMAP:-}" && -n "${POOL_NAME:-}" && -n "${EFI_SIZE:-}" \
     && -n "${COMPRESSION:-}" && -n "${ENCRYPTION_ALG:-}" && -n "${ZPOOL_COMPAT:-}" \
     && -n "${DROPBEAR_PORT:-}" && -n "${ZBM_VERSION:-}" && -n "${CRYPT_SSH_COMMIT:-}" ]] \
    || die "State file missing tunable settings (TIMEZONE/KEYMAP/POOL_NAME/EFI_SIZE/COMPRESSION/ENCRYPTION_ALG/ZPOOL_COMPAT/DROPBEAR_PORT/ZBM_VERSION/CRYPT_SSH_COMMIT)."
  read -ra DISKS <<< "$ZBM_DISKS"
  [[ ${#DISKS[@]} -ge 3 ]] || die "Recorded disk list has fewer than 3 entries."
  for d in "${DISKS[@]}"; do [[ -b "$d" ]] || die "Recorded disk not present in chroot: $d"; done
}

resolve_id() { ( . /etc/os-release && printf '%s' "$ID" ); }

ROOT_ID="$(resolve_id)"
[[ -n "$ROOT_ID" ]] || die "Could not resolve dataset id."
DISKS=()        # populated by select_disks (Stage 1) or load_state (Stage 2)
CANDIDATES=()   # populated by detect_disks
LIVE_DISK=""    # populated by detect_disks — whole-disk device backing the live USB, excluded as a target
IFACES=()       # populated by detect_ifaces
NET_IFACE=""    # populated by select_iface (Stage 1) or load_state (Stage 2)
NET_MAC=""      # populated by select_iface (Stage 1) or load_state (Stage 2) — the NIC's MAC
NET_IP=""       # populated by prompt_network (Stage 1) or load_state (Stage 2)
NET_GW=""       # populated by prompt_network (Stage 1) or load_state (Stage 2)
NET_MASK=""     # populated by prompt_network (Stage 1) or load_state (Stage 2)

usage() {
  # print the header comment block (up to the 'set -Eeuo' line), stripping '# ' prefixes
  sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
}

# =====================================================================================
# STAGE 1 — live environment
# =====================================================================================
stage1() {
  echo "${BLD}ZFSBootMenu encrypted-root installer — Stage 1 (live environment)${RST}"

  # ---- Phase 0: preflight ----
  phase 0 "Preflight checks"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
  [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode (no /sys/firmware/efi)."
  # This script writes trixie apt sources and debootstraps trixie — verify the live env matches.
  if ! grep -q '^ID=debian' /etc/os-release || ! grep -q 'VERSION_CODENAME=trixie' /etc/os-release; then
    die "Live environment is not Debian Trixie (check /etc/os-release). Boot the Trixie live ISO."
  fi
  # interactive identity (hostname + admin username), before any destructive step
  prompt_identity
  # interactive review of the tunable settings (CONFIG-block values are the defaults)
  prompt_config
  # detect, list, and confirm which NIC ZFSBootMenu remote-unlock should use
  select_iface
  # interactively collect the static IP config for that NIC (sets NET_IP/NET_GW/NET_MASK)
  prompt_network
  # detect, list, and confirm which disks to use (sets DISKS); must succeed before any wipe
  select_disks
  for d in "${DISKS[@]}"; do
    assert_block "$d"
    local mnts; mnts="$(lsblk -nro MOUNTPOINT "$d" || true)"
    if grep -q . <<<"$mnts"; then
      warn "$d has mounted partitions:"; lsblk "$d"
    fi
  done
  # discover + confirm the SSH public key from the current directory (must succeed before any wipe)
  find_pubkey
  ok "Preflight passed. Target: encrypted raidz1 '$POOL_NAME' (id '$ROOT_ID') on ${DISKS[*]}, remote unlock via $NET_IFACE ($NET_IP)"

  # ---- Phase 1: live env packages ----
  phase 1 "Install ZFS tooling in the live environment"
  pause
  cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian/ trixie main contrib non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free-firmware
EOF
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y debootstrap gdisk parted dosfstools dkms mdadm \
    "linux-headers-$(uname -r)" zfs-dkms zfsutils-linux
  need_cmd zpool; need_cmd zfs; need_cmd sgdisk; need_cmd partprobe; need_cmd mkfs.vfat; need_cmd mdadm; need_cmd debootstrap
  modprobe zfs || die "zfs kernel module failed to load."
  # Random per-machine hostid (no fixed value), so building several boxes with this
  # script gives each its own — shared hostids defeat ZFS's multi-host import guard.
  # Generate it only if the live session doesn't already have one, so re-running the
  # installer after a failed attempt reuses the same value and still matches a pool
  # left behind by that attempt (a fresh Debian live ships no /etc/hostid). It is
  # copied into the new system in Phase 6, so live env, initramfs, and installed
  # system all agree.
  [[ -s /etc/hostid ]] || zgenhostid
  [[ -s /etc/hostid ]] || die "/etc/hostid was not created."
  ok "Tooling installed; zfs module loaded; hostid set."

  # ---- Phase 2: WIPE GATE ----
  phase 2 "Partition disks (DESTRUCTIVE)"
  echo "About to ${RED}${BLD}ERASE COMPLETELY${RST} and repartition:"
  for d in "${DISKS[@]}"; do printf '   - %s   (%s)\n' "$d" "$(lsblk -dno SIZE,MODEL "$d" 2>/dev/null || echo '?')"; done
  echo
  local ans=""
  read -r -p "Type ${BLD}ERASE${RST} to confirm (anything else aborts): " ans </dev/tty || ans=""
  [[ "$ans" == "ERASE" ]] || die "Wipe not confirmed."

  # Defensive cleanup of leftovers from a previous failed run, so re-runs don't
  # hit "device busy" (stale bind mounts, imported pool, assembled md array).
  if mountpoint -q /mnt 2>/dev/null; then
    warn "Unmounting stale /mnt from a previous run."
    umount -R /mnt 2>/dev/null || umount -lR /mnt 2>/dev/null || true
  fi
  if zpool list "$POOL_NAME" >/dev/null 2>&1; then
    warn "Exporting stale pool '$POOL_NAME' from a previous run."
    zpool export -f "$POOL_NAME" || die "Could not export existing pool '$POOL_NAME' — resolve manually."
  fi
  # Stop any md array assembled from the target disks — including one that udev
  # auto-assembled under a different name (e.g. /dev/md127) from a previous run's
  # leftover RAID superblock. Such an array holds a member partition "busy" and
  # breaks building the new ESP mirror; stopping only /dev/md0 by name misses it.
  local _d _md
  for _d in "${DISKS[@]}"; do
    while read -r _md; do
      [[ -n "$_md" ]] || continue
      warn "Stopping stale md array /dev/${_md} backed by ${_d}."
      umount "/dev/${_md}" 2>/dev/null || true
      mdadm --stop "/dev/${_md}" || die "Could not stop /dev/${_md} — resolve manually."
    done < <(lsblk -no NAME "$_d" 2>/dev/null | grep -oE 'md[0-9]+' | sort -u || true)
  done

  for d in "${DISKS[@]}"; do
    log "Wiping $d"
    zpool labelclear -f "$d" 2>/dev/null || true
    mdadm --zero-superblock "$(part "$d" 1)" 2>/dev/null || true
    wipefs -a "$d"
    sgdisk --zap-all "$d"
    sgdisk -n "1:1m:${EFI_SIZE}" -t "1:ef00" "$d"   # EFI
    sgdisk -n "2:0:-10m"         -t "2:bf00" "$d"   # ZFS
  done
  # Re-read only the disks we just partitioned — a bare `partprobe` probes every
  # disk in the system, including the live USB, which (as a hybrid ISO) still
  # carries an Apple driver descriptor that triggers a harmless but noisy
  # "physical block size 2048 vs 512" warning.
  partprobe "${DISKS[@]}" || true; udevadm settle || true; sleep 2
  for d in "${DISKS[@]}"; do
    assert_block "$(part "$d" 1)"; assert_block "$(part "$d" 2)"
  done
  ok "All ${#DISKS[@]} disks partitioned (p1=EFI, p2=ZFS)."

  # ---- Phase 3: mirrored ESP ----
  phase 3 "Create mirrored EFI partition (mdadm, metadata 1.0)"
  pause
  local esp_parts=(); for d in "${DISKS[@]}"; do esp_parts+=("$(part "$d" 1)"); done
  mdadm --create /dev/md0 --level=1 --raid-devices="${#DISKS[@]}" --metadata=1.0 --run \
    --homehost="${NEW_HOSTNAME%%.*}" --name=efi "${esp_parts[@]}"
  assert_block /dev/md0
  mkfs.vfat -F32 /dev/md0
  [[ "$(blkid -s TYPE -o value /dev/md0)" == "vfat" ]] || die "ESP md0 is not vfat after mkfs."
  ok "Mirrored ESP /dev/md0 created and formatted vfat."

  # ---- Phase 4: passphrase + encrypted raidz1 pool ----
  phase 4 "Create encrypted raidz1 pool '$POOL_NAME'"
  pause
  local p1 p2
  while :; do
    read -r -s -p "Enter ZFS passphrase (>=8 chars, you'll type this at every boot): " p1 </dev/tty; echo
    read -r -s -p "Confirm passphrase: " p2 </dev/tty; echo
    [[ "$p1" == "$p2" ]] || { warn "Passphrases differ."; continue; }
    [[ ${#p1} -ge 8 ]]   || { warn "Too short (>=8)."; continue; }
    break
  done
  mkdir -p /etc/zfs
  ( umask 277; printf '%s' "$p1" > /etc/zfs/zroot.key )   # NO trailing newline; never group/world-readable
  chmod 000 /etc/zfs/zroot.key
  unset p1 p2

  local zfs_parts=(); for d in "${DISKS[@]}"; do zfs_parts+=("$(part "$d" 2)"); done
  zpool create -f -o ashift=12 \
    -O compression="$COMPRESSION" \
    -O acltype=posixacl -O xattr=sa -O atime=off \
    -O encryption="$ENCRYPTION_ALG" \
    -O keyformat=passphrase \
    -O keylocation=file:///etc/zfs/zroot.key \
    -o autotrim=on \
    -o compatibility="$ZPOOL_COMPAT" \
    -m none "$POOL_NAME" \
    raidz1 "${zfs_parts[@]}"

  zpool list "$POOL_NAME" >/dev/null || die "Pool $POOL_NAME not found after create."
  [[ "$(zfs get -H -o value encryption "$POOL_NAME")" == "$ENCRYPTION_ALG" ]] || die "Encryption not active on pool."
  [[ "$(zpool list -H -o health "$POOL_NAME")" == "ONLINE" ]] || die "Pool not ONLINE after create."
  local pool_status; pool_status="$(zpool status "$POOL_NAME")"
  grep -q "raidz1" <<<"$pool_status" || die "Pool is not raidz1 — check vdev layout."
  ok "Encrypted raidz1 pool ONLINE with $COMPRESSION compression."

  # ---- Phase 5: datasets ----
  phase 5 "Create boot-environment datasets"
  zfs create -o mountpoint=none "$POOL_NAME/ROOT"
  zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/ROOT/$ROOT_ID"
  zfs create -o mountpoint=/home "$POOL_NAME/home"
  zpool set bootfs="$POOL_NAME/ROOT/$ROOT_ID" "$POOL_NAME"
  [[ "$(zpool get -H -o value bootfs "$POOL_NAME")" == "$POOL_NAME/ROOT/$ROOT_ID" ]] || die "bootfs not set correctly."
  ok "Datasets created; bootfs set."

  # ---- Phase 6: re-import under /mnt + base system ----
  phase 6 "Mount under /mnt and bootstrap Debian"
  zpool export "$POOL_NAME"
  zpool import -N -R /mnt "$POOL_NAME"
  zfs load-key "$POOL_NAME"
  zfs mount "$POOL_NAME/ROOT/$ROOT_ID"
  zfs mount "$POOL_NAME/home"
  udevadm trigger || true
  mountpoint -q /mnt || die "/mnt is not a mountpoint after zfs mount."

  log "Running debootstrap (this takes a few minutes)…"
  debootstrap trixie /mnt
  [[ -x /mnt/bin/bash ]] || die "debootstrap did not produce a usable root."

  cp /etc/hostid /mnt/etc/
  cp /etc/resolv.conf /mnt/etc/
  mkdir -p /mnt/etc/zfs
  # cachefile from the live-env import, so zfs-import-cache has one on first boot
  if [[ -f /etc/zfs/zpool.cache ]]; then cp /etc/zfs/zpool.cache /mnt/etc/zfs/; fi
  cp /etc/zfs/zroot.key /mnt/etc/zfs/zroot.key
  chmod 000 /mnt/etc/zfs/zroot.key
  [[ -f /mnt/etc/zfs/zroot.key ]] || die "Encryption key was not copied into the new system."
  # carry the confirmed SSH public key into the new system for Stage 2 to install
  printf '%s\n' "$SSH_PUBKEY" > /mnt/root/authorized_key.pub
  chmod 0644 /mnt/root/authorized_key.pub
  [[ -s /mnt/root/authorized_key.pub ]] || die "Failed to stage authorized SSH key for Stage 2."
  # record identity, network config, tunable settings, and selected disks for Stage 2
  # (all values are validated and quote/space-free — timezone may contain a '/' but no
  # spaces or quotes — so safe to single-quote; disks cannot be re-detected once they
  # are partitioned, and the config prompts only run in Stage 1)
  {
    printf "NEW_HOSTNAME='%s'\nADMIN_USER='%s'\n" "$NEW_HOSTNAME" "$ADMIN_USER"
    printf "NET_IFACE='%s'\nNET_MAC='%s'\nNET_IP='%s'\nNET_GW='%s'\nNET_MASK='%s'\n" \
      "$NET_IFACE" "$NET_MAC" "$NET_IP" "$NET_GW" "$NET_MASK"
    printf "TIMEZONE='%s'\nKEYMAP='%s'\nPOOL_NAME='%s'\nEFI_SIZE='%s'\n" \
      "$TIMEZONE" "$KEYMAP" "$POOL_NAME" "$EFI_SIZE"
    printf "COMPRESSION='%s'\nENCRYPTION_ALG='%s'\nZPOOL_COMPAT='%s'\nARC_MAX_BYTES='%s'\n" \
      "$COMPRESSION" "$ENCRYPTION_ALG" "$ZPOOL_COMPAT" "$ARC_MAX_BYTES"
    printf "DROPBEAR_PORT='%s'\nZBM_VERSION='%s'\nCRYPT_SSH_COMMIT='%s'\n" \
      "$DROPBEAR_PORT" "$ZBM_VERSION" "$CRYPT_SSH_COMMIT"
    printf "ZBM_DISKS='%s'\n" "${DISKS[*]}"
  } > /mnt/root/zbm-install.env
  [[ -s /mnt/root/zbm-install.env ]] || die "Failed to record install state for Stage 2."
  ok "Base system installed; hostid/resolv.conf/encryption-key/SSH-pubkey/install-state copied in."

  # bind mounts + hand off to stage 2 inside the chroot
  mount -t proc  proc /mnt/proc
  mount -t sysfs sys  /mnt/sys
  mount -B /dev       /mnt/dev
  mount -t devpts pts /mnt/dev/pts

  install -m 0755 "$(readlink -f "$0")" /mnt/root/zbm-install.sh
  log "Entering chroot to run Stage 2…"
  chroot /mnt /usr/bin/env ASSUME_YES="$ASSUME_YES" bash /root/zbm-install.sh --stage2

  # ---- finalize ----
  phase 7 "Finalize and reboot"
  log "Unmounting and exporting pool…"
  umount -n -R /mnt || { warn "Lazy-unmounting stragglers"; umount -nl -R /mnt || true; }
  zpool export "$POOL_NAME" || warn "Pool export reported an issue; check 'zpool status'."
  ok "Install complete."
  echo
  echo "${BLD}Next:${RST}"
  echo "  1. Remove the USB stick."
  echo "  2. Reboot. ZFSBootMenu will prompt for your passphrase on the CONSOLE first — verify locally."
  echo "  3. Remote unlock:  ssh -p ${DROPBEAR_PORT} root@<nas-ip>   (unlock in ZBM)"
  echo "     then reconnect:  ssh ${ADMIN_USER}@<nas-ip>   (normal port 22 after boot)"
  if confirm "Reboot now?"; then reboot; else log "Reboot skipped. Run 'reboot' when ready."; fi
}

# =====================================================================================
# STAGE 2 — inside the chroot
# =====================================================================================
stage2() {
  echo "${BLD}Stage 2 (inside chroot)${RST}"
  [[ $EUID -eq 0 ]] || die "Stage 2 must run as root."
  load_state      # recover the identity, network config, and disk list recorded by Stage 1

  # ---- Phase 8: base config ----
  phase 8 "Base Debian configuration"
  # Debian convention: /etc/hostname holds the short (unqualified) name; the
  # FQDN, if any, is resolved via /etc/hosts. NEW_HOSTNAME may be either.
  local short_host="${NEW_HOSTNAME%%.*}"
  local hosts_names="$short_host"
  [[ "$NEW_HOSTNAME" != "$short_host" ]] && hosts_names="${NEW_HOSTNAME} ${short_host}"
  echo "$short_host" > /etc/hostname
  # debootstrap does not create /etc/hosts — write a complete one
  cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${hosts_names}

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
  cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian/ trixie main contrib non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y locales console-setup keyboard-configuration openssh-server sudo ca-certificates
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  # Console keymap for the installed OS's TTY. Also the source of truth dracut's
  # i18n module reads (Phase 10) to bake the same keymap into the ZFSBootMenu
  # image — this is the one prompt (the ZFS passphrase) where a wrong keymap
  # can make a passphrase impossible to type correctly.
  #
  # The installed-OS console keymap has two consumers that, on Debian, read
  # DIFFERENT files — so we write BOTH and keep them consistent:
  #   - systemd-vconsole-setup and dracut's i18n module (which bakes the
  #     ZFSBootMenu passphrase-prompt keymap in Phase 10) read /etc/vconsole.conf
  #     (KEYMAP=, a loadkeys/vconsole name).
  #   - Debian's console-setup (keyboard-setup.service *and* console-setup.service,
  #     both running setupcon) reads /etc/default/keyboard (XKBLAYOUT=). If that
  #     disagrees with vconsole.conf, setupcon re-applies its layout at boot and
  #     WINS — which is why writing only vconsole.conf (and masking just
  #     keyboard-setup.service) left the console on the wrong layout.
  # KEYMAP is a vconsole keymap name; for the common layouts it also equals the
  # X11 layout code written to /etc/default/keyboard (dk, de, fr, es, it, us, no,
  # se, fi, ...). Setting XKBMODEL also silences setupcon's "keyboard model is
  # unknown, assuming pc105" warning.
  #
  # Verify the keymap is real now that console-setup/kbd (the keymap data) are
  # installed — the live-env prompt only charset-checked it, since the keymap
  # list wasn't populated that early. Non-fatal (the install is nearly complete
  # and the layout is fixable post-boot) but warned loudly so a typo doesn't
  # silently yield the wrong console/passphrase layout.
  local known_keymaps; known_keymaps="$(localectl list-keymaps 2>/dev/null || true)"
  if [[ -n "$known_keymaps" ]]; then
    grep -qxF "$KEYMAP" <<<"$known_keymaps" \
      || warn "Console keymap '$KEYMAP' is not in 'localectl list-keymaps' — the console may fall back to a default layout. Verify passphrase entry on the local console at first boot; fix later with 'localectl set-keymap <name>' and /etc/default/keyboard."
  else
    warn "Could not list keymaps to verify '$KEYMAP'; skipping keymap verification."
  fi
  echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
  grep -q "^KEYMAP=${KEYMAP}$" /etc/vconsole.conf || die "Failed to write /etc/vconsole.conf keymap."
  cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
  grep -q "^XKBLAYOUT=\"${KEYMAP}\"\$" /etc/default/keyboard || die "Failed to write /etc/default/keyboard layout."
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || warn "Timezone $TIMEZONE not found; leaving default."
  systemctl enable ssh >/dev/null 2>&1 || true

  # Installed-OS static networking, reusing the same IP/gateway/netmask captured in
  # Stage 1 (defaulted from the live DHCP lease). systemd-networkd ships with systemd,
  # so nothing extra is installed. The NIC is matched by its MAC address, not its
  # name: interface names can differ between the live ISO and the installed system
  # (e.g. eth0 vs enp3s0), but the MAC is stable, so matching on it can't silently
  # leave the box with no network.
  local net_prefix; net_prefix="$(netmask_to_prefix "$NET_MASK")"
  [[ "$net_prefix" =~ ^[0-9]+$ ]] || die "Could not convert netmask '$NET_MASK' to a CIDR prefix."
  mkdir -p /etc/systemd/network
  cat > /etc/systemd/network/10-zbm-unlock.network <<EOF
[Match]
MACAddress=${NET_MAC}

[Network]
Address=${NET_IP}/${net_prefix}
Gateway=${NET_GW}
DNS=${NET_GW}
EOF
  grep -q "Address=${NET_IP}/${net_prefix}" /etc/systemd/network/10-zbm-unlock.network \
    || die "Failed to write OS network config."
  systemctl enable systemd-networkd >/dev/null 2>&1 || die "Could not enable systemd-networkd."
  # Ensure a usable resolver: the resolv.conf copied from the live env may be a
  # systemd-resolved stub (127.0.0.53) that does not exist in the installed system.
  # If it carries no real nameserver, fall back to the gateway (matches the DNS= above).
  if ! grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | grep -qv '127\.0\.0\.53'; then
    printf 'nameserver %s\n' "$NET_GW" > /etc/resolv.conf
  fi
  ok "OS networking: static ${NET_IP}/${net_prefix} via ${NET_GW} on MAC ${NET_MAC} (systemd-networkd)."

  if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
  fi
  echo "${BLD}Set a password for admin user '$ADMIN_USER':${RST}"; set_password "$ADMIN_USER"
  echo "${BLD}Set the root password:${RST}"; set_password root
  ok "Hostname, locale, SSH, sudo, and admin user '$ADMIN_USER' configured."

  # ---- Phase 9: ZFS in the installed system ----
  phase 9 "Install ZFS, ARC cap, services, initramfs"
  pause
  DEBIAN_FRONTEND=noninteractive apt install -y \
    linux-image-amd64 linux-headers-amd64 build-essential \
    zfs-dkms zfs-initramfs zfsutils-linux dosfstools mdadm
  echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
  # Verify the boot-critical ZFS kernel module actually built for the installed kernel.
  # (A silent DKMS failure would otherwise surface as an unbootable system.)
  local kver
  kver="$(printf '%s\n' /lib/modules/*/ | sed 's#/lib/modules/##; s#/##' | sort -V | tail -1)"
  [[ -n "$kver" ]] || die "Could not determine installed kernel version."
  modinfo -k "$kver" zfs >/dev/null 2>&1 \
    || die "ZFS kernel module did not build for kernel $kver — check 'dkms status'."
  ok "ZFS module built and present for kernel $kver."
  if [[ -n "${ARC_MAX_BYTES:-}" ]]; then
    echo "options zfs zfs_arc_max=${ARC_MAX_BYTES}" > /etc/modprobe.d/zfs.conf
    ok "ARC capped at ${ARC_MAX_BYTES} bytes."
  fi
  mdadm --detail --scan >> /etc/mdadm/mdadm.conf
  grep -q "ARRAY" /etc/mdadm/mdadm.conf || die "mdadm.conf has no ARRAY entry for the ESP."
  systemctl enable zfs.target zfs-import-cache zfs-import.target zfs-mount

  local efi_uuid; efi_uuid="$(blkid -s UUID -o value /dev/md0)"
  [[ -n "$efi_uuid" ]] || die "Could not read ESP UUID from /dev/md0."
  printf 'UUID=%s /boot/efi vfat defaults,nofail 0 0\n' "$efi_uuid" >> /etc/fstab
  mkdir -p /boot/efi
  mount /boot/efi
  mountpoint -q /boot/efi || die "/boot/efi failed to mount."
  update-initramfs -c -k all
  # confirm the encryption key got baked into the Debian initramfs
  local initrd; initrd="$(printf '%s\n' /boot/initrd.img-* | sort -V | tail -1)"
  [[ -f "$initrd" ]] || die "No Debian initramfs found in /boot."
  local initrd_contents; initrd_contents="$(lsinitramfs "$initrd" || true)"
  grep -q "etc/zfs/zroot.key" <<<"$initrd_contents" || die "Key not found in Debian initramfs."
  ok "ZFS configured; ESP mounted; key present in initramfs."

  # ---- pre-apt auto-snapshots of the booted root dataset (one-reboot undo) ----
  cat > /usr/local/sbin/zfs-apt-snapshot <<'EOF'
#!/bin/sh
# Snapshot the currently-booted ZFS root dataset before apt modifies it,
# then prune so only the newest $keep apt_ snapshots remain.
set -eu
keep=20
root_ds="$(findmnt -no SOURCE / 2>/dev/null || true)"
case "$root_ds" in */ROOT/*) ;; *) exit 0 ;; esac   # only act on a ZFSBootMenu root
command -v zfs >/dev/null 2>&1 || exit 0
zfs snapshot "${root_ds}@apt_$(date +%Y-%m-%d-%H%M%S)" 2>/dev/null || true
zfs list -H -t snapshot -o name -s creation 2>/dev/null \
  | grep "^${root_ds}@apt_" \
  | head -n "-${keep}" \
  | while IFS= read -r snap; do
      [ -n "$snap" ] && zfs destroy "$snap" 2>/dev/null || true
    done
EOF
  chmod 0755 /usr/local/sbin/zfs-apt-snapshot

  echo 'DPkg::Pre-Invoke { "/usr/local/sbin/zfs-apt-snapshot"; };' > /etc/apt/apt.conf.d/80-zfs-snapshot
  ok "Pre-apt auto-snapshots enabled (newest 20 kept, older ones pruned after each snapshot)."

  # ---- Phase 10: ZFSBootMenu + remote unlock ----
  phase 10 "Build ZFSBootMenu with dropbear remote unlock"
  pause
  zfs set org.zfsbootmenu:commandline="quiet loglevel=0" "$POOL_NAME/ROOT"
  zfs set org.zfsbootmenu:keysource="$POOL_NAME/ROOT/$ROOT_ID" "$POOL_NAME"

  # isc-dhcp-client provides dhclient, which dracut's network-legacy module
  # (a hard dependency of crypt-ssh's 'network' module) requires at build time —
  # without it the ZBM image build fails with "Module 'crypt-ssh' ... network ...
  # network-legacy ... can't be installed".
  # fzf is the interactive menu UI ZFSBootMenu is built around; its dracut module
  # marks it an essential executable, so the image build hard-fails without it.
  # mbuffer is an optional ZBM binary (ZBM only warns if absent) used for
  # zfs send/recv in the recovery shell — included so that shell is fully usable.
  # systemd-boot-efi provides the UEFI stub loader (linuxx64.efi.stub) that
  # generate-zbm bundles the kernel+initramfs into as a single EFI executable.
  # dropbear-bin (NOT the full 'dropbear' package): we only need the dropbear
  # binary for crypt-ssh to bake into the ZBM image. The 'dropbear' package pulls
  # in dropbear-run, which enables a system SSH daemon on port 22 that collides
  # with openssh-server ("address already in use") on the installed system.
  DEBIAN_FRONTEND=noninteractive apt install -y \
    curl git make efibootmgr dracut-core dracut-network isc-dhcp-client dropbear-bin fzf mbuffer \
    systemd-boot-efi \
    libsort-versions-perl libboolean-perl libconfig-inifiles-perl libyaml-pp-perl kexec-tools
  need_cmd dracut; need_cmd dropbear; need_cmd dhclient; need_cmd fzf
  [[ -f /usr/lib/systemd/boot/efi/linuxx64.efi.stub ]] \
    || die "UEFI stub loader missing (/usr/lib/systemd/boot/efi/linuxx64.efi.stub) — systemd-boot-efi not installed?"

  # ZBM from source, pinned to $ZBM_VERSION (local generation needed so crypt-ssh is baked in)
  mkdir -p /usr/local/src/zfsbootmenu
  ( cd /usr/local/src/zfsbootmenu
    curl -fL "https://github.com/zbm-dev/zfsbootmenu/archive/refs/tags/${ZBM_VERSION}.tar.gz" \
      | tar -zxv --strip-components=1 -f - )
  ( cd /usr/local/src/zfsbootmenu && make core dracut )
  need_cmd generate-zbm
  log "ZFSBootMenu source pinned to ${ZBM_VERSION}"

  # dracut-crypt-ssh module, pinned to an exact commit ($CRYPT_SSH_COMMIT).
  # Full clone (not --depth 1) so an arbitrary pinned commit can be checked out.
  rm -rf /tmp/dracut-crypt-ssh
  git clone https://github.com/dracut-crypt-ssh/dracut-crypt-ssh /tmp/dracut-crypt-ssh
  git -C /tmp/dracut-crypt-ssh checkout --quiet "$CRYPT_SSH_COMMIT" \
    || die "Could not check out pinned dracut-crypt-ssh commit $CRYPT_SSH_COMMIT"
  local got_sha; got_sha="$(git -C /tmp/dracut-crypt-ssh rev-parse HEAD)"
  [[ "$got_sha" == "$CRYPT_SSH_COMMIT" ]] \
    || die "dracut-crypt-ssh commit mismatch: expected $CRYPT_SSH_COMMIT, got $got_sha"
  log "dracut-crypt-ssh pinned to ${CRYPT_SSH_COMMIT}"
  mkdir -p /usr/lib/dracut/modules.d/60crypt-ssh
  cp -r /tmp/dracut-crypt-ssh/modules/60crypt-ssh/* /usr/lib/dracut/modules.d/60crypt-ssh/
  # comment out the unshipped helper installers that otherwise break the build
  # shellcheck disable=SC2016  # matching the literal text "$moddir" in the file, not expanding it
  sed -i -E 's#^([[:space:]]*inst "\$moddir"/helper/.*)#\##' /usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh
  # shellcheck disable=SC2016  # literal "$moddir" again
  ! grep -E '^[[:space:]]*inst "\$moddir"/helper/' /usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh \
    || die "crypt-ssh helper lines were not commented out."

  # dedicated dropbear host keys (so the client doesn't see new keys each boot)
  mkdir -p /etc/dropbear
  [[ -f /etc/dropbear/ssh_host_ed25519_key ]] || ssh-keygen -t ed25519 -f /etc/dropbear/ssh_host_ed25519_key -N "" -q
  [[ -f /etc/dropbear/ssh_host_ecdsa_key   ]] || ssh-keygen -t ecdsa   -m PEM -f /etc/dropbear/ssh_host_ecdsa_key   -N "" -q
  [[ -f /etc/dropbear/ssh_host_rsa_key     ]] || ssh-keygen -t rsa -b 4096 -m PEM -f /etc/dropbear/ssh_host_rsa_key -N "" -q
  [[ -f /root/authorized_key.pub ]] || die "Authorized key /root/authorized_key.pub missing (Stage 1 should have placed it)."
  install -m 0644 /root/authorized_key.pub /etc/dropbear/root_key
  grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-)' /etc/dropbear/root_key || die "root_key does not contain a valid public key."

  # ZBM kernel cmdline carries the static network config so dropbear can come up.
  # Pin the NIC to a fixed name by MAC (ifname=) rather than trusting the name the
  # ZFSBootMenu initramfs happens to assign — the kernel renames the interface with
  # this MAC to zbmnet0 early, and ip= then configures zbmnet0, so remote unlock
  # can't break just because udev names the NIC differently than the live ISO did.
  local zbm_ifname="zbmnet0"
  local ip_arg="ifname=${zbm_ifname}:${NET_MAC} ip=${NET_IP}::${NET_GW}:${NET_MASK}::${zbm_ifname}:none"

  mkdir -p /etc/zfsbootmenu/dracut.conf.d
  cat > /etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PreHooksDir: /etc/zfsbootmenu/generate-zbm.pre.d
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
Components:
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/zbm
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ${ip_arg} rd.vconsole.keymap=${KEYMAP} quiet loglevel=0
EOF

  cat > /etc/zfsbootmenu/dracut.conf.d/dropbear.conf <<EOF
add_dracutmodules+=" crypt-ssh network-legacy i18n "
dropbear_acl=/etc/dropbear/root_key
dropbear_ed25519_key=/etc/dropbear/ssh_host_ed25519_key
dropbear_ecdsa_key=/etc/dropbear/ssh_host_ecdsa_key
dropbear_rsa_key=/etc/dropbear/ssh_host_rsa_key
dropbear_port=${DROPBEAR_PORT}
EOF

  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
  generate-zbm
  local zbm_img="/boot/efi/EFI/zbm/VMLINUZ.EFI"
  [[ -f "$zbm_img" ]] || die "ZBM image not produced at $zbm_img."
  # verify dropbear + keys actually made it into the image.
  # NOTE: capture once, then grep the variable — `lsinitrd | grep -q` under pipefail
  # would report failure via SIGPIPE (141) even on a successful match.
  local zbm_contents; zbm_contents="$(lsinitrd "$zbm_img" 2>/dev/null || true)"
  grep -q dropbear <<<"$zbm_contents" || die "dropbear NOT in ZBM image — remote unlock would fail."
  # crypt-ssh installs the acl (our /etc/dropbear/root_key) into the image under
  # dropbear's fixed path /root/.ssh/authorized_keys — verify by that path, not
  # by the source filename.
  grep -qE 'root/\.ssh/authorized_keys' <<<"$zbm_contents" \
    || die "authorized key NOT in ZBM image (expected /root/.ssh/authorized_keys) — remote unlock would fail."
  ok "ZFSBootMenu built with working dropbear remote unlock."
  # Soft check only: the i18n module's internal file naming isn't a stable
  # contract, so a miss here is a prompt to verify by hand, not a hard failure.
  if grep -qi "keymap\|i18n" <<<"$zbm_contents"; then
    ok "Console keymap ($KEYMAP) appears to be embedded in the ZBM image."
  else
    warn "Could not confirm console keymap ($KEYMAP) was embedded in the ZBM image — verify passphrase entry on the local console after first boot."
  fi

  # Keep a known-good backup copy of the freshly-built image. On future rebuilds the
  # kernel hook rotates the current (working) image here first, so a broken rebuild
  # never overwrites your last-good bootloader.
  cp -f "$zbm_img" /boot/efi/EFI/zbm/VMLINUZ-BACKUP.EFI

  # Remove any ZFSBootMenu entries from a previous run (efibootmgr -c always appends,
  # so re-runs would otherwise accumulate duplicates), then create backup + primary.
  local bootnum
  while read -r bootnum; do
    [[ -n "$bootnum" ]] && efibootmgr -b "$bootnum" -B >/dev/null || true
  done < <(efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\? *ZFSBootMenu.*/\1/p')

  # EFI boot entries. Backups created first so the primaries sit ahead of them in
  # BootOrder; the backup entries exist for one-keypress recovery from the firmware
  # boot menu if a rebuilt primary image ever misbehaves.
  local i
  for i in "${!DISKS[@]}"; do
    efibootmgr -c -d "${DISKS[$i]}" -p 1 \
      -L "ZFSBootMenu Backup (disk $((i+1)))" -l '\EFI\zbm\VMLINUZ-BACKUP.EFI' >/dev/null
  done
  for i in "${!DISKS[@]}"; do
    efibootmgr -c -d "${DISKS[$i]}" -p 1 \
      -L "ZFSBootMenu (disk $((i+1)))" -l '\EFI\zbm\VMLINUZ.EFI' >/dev/null
  done
  local efi_entries; efi_entries="$(efibootmgr)"
  grep -q "ZFSBootMenu (disk 1)"        <<<"$efi_entries" || die "Primary EFI boot entry was not created."
  grep -q "ZFSBootMenu Backup (disk 1)" <<<"$efi_entries" || die "Backup EFI boot entry was not created."

  # Rebuild ZBM on kernel updates, rotating the current image to the backup slot first.
  cat > /etc/kernel/postinst.d/zbm <<'EOF'
#!/bin/sh
set -e
img=/boot/efi/EFI/zbm/VMLINUZ.EFI
[ -f "$img" ] && cp -f "$img" /boot/efi/EFI/zbm/VMLINUZ-BACKUP.EFI
generate-zbm
EOF
  chmod +x /etc/kernel/postinst.d/zbm
  ok "Primary + backup EFI entries added on all ${#DISKS[@]} disks; rotating kernel hook installed."

  # ---- Phase 11: rescue dataset + base snapshot ----
  phase 11 "Create rescue dataset and base snapshot"
  zfs snapshot "$POOL_NAME/ROOT/$ROOT_ID@base_install"
  zfs clone -o canmount=noauto -o mountpoint=/ \
    "$POOL_NAME/ROOT/$ROOT_ID@base_install" "$POOL_NAME/ROOT/${ROOT_ID}_rescue"
  zfs list "$POOL_NAME/ROOT/${ROOT_ID}_rescue" >/dev/null \
    || die "Rescue dataset was not created."
  ok "Rescue clone '${POOL_NAME}/ROOT/${ROOT_ID}_rescue' created (selectable in ZFSBootMenu)."
  echo
  ok "Stage 2 complete — returning to Stage 1 to finalize."
}

# =====================================================================================
main() {
  case "${1:-}" in
    --stage2)   stage2 ;;
    --help|-h)  usage ;;
    "")         stage1 ;;
    *)          die "Unknown argument: $1 (use --help)";;
  esac
}
main "$@"
