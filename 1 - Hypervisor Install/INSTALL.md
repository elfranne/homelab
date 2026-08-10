# Installing with incus-install.sh

`incus-install.sh` adds the virtualization layer on top of the step-0 box:
[Incus](https://linuxcontainers.org/incus/) (the community LXD fork) for running
system containers and virtual machines. It installs the Debian Trixie native
`incus` package, backs it with a dedicated dataset on the **existing encrypted ZFS
pool**, and initialises it with two ready-to-use networks. It is interactive and
fail-fast: each phase pauses for confirmation and any error aborts immediately.

Unlike [step 0](<../0 - OS Install/INSTALL.md>), this runs on the **already-booted
installed system**, not a live USB — so it is a single, quick stage. It only adds
packages and one ZFS dataset; **it does not wipe disks or change the host's own
network configuration.**

## What it sets up

- **Incus** from Debian Trixie `main` (6.0 LTS). Installing it pulls in the QEMU/OVMF
  dependencies, so both containers *and* virtual machines work.
- **Storage** on a dedicated dataset on your existing pool — `<pool>/incus`, e.g.
  `zroot/incus`. The pool name is **auto-detected** from the booted root dataset, so
  it works whatever you named the pool in step 0. Because it lives on the encrypted
  pool, all Incus data inherits that encryption.
- **Two networks / profiles:**
  - **`default` — NAT.** Guests sit behind a managed bridge (`incusbr0`) on a private
    subnet with outbound NAT. Nothing on your LAN is exposed; reach services via port
    forwards or a reverse proxy. The **host can talk to these guests.**
  - **`lan` — macvlan.** Guests get a **real IP on your LAN** (from your router's
    DHCP) via a macvlan interface on the host's uplink NIC. This needs **no change to
    the host's static networking**, so it can't break your SSH / dropbear access.
    Caveat: by design, macvlan guests can reach the LAN and each other but **not the
    host itself** — if you need host↔guest traffic, use the `default` (NAT) profile.
- **Accelerator profiles (GPU / NPU).** On hardware with an AMD GPU and/or XDNA NPU
  — the target box is a [Minisforum N5 Pro](https://www.minisforum.com/products/n5-pro)
  (Ryzen AI 9 HX PRO 370: Radeon 890M iGPU + a 50-TOPS XDNA2 NPU) — the script
  creates reusable **add-on profiles** that pass those devices into **containers**:
  `gpu` (the `/dev/dri` render node, for VAAPI transcoding) and `npu`
  (`/dev/accel/accel0`). You stack them onto an instance, e.g.
  `incus launch images:debian/13 c1 -p default -p gpu`. See
  [GPU and NPU access](#gpu-and-npu-access) for the details, the VM story, and the
  kernel requirement for the NPU.
- **Local management.** Your admin user is added to the `incus-admin` group so it can
  drive Incus over the local unix socket. **No remote TLS port is opened** — manage
  remotely later over SSH if you want.

## Requirements

- A machine already installed per [step 0](<../0 - OS Install/INSTALL.md>): Debian
  Trixie booted from a **root-on-ZFS** boot environment (`<pool>/ROOT/<id>`). The
  script refuses to run anywhere else (this is also what stops it running on the live
  USB by mistake).
- **root** on that system (`sudo`).
- Network access (to fetch the `incus` package and, for the smoke test / first
  launches, container images).
- For the **`lan`/macvlan** profile to be useful, a LAN with **DHCP** (your router)
  so guests can pick up an address.
- For **virtual machines**, hardware virtualization (VT-x/AMD-V, plus nested virt if
  this box is itself a VM) — the script checks for `/dev/kvm` and warns if it's
  missing. Containers work regardless.
- For the **GPU profile**, the `amdgpu` driver + firmware must be up (the script
  installs `firmware-amd-graphics` and looks for `/dev/dri/renderD*`). For the **NPU
  profile**, the `amdxdna` driver must be present — it was mainlined in **Linux
  6.14**, but Debian Trixie ships **6.12**, so the NPU needs a newer kernel first
  (see [GPU and NPU access](#gpu-and-npu-access)). Missing devices are reported and
  their profile is skipped, never fatal.

## Getting the script onto the machine

Copy `incus-install.sh` to the box (it's the only file you need):

```sh
scp "1 - Hypervisor Install/incus-install.sh" <admin_user>@<nas-ip>:~/
```

Then, on the box:

```sh
chmod +x incus-install.sh
sudo ./incus-install.sh
```

Or skip the per-phase "proceed?" pauses:

```sh
sudo ASSUME_YES=1 ./incus-install.sh
```

Run `./incus-install.sh --help` at any time to print the header/usage block.

Optionally review the `CONFIG` block near the top of the script. **Editing it is not
required** — every value is prompted for at the start of the run with the CONFIG
value pre-filled as the default (press Enter to accept, or type a replacement).

| Variable | Meaning | Default |
|---|---|---|
| `INCUS_DATASET` | Dataset created under the detected pool (`<pool>/<this>`) | `incus` |
| `STORAGE_POOL` | Incus storage-pool name | `default` |
| `BRIDGE_NAME` | Managed NAT bridge for the `default` profile | `incusbr0` |
| `BRIDGE_IPV4` | `incusbr0` IPv4 — `auto` picks a free private subnet, or set e.g. `10.20.0.1/24` | `auto` |
| `LAN_PROFILE` | Name of the macvlan LAN profile | `lan` |
| `RUN_SMOKE_TEST` | `yes` / `no` / `ask` — launch+delete a throwaway container at the end | `ask` |
| `SETUP_ACCEL` | `yes` / `no` / `ask` — create the GPU/NPU passthrough profiles | `ask` |
| `GPU_PROFILE` | Name of the GPU add-on profile | `gpu` |
| `NPU_PROFILE` | Name of the NPU add-on profile | `npu` |
| `SETUP_NPU_KERNEL` | `no` / `ask` / `yes` — pull a backports kernel + ZFS to enable the NPU (env-overridable, e.g. `SETUP_NPU_KERNEL=ask`) | `no` |
| `ADMIN_USER` | User added to `incus-admin` (auto-detected from `$SUDO_USER`) | (detected) |
| `ASSUME_YES` | `1` skips per-phase pauses (env var, not CONFIG) | `0` |

The **ZFS pool** is not configurable here — it is auto-detected from the booted root.
The **macvlan parent NIC** is auto-detected as the interface owning the default route
(you're prompted only if that can't be determined).

## What it does, phase by phase

0. **Preflight** — checks you're root on Debian Trixie and booted from a `ROOT/`
   ZFS dataset, derives the **pool name** and verifies it's `ONLINE`, checks for
   `/dev/kvm` (warns if absent), **detects the GPU/NPU** device nodes, detects the
   **uplink NIC** for the macvlan profile, picks the **admin user**, then shows a
   summary to confirm.
1. **Install Incus** — `apt install incus` (with its QEMU deps), brings up the
   daemon, and verifies `incus info` responds.
2. **ZFS dataset** — creates `<pool>/incus` (if absent) and confirms it inherits the
   pool's encryption.
3. **Initialise Incus** — feeds a preseed to `incus admin init` that creates the
   `default` (zfs) storage pool, the `incusbr0` NAT network, and the `default`
   (NAT) and `lan` (macvlan) profiles, then verifies each exists.
4. **GPU / NPU profiles (optional)** — installs GPU firmware and, for each device
   that's present, creates a container add-on profile: `gpu` (a `physical` gpu
   device) and `npu` (a `unix-char` passthrough of `/dev/accel/accel0`). A device
   that isn't present is skipped with guidance.
5. **Local admin access** — adds the admin user to `incus-admin`.
6. **Smoke test (optional)** — launches a throwaway container on the NAT profile,
   waits for it to get an IP, then deletes it. Failure here only warns.
7. **NPU kernel (optional, default off)** — only if `SETUP_NPU_KERNEL` is enabled, the
   NPU is absent, and the kernel is < 6.14: pulls a newer kernel + matching ZFS from
   trixie-backports, verifies the ZFS DKMS build / initramfs key / rebuilt ZFSBootMenu
   image, and stops **without rebooting**. See
   [Enabling the NPU](#enabling-the-npu-newer-kernel-required).

## After install

1. Log the admin user out and back in (or run `newgrp incus-admin`) so the new group
   membership takes effect — otherwise `incus` commands report a permission error.
2. Launch things:
   ```sh
   incus launch images:debian/13 c1                    # container, NAT (default profile)
   incus launch images:debian/13 c2 -p lan             # container, real LAN IP (macvlan)
   incus launch images:debian/13 media -p default -p gpu  # container with the GPU (transcoding)
   incus launch images:debian/13 ai -p default -p npu     # container with the NPU
   incus launch images:debian/13 v1 --vm               # virtual machine
   incus list                                          # see instances and their IPs
   ```
3. Incus data lives on ZFS under `<pool>/incus` — it's covered by the pool's
   encryption and by your normal ZFS snapshots/backups.

### Want host↔guest over the LAN instead of macvlan?

macvlan is used for the `lan` profile precisely because it needs no change to the
host's networking. If you need the **host and its LAN guests to talk directly** over
the LAN, replace macvlan with a real host bridge: create a Linux bridge that
enslaves the uplink NIC and move the host's static IP onto it (via
`/etc/systemd/network/`), then point the profile's `eth0` at that bridge with
`nictype: bridged, parent: <br>`. Do this **at the console**, not over SSH — a
mistake takes the box off the network.

## GPU and NPU access

The [Minisforum N5 Pro](https://www.minisforum.com/products/n5-pro) has an **AMD
Ryzen AI 9 HX PRO 370** with two accelerators worth exposing to guests:

| Device | What it is | Host driver | Device node | Userspace |
|---|---|---|---|---|
| **GPU** | Radeon 890M iGPU (RDNA 3.5), AV1/H.265 encode+decode | `amdgpu` (in Trixie's 6.12) | `/dev/dri/renderD128` | Mesa VAAPI (`vainfo`, `ffmpeg -hwaccel vaapi`) |
| **NPU** | XDNA2 NPU, ~50 TOPS | `amdxdna` (**Linux ≥ 6.14**) | `/dev/accel/accel0` | AMD XRT / Ryzen AI |

The pragmatic split: **use containers for GPU/NPU workloads.** A container shares the
accelerator with the host and other containers via a passed-through device node — no
exclusive handover, no driver drama. A VM, by contrast, needs full PCI (VFIO)
passthrough that takes the *only* integrated device away from the host (see
[GPU/NPU in a VM](#gpunpu-in-a-vm-advanced)).

### Containers (the easy, supported path)

The installer creates two **add-on profiles** you stack onto a normal instance
(they carry only the device — the root disk and NIC come from `default`/`lan`):

```sh
# GPU — hardware transcoding (e.g. Jellyfin/Plex/ffmpeg via VAAPI)
incus launch images:debian/13 media -p default -p gpu
incus exec media -- apt install -y mesa-va-drivers vainfo
incus exec media -- vainfo                       # should list the AMD VAAPI profiles

# NPU — AMD XDNA inference
incus launch images:debian/13 ai -p default -p npu
incus exec ai -- ls -l /dev/accel/accel0         # the NPU node is present in the guest
# then install AMD's XRT / Ryzen AI userspace inside the guest
```

Under the hood the profiles are just:

```sh
incus profile device add gpu gpu gpu gputype=physical           # /dev/dri render node
incus profile device add npu npu unix-char source=/dev/accel/accel0
```

You can add the same devices to an existing instance instead of using the profiles:

```sh
incus config device add media gpu gpu gputype=physical
incus config device add ai   npu unix-char source=/dev/accel/accel0
```

Notes:
- Both accelerators are **shared** — several containers (and the host) can use them at
  once; there's no exclusive lock.
- For VAAPI in an **unprivileged** container the render node is mapped for you by the
  `gpu` device. If a workload still can't open it, make sure the app's user is in the
  guest's `render` group.
- The NPU userspace (XRT + the Ryzen AI stack) is young and moves fast — treat the
  `npu` container as experimental and follow AMD's current install steps inside it.

### Enabling the NPU: newer kernel required

Debian Trixie ships **Linux 6.12**; the `amdxdna` NPU driver was mainlined in
**6.14**. So out of the box `/dev/accel/accel0` won't exist and the installer skips
the `npu` profile. Enabling it means moving to a newer kernel from
**trixie-backports** — but on this box that is **not** a standalone kernel bump.

#### Why it's a coupled kernel + ZFS + ZFSBootMenu change

- **ZFS is a DKMS (out-of-tree) module.** OpenZFS only builds against kernels up to a
  version it declares. Install a kernel newer than your ZFS supports and `zfs.ko`
  **won't build** → the root pool can't import → **the OS won't boot**. Trixie's ZFS
  is 2.3.x (supports up to ~kernel 6.16); `trixie-backports` carries ZFS 2.4.x
  (up to ~kernel 7.0). **Fix: install the kernel *and* ZFS from backports in one apt
  transaction** so DKMS builds a matching module — never the kernel alone.
- **ZFSBootMenu is rebuilt too.** The step-0 hook `/etc/kernel/postinst.d/zbm` runs
  `generate-zbm` on every kernel install (after rotating the last-good image to
  `VMLINUZ-BACKUP.EFI`). `generate-zbm` builds ZBM against the newest kernel, so ZBM's
  own kernel + zfs move as well — another reason the DKMS build must succeed.
- **The OS kernel + initramfs live inside the ZFS boot environment** (`/boot`), and the
  initramfs re-embeds `/etc/zfs/zroot.key` so the new kernel can still unlock root.

Your rollback ladder (all built by step 0): the **pre-apt ZFS snapshot** (`apt_*`,
taken automatically before the install), the **`_rescue`** boot environment, and the
**"ZFSBootMenu Backup"** EFI entries (last-good ZBM). ZBM also lets you pick an older
kernel within the boot environment at its menu.

#### Automated path (recommended)

The installer has an opt-in, **default-off** phase for exactly this. It only acts when
the NPU is absent *and* the running kernel is < 6.14; it installs the kernel + ZFS
together, **verifies the result before you reboot**, and **does not reboot**:

```sh
sudo SETUP_NPU_KERNEL=ask ./incus-install.sh    # ask=confirm first; yes=no prompt
```

It reboots nothing and re-runs safely. After it finishes: **reboot**, confirm the NPU,
then **re-run the script** so it creates the `npu` profile (two-pass by nature — the
new kernel only takes effect after reboot).

Once the new kernel is verified, the phase also **pins the kernel to that minor
series** — see [Keeping the kernel in step with ZFS](#keeping-the-kernel-in-step-with-zfs).

#### Manual path (equivalent)

```sh
echo 'deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware' \
  | sudo tee /etc/apt/sources.list.d/backports.list
sudo apt update
# kernel + matching ZFS + initramfs + firmware, all from backports, one transaction:
sudo apt -t trixie-backports install \
     linux-image-amd64 linux-headers-amd64 zfs-dkms zfsutils-linux zfs-initramfs firmware-amd-graphics
```

**Verify BEFORE rebooting** (this is what the automated phase checks, and where "safe"
vs "maybe unbootable" is decided):

```sh
NEWK=$(ls -1 /lib/modules | sort -V | tail -1)
dkms status | grep zfs                       # zfs built for $NEWK
modinfo -k "$NEWK" zfs >/dev/null && echo "zfs.ko OK for $NEWK"
lsinitramfs /boot/initrd.img-$NEWK | grep etc/zfs/zroot.key   # key embedded
lsinitrd /boot/efi/EFI/zbm/VMLINUZ.EFI | grep -E 'zfs|dropbear'  # ZBM rebuilt with zfs (+dropbear)
```

If any check fails, **do not reboot into the new kernel** — boot the previous kernel
from the ZBM menu (or the "ZFSBootMenu Backup" EFI entry) and investigate.

Then reboot, verify `uname -r` (≥ 6.14), `lsmod | grep amdxdna`, and
`ls -l /dev/accel/accel0`, and **re-run `sudo ./incus-install.sh`** to create the
`npu` profile (or add it by hand with the `incus profile device add` line above). If
the driver loads but the device node doesn't appear, the NPU firmware is missing —
make sure the backports `firmware-amd-graphics`/`linux-firmware` is installed. Finally,
pin the kernel to its series as below so it can't later outpace ZFS.

#### Keeping the kernel in step with ZFS

ZFS is a DKMS module and **OpenZFS caps support at a kernel *minor*** — every `7.0.x`
builds, but the next minor (`7.1`) may not until OpenZFS (and thus backports
`zfs-dkms`) catches up. A kernel that gets ahead of ZFS means `zfs.ko` won't build and
the root pool won't import. Two things keep you safe:

- **Backports doesn't auto-upgrade.** It's `NotAutomatic` (low priority), so a plain
  `sudo apt upgrade` will **not** pull a newer backports kernel — the kernel only moves
  when you explicitly `apt -t trixie-backports …`. No silent drift.
- **The series pin.** The automated phase writes
  `/etc/apt/preferences.d/90-zfs-kernel-series` pinning the kernel meta-packages to the
  verified minor series, so `7.0.x` point/ABI updates (security fixes) still install —
  even on a plain `apt upgrade` — while `7.1+` is held back:

  ```
  Package: linux-image-amd64 linux-headers-amd64
  Pin: version 7.0.*
  Pin-Priority: 1001
  ```

  Check it with `apt-cache policy linux-image-amd64` (the `7.0.*` versions should sit at
  priority 1001, any `7.1` below). To **move to a newer series later**, do it
  deliberately: confirm `trixie-backports` `zfs-dkms` supports it, bump the version in
  that file (or remove it), re-run the upgrade, and **re-verify the DKMS build before
  rebooting**. If you'd rather freeze the *exact* kernel and forgo even in-series
  security updates, use `sudo apt-mark hold linux-image-amd64 linux-headers-amd64`
  instead.

### GPU/NPU in a VM (advanced)

Incus's `gpu`/`unix-char` passthrough above is **container-only**. Giving an
accelerator to a *VM* means full **VFIO PCI passthrough**, which unbinds the device
from the host and hands it to one guest exclusively:

1. Enable the IOMMU on the host. Step 0 sets the kernel command line through
   ZFSBootMenu, so add the IOMMU flags there rather than to GRUB:
   ```sh
   sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=0 amd_iommu=on iommu=pt" <pool>/ROOT
   sudo generate-zbm && sudo reboot
   ```
2. Find the device and its IOMMU group (`lspci -nnk`, then
   `ls /sys/kernel/iommu_groups/*/devices/`); everything in the group moves together.
3. Bind it to `vfio-pci` and attach it to the VM:
   ```sh
   incus config device add v1 gpu gpu gputype=physical pci=0000:c5:00.0   # GPU, by PCI addr
   incus config device add v1 npu pci  address=0000:c5:00.1               # NPU, raw PCI passthrough
   ```

The catch on this box: there is **one** iGPU and **one** NPU. Passing either to a VM
takes it away from the host and from every container, and integrated-GPU passthrough
on this platform is fragile. For the built-in devices, **prefer containers.** VFIO to
a VM makes sense mainly if you add a **discrete GPU** in the PCIe x16 slot — then the
iGPU stays with the host/containers and the dGPU goes to the VM.

## Building images with distrobuilder

The steps above provision containers *imperatively* — launch a stock image, then
`apt install` at runtime. For services you run for real, it's better to bake the OS +
packages + static config into a **reproducible, versioned Incus image** with
[`distrobuilder`](https://github.com/lxc/distrobuilder), and keep only the stateful,
secret-bearing bits as a thin provisioning step. That building/running machinery lives
here, in the hypervisor layer, because it's generic; each **image definition** is one
YAML file kept next to its service in [`../2 - Containers/`](<../2 - Containers/INSTALL.md>).

**Build needs root; the container still runs unprivileged.** `distrobuilder` needs host
root at *build time only* (it does `debootstrap`, `chroot`, `mknod`). The image it emits
carries no notion of privilege — Incus runs the resulting container **unprivileged**
(root inside → a mapped, harmless uid on the host), exactly like everything above. So
building as root does not change your runtime security posture.

**Image = disposable base; state = a separate volume.** Put the slow, deterministic layer
(OS, packages, static config) in the image; put persistent data on a **separate Incus
custom volume**. Then a base-image update is a rootfs swap that leaves your data alone.
Never bake secrets or per-instance setup into a shared image.

**Per-instance settings go in `user.*` keys, not in the image.** `incus rebuild` keeps an
instance's config and devices while replacing its rootfs, so a `user.*` key survives an
update — and an image can read one back at runtime through an **Incus template**, baked in
with distrobuilder's `template` generator:

```yaml
files:
  - generator: template
    name: caddyfile
    path: /etc/caddy/Caddyfile          # rendered inside the container…
    template:
      when: [create, start]             # …at create, and at every start
    content: |-
      { email {{ config_get("user.acme_email", "") }} }
```

Pass the values at deploy time with `--config user.acme_email=…`, and the container
regenerates its own configuration after every update with nothing re-running. Step 2 uses
exactly this for the proxy's Caddyfile and LAN address, and for Nextcloud's nginx vhost.

Between the two mechanisms, a rule of thumb: **settings** (a hostname, an address, an email)
are `user.*` keys; **secrets** (an API token, a database password) belong on the volume at
mode `600`, because `user.*` keys are visible in `incus config show` and travel inside
`incus export` tarballs and instance copies.

### The `image.sh` helper

`image.sh` (in this folder) wraps the whole lifecycle. `distrobuilder` is not packaged in
Debian `main`; on the first `build` the script offers to install it (a Go build into
`/usr/local/bin`) after a prompt. Only the build uses `sudo`; every `incus` call runs as
your incus-admin user.

```sh
# create/refresh the image from its definition (alias = the YAML's basename, "example")
"./image.sh" build "../2 - Containers/example.yaml"

# deploy an instance, with a persistent volume mounted for state
"./image.sh" deploy example demo --volume default/demo-data:/srv/data
curl http://<demo NAT IP>              # the baked page; image.sh prints the IP

# …and, for an image with templates, the per-instance settings they read back
"./image.sh" deploy caddy caddy --volume default/caddy-state:/var/lib/homelab \
    --config user.acme_email=me@example.com --config user.lan_ip=192.168.1.50/24

# ship a new base image to it: rebuild the image, then swap the rootfs
#   (edit the marker/serial in example.yaml first, then:)
"./image.sh" build  "../2 - Containers/example.yaml"
"./image.sh" update example demo       # -> incus rebuild: fresh rootfs, volumes kept

# tear it all down
"./image.sh" destroy demo --image example --volume default/demo-data

"./image.sh" status                    # images / instances / volumes at a glance
```

Under the hood these are just:

```sh
sudo distrobuilder build-incus example.yaml ./out
incus image import ./out/incus.tar.xz ./out/rootfs.squashfs --alias example
incus init example demo -p default   # + incus config device add … disk (the volume)
incus rebuild example demo           # update: rootfs from the new image, config/volumes kept
```

The `update` step is the point of the split: after it, the instance's
`/etc/homelab-image-version` marker shows the **new** image while a file written to the
mounted volume (`/srv/data`) still survives — fresh rootfs, preserved state.

**`update` refuses on an instance with snapshots.** `incus rebuild` does not run when the
instance has any, so a snapshot taken "just in case" before an upgrade is precisely what
blocks the upgrade. `image.sh update` checks first and tells you, rather than failing
obscurely. Snapshot the **state volume** instead — the rootfs is disposable by design:

```sh
incus storage volume snapshot default demo-data
```

**Reproducibility note.** `apt` still floats within the suite between builds; for a
build pinned to an exact point in time, point the definition's repositories at
[`snapshot.debian.org`](https://snapshot.debian.org/). Pin anything you fetch by hand in a
`post-packages` action too — a URL like `latest.tar.gz` would make the image a moving
target, which defeats the point of building one. That's optional hardening beyond the
example.

**Not every service should be an image.** This machinery suits services that carry little
or no state, where replacing the rootfs really is just an update. A stateful service — one
with a database, generated config holding secrets, or plugins installed at runtime — is
usually better as a plain container upgraded in place, because making a rootfs swap safe
means redirecting every one of those onto a volume first. Step 2 has one of each and
explains the choice: see
[Two deployment models](<../2 - Containers/INSTALL.md#two-deployment-models-and-how-to-choose>).

## Re-running

The script is safe to re-run. `incus admin init --preseed` is idempotent (it creates
what's missing and merges the rest), the ZFS dataset is only created if absent, the
`gpu`/`npu` profiles are only created/added when missing, and adding an already-member
user to a group is a no-op. Re-running is in fact the intended way to pick up the
`npu` profile after you've moved to a ≥ 6.14 kernel. If a run aborts, read the
`[FAIL]` line (it names the exact command and line that failed), resolve it, and run
again.
