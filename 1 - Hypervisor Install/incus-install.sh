#!/usr/bin/env bash
#
# incus-install.sh — Incus hypervisor layer on the Debian Trixie ZFS-root box.
#
# Installs Incus (Debian Trixie native package, containers + VMs), backs it with a
# dedicated dataset on the EXISTING encrypted ZFS pool, and initialises it with two
# networks: a managed NAT bridge (default) and a macvlan 'lan' profile that puts
# guests straight on your LAN — without touching the host's static networking. On
# hardware with an AMD GPU/NPU (e.g. the Minisforum N5 Pro) it also creates 'gpu' and
# 'npu' add-on profiles that pass those accelerators through to containers.
#
# Interactive, fail-fast. Run as root ON THE INSTALLED SYSTEM (not a live USB),
# i.e. after step 0 (zbm-install.sh) has produced a booting root-on-ZFS box.
#
#   Usage:   sudo ./incus-install.sh              # normal run
#            sudo ASSUME_YES=1 ./incus-install.sh # skip per-phase pauses
#            ./incus-install.sh --help
#
#   All settings are prompted interactively at the start of the run; the values in
#   the CONFIG block below are only the defaults pre-filled at each prompt, so
#   editing them is optional.
#
# This adds packages and one ZFS dataset; it does not wipe disks or change the
# host's network config. The optional NPU phase (SETUP_NPU_KERNEL, default off) can
# additionally pull a newer kernel + ZFS from trixie-backports; it verifies the result
# and never reboots.
#
set -Eeuo pipefail

####################  CONFIG — DEFAULTS (prompted interactively)  ####################
# Every value below is only a DEFAULT: at the start of the run the script prompts for
# each one with the value here pre-filled in [brackets], so you can just press Enter
# to accept it or type a replacement. Editing this block changes the defaults; it is
# not required.
#
# The ZFS pool is NOT set here — it is auto-detected from the booted root dataset
# (e.g. 'zroot' from 'zroot/ROOT/debian'), so this works whatever you named the pool
# in step 0.

INCUS_DATASET="incus"          # dataset created under the detected pool, e.g. zroot/incus
STORAGE_POOL="default"         # Incus storage-pool name (backed by the dataset above)
BRIDGE_NAME="incusbr0"         # managed NAT bridge Incus creates for the default profile
BRIDGE_IPV4="auto"             # incusbr0 IPv4: 'auto' lets Incus pick a free private subnet,
                                # or set e.g. 10.20.0.1/24
LAN_PROFILE="lan"              # profile that puts guests on the LAN via macvlan
RUN_SMOKE_TEST="ask"           # yes | no | ask — launch+delete a throwaway container at the end

# Hardware accelerators (Minisforum N5 Pro: AMD Radeon 890M iGPU + XDNA2 NPU). When
# the devices are present the script creates reusable add-on profiles you stack onto
# an instance, e.g. 'incus launch images:debian/13 c1 -p default -p gpu'.
SETUP_ACCEL="ask"              # yes | no | ask — create GPU/NPU passthrough profiles
GPU_PROFILE="gpu"              # add-on profile: /dev/dri render node (container VAAPI transcoding)
NPU_PROFILE="npu"              # add-on profile: /dev/accel/accel0 (AMD XDNA NPU, needs kernel >= 6.14)

# The AMD XDNA NPU driver (amdxdna) needs Linux >= 6.14, but Trixie ships 6.12. When
# enabled AND the NPU is absent on an < 6.14 kernel, the final phase pulls a newer
# kernel + matching ZFS from trixie-backports (one apt transaction), verifies the ZFS
# DKMS build / initramfs key / rebuilt ZFSBootMenu image, and then STOPS — it does not
# reboot. Default off; opt in with e.g.  sudo SETUP_NPU_KERNEL=ask ./incus-install.sh
SETUP_NPU_KERNEL="${SETUP_NPU_KERNEL:-no}"   # no | ask | yes

# Admin user to grant Incus control (added to the incus-admin group). Auto-detected
# from $SUDO_USER when possible; prompted otherwise.
ADMIN_USER=""

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
  echo "${RED}Aborting. Review before re-running — see the re-run note in INSTALL.md.${RST}" >&2
  exit "$ec"
}
trap on_err ERR

# ---------- interaction ----------
confirm() { # confirm "prompt"   -> 0 if yes
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local ans=""
  read -r -p "$1 [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
pause() { confirm "${1:-Proceed with this phase?}" || die "Aborted by user."; }

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

ensure_profile() { # ensure an empty add-on profile exists (idempotent)
  incus profile show "$1" >/dev/null 2>&1 || incus profile create "$1" >/dev/null
}
profile_has_device() { # profile_has_device PROFILE DEV -> 0 if PROFILE already defines device DEV
  incus profile device list "$1" 2>/dev/null | grep -qx "$2"
}
first_render_node() { # print the first /dev/dri/renderD* node, or nothing
  local n
  for n in /dev/dri/renderD*; do [[ -e "$n" ]] && { printf '%s' "$n"; return; }; done
}
kernel_ge_614() { # 0 if the running kernel is >= 6.14 (where amdxdna is mainlined)
  local mm maj min
  mm="$(uname -r | grep -oE '^[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$mm" ]] || return 1
  maj="${mm%.*}"; min="${mm#*.}"
  (( maj > 6 || (maj == 6 && min >= 14) ))
}

resolve_pool() { # print the ZFS pool backing the booted root, or fail — confirms we're on the ZBM root
  local root_ds
  root_ds="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$root_ds" ]] || die "Could not determine the root filesystem source (findmnt / failed)."
  case "$root_ds" in
    */ROOT/*) : ;;
    *) die "Root ('$root_ds') is not a ZFSBootMenu boot-environment dataset (<pool>/ROOT/<id>). Run this on the installed step-0 system, not a live USB." ;;
  esac
  printf '%s' "${root_ds%%/*}"
}

detect_uplink() { # print the interface owning the default route, or empty
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

prompt_admin_user() { # set ADMIN_USER to a real, non-root account (default from $SUDO_USER)
  local default="${ADMIN_USER:-}"
  [[ -z "$default" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && default="$SUDO_USER"
  local u
  while :; do
    if [[ -n "$default" ]]; then
      read -r -p "Admin user to grant Incus control (added to incus-admin) [${default}]: " u </dev/tty || u=""
      u="${u:-$default}"
    else
      read -r -p "Admin user to grant Incus control (added to incus-admin): " u </dev/tty || u=""
    fi
    [[ "$u" == "root" ]] && { warn "Pick a non-root user (root already has full access)."; continue; }
    id -u "$u" >/dev/null 2>&1 || { warn "No such user: '$u'."; continue; }
    break
  done
  ADMIN_USER="$u"
}

# =====================================================================================
run() {
  echo "${BLD}Incus hypervisor installer — Debian Trixie on root-on-ZFS${RST}"

  # ---- Phase 0: preflight ----
  phase 0 "Preflight checks"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo ./incus-install.sh)."
  # Debian Trixie: the native 'incus' package (6.0 LTS) and its QEMU deps come from here.
  if ! grep -q '^ID=debian' /etc/os-release || ! grep -q 'VERSION_CODENAME=trixie' /etc/os-release; then
    die "Not Debian Trixie (check /etc/os-release). This targets the step-0 Trixie system."
  fi
  need_cmd zfs; need_cmd zpool
  POOL="$(resolve_pool)"
  [[ "$(zpool list -H -o health "$POOL" 2>/dev/null)" == "ONLINE" ]] \
    || die "ZFS pool '$POOL' is not ONLINE (zpool status '$POOL')."
  ok "On the installed root-on-ZFS system; backing pool is '$POOL' (ONLINE)."

  # Guard against re-creating a storage pool that already has a different backing.
  if zfs list -H -o name "$POOL/$INCUS_DATASET" >/dev/null 2>&1; then
    warn "Dataset '$POOL/$INCUS_DATASET' already exists — a previous run, perhaps. It will be reused."
  fi

  # KVM: needed for Incus VMs (containers work regardless). Non-fatal.
  if [[ -e /dev/kvm ]]; then
    ok "/dev/kvm present — hardware virtualization available for VMs."
  else
    warn "/dev/kvm not present — CONTAINERS will work, but VMs won't until CPU virtualization (VT-x/AMD-V, and nested virt if this box is itself a VM) is enabled."
  fi

  # Accelerators (N5 Pro: Radeon 890M iGPU + XDNA2 NPU). Detect the device nodes so the
  # summary reports what container passthrough profiles Phase 4 can create. Non-fatal.
  GPU_NODE=""; NPU_NODE=""
  GPU_NODE="$(first_render_node)"
  if [[ -n "$GPU_NODE" ]]; then
    ok "GPU render node present ($GPU_NODE) — amdgpu is up; container VAAPI transcoding available."
  else
    warn "No /dev/dri/renderD* node — amdgpu/firmware not ready. Phase 4 will (re)install GPU firmware; a reboot may be needed."
  fi
  if [[ -e /dev/accel/accel0 ]]; then
    NPU_NODE="/dev/accel/accel0"
    ok "NPU present ($NPU_NODE) — amdxdna driver loaded."
  else
    warn "No /dev/accel/accel0 — the AMD XDNA NPU needs Linux >= 6.14 (Trixie ships $(uname -r)). See INSTALL.md for the backports-kernel path; the NPU profile will be skipped."
  fi

  # macvlan parent for the LAN profile = the interface carrying the default route.
  UPLINK="$(detect_uplink)"
  if [[ -n "$UPLINK" && -d "/sys/class/net/$UPLINK" ]]; then
    ok "Uplink NIC for the '$LAN_PROFILE' (macvlan) profile: $UPLINK"
  else
    warn "Could not detect the uplink NIC (no default route?). You'll be asked to name it."
    local in
    while :; do
      read -r -p "Physical NIC to use as the macvlan parent for '$LAN_PROFILE': " in </dev/tty || in=""
      [[ -n "$in" && -d "/sys/class/net/$in" ]] && { UPLINK="$in"; break; }
      warn "No such interface: '${in:-<empty>}'."
    done
  fi

  prompt_admin_user

  echo
  echo "Settings:"
  printf '  %-16s %s\n' "Pool:"          "$POOL"
  printf '  %-16s %s\n' "Incus dataset:" "$POOL/$INCUS_DATASET"
  printf '  %-16s %s\n' "Storage pool:"  "$STORAGE_POOL"
  printf '  %-16s %s\n' "NAT bridge:"    "$BRIDGE_NAME ($BRIDGE_IPV4)"
  printf '  %-16s %s\n' "LAN profile:"   "$LAN_PROFILE (macvlan on $UPLINK)"
  printf '  %-16s %s\n' "Admin user:"    "$ADMIN_USER"
  printf '  %-16s %s\n' "GPU profile:"   "${GPU_NODE:+$GPU_PROFILE ($GPU_NODE)}${GPU_NODE:-<no GPU node — skipped>}"
  printf '  %-16s %s\n' "NPU profile:"   "${NPU_NODE:+$NPU_PROFILE ($NPU_NODE)}${NPU_NODE:-<no NPU node — needs kernel >= 6.14, skipped>}"
  confirm "Proceed with these settings?" || die "Not confirmed."

  # ---- Phase 1: install Incus ----
  phase 1 "Install Incus"
  pause
  apt update
  # Default 'apt install' pulls Recommends, which include qemu-system-x86/OVMF for VMs.
  DEBIAN_FRONTEND=noninteractive apt install -y incus
  need_cmd incus
  # Bring the daemon up (socket + service). Names are stable on Debian's packaging.
  systemctl enable --now incus.socket incus.service >/dev/null 2>&1 || true
  incus info >/dev/null 2>&1 || die "Incus daemon is not responding ('incus info' failed)."
  ok "Incus installed and the daemon is responding."

  # ---- Phase 2: ZFS dataset for Incus ----
  phase 2 "Create the ZFS dataset for Incus"
  if ! zfs list -H -o name "$POOL/$INCUS_DATASET" >/dev/null 2>&1; then
    # mountpoint=none: Incus manages the mountpoints of the child datasets it creates.
    zfs create -o mountpoint=none "$POOL/$INCUS_DATASET"
  fi
  zfs list -H -o name "$POOL/$INCUS_DATASET" >/dev/null 2>&1 \
    || die "Dataset '$POOL/$INCUS_DATASET' was not created."
  local enc; enc="$(zfs get -H -o value encryption "$POOL/$INCUS_DATASET" 2>/dev/null || true)"
  if [[ -n "$enc" && "$enc" != "off" ]]; then
    ok "Dataset '$POOL/$INCUS_DATASET' ready (encryption: $enc, inherited from the pool)."
  else
    warn "Dataset '$POOL/$INCUS_DATASET' ready but encryption is '$enc' — the pool is not encrypted?"
  fi

  # ---- Phase 3: initialise Incus (preseed) ----
  phase 3 "Initialise Incus (storage + networks + profiles)"
  pause
  # Idempotent: 'incus admin init --preseed' creates what's missing and merges the
  # rest, so this is safe to re-run. The 'lan' profile is self-contained (its own root
  # disk) so a guest can be launched with just '-p lan'.
  incus admin init --preseed <<EOF
storage_pools:
  - name: ${STORAGE_POOL}
    driver: zfs
    config:
      source: ${POOL}/${INCUS_DATASET}
networks:
  - name: ${BRIDGE_NAME}
    type: bridge
    config:
      ipv4.address: ${BRIDGE_IPV4}
      ipv4.nat: "true"
      ipv6.address: none
profiles:
  - name: default
    description: NAT — guests behind incusbr0 on a private subnet
    devices:
      root:
        path: /
        pool: ${STORAGE_POOL}
        type: disk
      eth0:
        name: eth0
        nictype: bridged
        parent: ${BRIDGE_NAME}
        type: nic
  - name: ${LAN_PROFILE}
    description: LAN — guests get a real LAN IP via macvlan on ${UPLINK}
    devices:
      root:
        path: /
        pool: ${STORAGE_POOL}
        type: disk
      eth0:
        name: eth0
        nictype: macvlan
        parent: ${UPLINK}
        type: nic
EOF
  incus storage list -f csv 2>/dev/null | grep -q "^${STORAGE_POOL}," \
    || die "Storage pool '$STORAGE_POOL' missing after init."
  incus network list -f csv 2>/dev/null | grep -q "^${BRIDGE_NAME}," \
    || die "Network '$BRIDGE_NAME' missing after init."
  incus profile list -f csv 2>/dev/null | grep -q "^default," \
    || die "Profile 'default' missing after init."
  incus profile list -f csv 2>/dev/null | grep -q "^${LAN_PROFILE}," \
    || die "Profile '$LAN_PROFILE' missing after init."
  ok "Storage '$STORAGE_POOL' (zfs), network '$BRIDGE_NAME' (NAT), profiles 'default' + '$LAN_PROFILE' ready."

  # ---- Phase 4: GPU / NPU accelerator profiles ----
  phase 4 "GPU / NPU accelerator profiles (containers)"
  # These are add-on profiles (device only, no root/nic) — stack them onto default/lan.
  # Container-only by design: a 'gpu' device in a VM PCI-passes the iGPU away from the
  # host, which isn't viable for the single integrated GPU (see INSTALL.md).
  local do_accel=0
  case "$SETUP_ACCEL" in
    yes) do_accel=1 ;;
    no)  do_accel=0 ;;
    *)   confirm "Create GPU/NPU passthrough profiles for containers?" && do_accel=1 ;;
  esac
  if (( do_accel )); then
    # GPU firmware for the Radeon 890M (step 0 enabled non-free-firmware in apt sources).
    DEBIAN_FRONTEND=noninteractive apt install -y firmware-amd-graphics \
      || warn "Could not install firmware-amd-graphics — install it by hand if the GPU node stays missing."
    # Re-check in case the node appeared since preflight.
    [[ -z "$GPU_NODE" ]] && GPU_NODE="$(first_render_node)"

    # GPU: a 'physical' gpu device gives the container the /dev/dri render node (VAAPI).
    if [[ -n "$GPU_NODE" ]]; then
      ensure_profile "$GPU_PROFILE"
      profile_has_device "$GPU_PROFILE" gpu \
        || incus profile device add "$GPU_PROFILE" gpu gpu gputype=physical >/dev/null
      profile_has_device "$GPU_PROFILE" gpu || die "Failed to add gpu device to profile '$GPU_PROFILE'."
      ok "GPU profile '$GPU_PROFILE' ready — e.g. incus launch images:debian/13 c1 -p default -p $GPU_PROFILE"
    else
      warn "GPU render node still absent — '$GPU_PROFILE' profile skipped. Reboot after the firmware install, then re-run to create it."
    fi

    # NPU: no native Incus device type — pass /dev/accel/accel0 as a unix-char device.
    if [[ -n "$NPU_NODE" ]]; then
      ensure_profile "$NPU_PROFILE"
      profile_has_device "$NPU_PROFILE" npu \
        || incus profile device add "$NPU_PROFILE" npu unix-char source="$NPU_NODE" >/dev/null
      profile_has_device "$NPU_PROFILE" npu || die "Failed to add npu device to profile '$NPU_PROFILE'."
      ok "NPU profile '$NPU_PROFILE' ready — e.g. incus launch images:debian/13 c1 -p default -p $NPU_PROFILE"
    else
      warn "NPU node absent (needs Linux >= 6.14; Trixie ships $(uname -r)) — '$NPU_PROFILE' profile skipped. See INSTALL.md for the backports-kernel path, then re-run."
    fi
  else
    log "GPU/NPU profile setup skipped."
  fi

  # ---- Phase 5: local admin access ----
  phase 5 "Grant '$ADMIN_USER' local Incus control"
  getent group incus-admin >/dev/null 2>&1 || die "Group 'incus-admin' does not exist (incus package problem?)."
  usermod -aG incus-admin "$ADMIN_USER"
  id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx incus-admin \
    || die "Failed to add '$ADMIN_USER' to incus-admin."
  ok "'$ADMIN_USER' added to incus-admin (local unix-socket access; no remote TLS port opened)."
  warn "'$ADMIN_USER' must log out and back in for the new group to take effect."

  # ---- Phase 6: optional smoke test ----
  phase 6 "Smoke test (optional)"
  local do_test=0
  case "$RUN_SMOKE_TEST" in
    yes) do_test=1 ;;
    no)  do_test=0 ;;
    *)   confirm "Launch a throwaway container to verify (needs to download an image)?" && do_test=1 ;;
  esac
  if (( do_test )); then
    local name="incus-smoke-$$"
    log "Launching test container '$name' on the default (NAT) profile…"
    if incus launch images:debian/13 "$name" -p default; then
      local tries=0 ip4=""
      while (( tries < 30 )); do
        ip4="$(incus list "$name" -c 4 -f csv 2>/dev/null | tr -d ' ' | grep -m1 -oE '^[0-9.]+' || true)"
        [[ -n "$ip4" ]] && break
        sleep 2; tries=$((tries+1))
      done
      if [[ -n "$ip4" ]]; then ok "Test container got IPv4 $ip4."; else warn "Test container did not report an IPv4 within ~60s."; fi
      incus delete -f "$name" >/dev/null 2>&1 || warn "Could not delete test container '$name' — remove it by hand."
      ok "Smoke test complete (container removed)."
    else
      warn "Test container failed to launch (image download / network?). Incus itself is installed and configured."
    fi
  else
    log "Smoke test skipped."
  fi

  # ---- Phase 7: optional NPU-enabling kernel upgrade (backports) ----
  phase 7 "Enable the NPU: newer kernel from backports (optional)"
  KERNEL_UPGRADED=0; KERNEL_SERIES=""
  if [[ -n "$NPU_NODE" ]]; then
    log "NPU already present ($NPU_NODE) — nothing to do."
  elif kernel_ge_614; then
    warn "Running kernel is $(uname -r) (>= 6.14) but /dev/accel/accel0 is absent — this is a firmware/driver issue, not a kernel-version one. See INSTALL.md; not touching the kernel."
  else
    local do_kernel=0
    case "$SETUP_NPU_KERNEL" in
      yes) do_kernel=1 ;;
      no)  do_kernel=0 ;;
      *)   # ask
        echo "${YLW}The AMD XDNA NPU needs Linux >= 6.14; this box runs $(uname -r).${RST}"
        echo "Proceeding upgrades the KERNEL + ZFS (from trixie-backports) in one step and"
        echo "rebuilds ZFSBootMenu. It does NOT reboot. If the ZFS DKMS build failed the box"
        echo "could be unbootable — recovery is the 'ZFSBootMenu Backup' EFI entry / the"
        echo "pre-apt ZFS snapshot (see INSTALL.md). This is verified before you reboot."
        confirm "Pull a backports kernel now to enable the NPU?" && do_kernel=1 ;;
    esac
    if (( do_kernel )); then
      # Enable trixie-backports (idempotent), matching step 0's source components.
      local bp=/etc/apt/sources.list.d/backports.list
      if ! grep -rqsE '^\s*deb\s.*trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        echo 'deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware' > "$bp"
        ok "Enabled trixie-backports ($bp)."
      else
        log "trixie-backports already enabled."
      fi
      apt update
      local oldk; oldk="$(uname -r)"
      # Kernel + matching ZFS + initramfs + firmware, all from backports in ONE
      # transaction, so DKMS builds zfs against the new kernel (a kernel newer than the
      # installed ZFS supports would otherwise fail to build and leave root unbootable).
      # The step-0 pre-apt hook snapshots root first; the kernel postinst hook rebuilds
      # ZFSBootMenu (rotating the last-good image to VMLINUZ-BACKUP.EFI). We do NOT run
      # generate-zbm ourselves — that would clobber that backup with an untested image.
      DEBIAN_FRONTEND=noninteractive apt -t trixie-backports install -y \
        linux-image-amd64 linux-headers-amd64 zfs-dkms zfsutils-linux zfs-initramfs firmware-amd-graphics

      # ---- verify the new kernel BEFORE any reboot ----
      local newk
      newk="$(printf '%s\n' /lib/modules/*/ | sed 's#/lib/modules/##; s#/##' | sort -V | tail -1)"
      [[ -n "$newk" ]] || die "Could not determine the newly installed kernel version."
      if [[ "$newk" == "$oldk" ]]; then
        warn "Backports did not provide a kernel newer than $oldk — nothing to enable. Skipping."
      else
        log "New kernel: $newk (was $oldk). Verifying before you reboot…"
        modinfo -k "$newk" zfs >/dev/null 2>&1 \
          || die "ZFS module did NOT build for $newk (check 'dkms status'). DO NOT reboot into $newk — boot the previous kernel from the ZFSBootMenu menu, or roll back the pre-apt 'apt_*' snapshot."
        local initrd="/boot/initrd.img-$newk"
        [[ -f "$initrd" ]] || die "No initramfs for $newk at $initrd."
        lsinitramfs "$initrd" 2>/dev/null | grep -q "etc/zfs/zroot.key" \
          || die "Encryption key is NOT in the $newk initramfs — the new kernel could not unlock root. DO NOT reboot; investigate zfs-initramfs before continuing."
        # ZFSBootMenu image the postinst hook rebuilt against the new kernel.
        local zbm_img="/boot/efi/EFI/zbm/VMLINUZ.EFI" zbm_contents=""
        [[ -f "$zbm_img" ]] || die "ZFSBootMenu image missing at $zbm_img after the kernel install — DO NOT reboot; use the 'ZFSBootMenu Backup' EFI entry and investigate generate-zbm."
        zbm_contents="$(lsinitrd "$zbm_img" 2>/dev/null || true)"
        grep -q zfs <<<"$zbm_contents" \
          || die "Rebuilt ZFSBootMenu image has no zfs module — it could not import the pool. DO NOT reboot; boot the 'ZFSBootMenu Backup' EFI entry and investigate."
        if grep -q dropbear <<<"$zbm_contents"; then
          ok "ZFSBootMenu rebuilt with zfs + dropbear (remote unlock intact)."
        else
          warn "Rebuilt ZFSBootMenu image has no dropbear — remote unlock may be unavailable; console unlock still works. Verify at first boot."
        fi
        KERNEL_UPGRADED=1
        ok "Kernel $newk installed and verified (ZFS built, key in initramfs, ZBM rebuilt). Not rebooting."

        # Pin the kernel to THIS minor series so it can't outpace OpenZFS. ZFS is a
        # DKMS module and OpenZFS caps support at a kernel MINOR: every X.Y.z builds,
        # but X.(Y+1) may not. Pinning the meta-packages to the verified series lets
        # point/ABI updates (security fixes) install while holding back the next minor.
        KERNEL_SERIES="$(grep -oE '^[0-9]+\.[0-9]+' <<<"$newk" || true)"
        if [[ -n "$KERNEL_SERIES" ]]; then
          local pin=/etc/apt/preferences.d/90-zfs-kernel-series
          cat > "$pin" <<EOF
# Keep the kernel on the ${KERNEL_SERIES}.x series so it can't outpace OpenZFS (ZFS is a
# DKMS module; OpenZFS caps support at a kernel MINOR). ${KERNEL_SERIES}.x point/ABI
# updates still install (security fixes); the next minor is held back. To move to a
# newer series later: confirm trixie-backports zfs-dkms supports it, then bump the
# version below (and re-verify the ZFS DKMS build before rebooting) or remove this file.
Package: linux-image-amd64 linux-headers-amd64
Pin: version ${KERNEL_SERIES}.*
Pin-Priority: 1001
EOF
          if grep -q "Pin: version ${KERNEL_SERIES}\\.\\*" "$pin" 2>/dev/null; then
            ok "Kernel pinned to the ${KERNEL_SERIES}.x series ($pin) — ${KERNEL_SERIES}.x updates flow, newer minors are held back."
          else
            warn "Could not confirm the kernel series pin in $pin — check it by hand (apt-cache policy linux-image-amd64)."
          fi
        else
          warn "Could not derive a minor series from '$newk' — kernel not pinned. Consider 'apt-mark hold linux-image-amd64' to stop it drifting past ZFS support."
        fi
      fi
    else
      log "Backports kernel upgrade skipped (SETUP_NPU_KERNEL=$SETUP_NPU_KERNEL). See INSTALL.md to enable the NPU later."
    fi
  fi

  # ---- finish ----
  echo
  ok "Incus hypervisor layer installed."
  echo
  echo "${BLD}Next:${RST}"
  echo "  1. Log out and back in (or 'newgrp incus-admin') so '$ADMIN_USER' can run incus."
  echo "  2. Container on the NAT bridge:   incus launch images:debian/13 c1"
  echo "  3. Container on the LAN (macvlan): incus launch images:debian/13 c2 -p ${LAN_PROFILE}"
  echo "       (macvlan guests reach the LAN and each other, but NOT the host itself —"
  echo "        for host<->guest use the default NAT profile.)"
  echo "  4. A virtual machine:             incus launch images:debian/13 v1 --vm"
  if [[ -n "$GPU_NODE" ]]; then
    echo "  5. GPU (transcoding) container:   incus launch images:debian/13 media -p default -p ${GPU_PROFILE}"
    echo "       verify inside:  vainfo   (needs the guest's VAAPI drivers, e.g. mesa-va-drivers)"
  fi
  if [[ -n "$NPU_NODE" ]]; then
    echo "  6. NPU container:                 incus launch images:debian/13 ai -p default -p ${NPU_PROFILE}"
    echo "       then install the AMD XRT / Ryzen AI userspace inside the guest."
  fi
  echo "  -  Incus data lives on ZFS at:    ${POOL}/${INCUS_DATASET}"
  echo "  -  GPU/NPU in a VM needs VFIO passthrough — see INSTALL.md (advanced)."
  if (( KERNEL_UPGRADED )); then
    echo
    echo "${BLD}${YLW}NPU kernel installed — action required:${RST}"
    echo "  a. REBOOT. ZFSBootMenu will ask for the ZFS passphrase (console, or dropbear"
    echo "     remote unlock) — it boots the new kernel by default. If it won't boot, pick"
    echo "     the previous kernel in the ZBM menu, or the 'ZFSBootMenu Backup' EFI entry."
    echo "  b. After boot, confirm:  uname -r   lsmod | grep amdxdna   ls -l /dev/accel/accel0"
    echo "  c. Re-run this script (it's idempotent) to create the '${NPU_PROFILE}' profile."
    if [[ -n "$KERNEL_SERIES" ]]; then
      echo "  -  Kernel pinned to the ${KERNEL_SERIES}.x series via /etc/apt/preferences.d/90-zfs-kernel-series"
      echo "     (${KERNEL_SERIES}.x updates flow; newer minors held back until you move deliberately)."
    fi
  fi
}

usage() {
  # print the header comment block (up to the 'set -Eeuo' line), stripping '# ' prefixes
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
