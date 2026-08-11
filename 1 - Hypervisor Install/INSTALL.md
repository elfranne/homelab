# Installing with incus-install.sh

`incus-install.sh` adds a virtualization layer on top of the step-0 box:
[Incus](https://linuxcontainers.org/incus/) (the community LXD fork), for system containers and
virtual machines. It installs the Debian Trixie native `incus` package. It puts Incus storage on a
dedicated dataset on the existing encrypted ZFS pool. It also creates two ready-to-use networks. The
script is interactive and fail-fast: each phase pauses for confirmation, and any error stops the
script immediately.

Unlike [step 0](<../0 - OS Install/INSTALL.md>), this script runs on the already-booted installed
system, not a live USB. As a result, it is a single, quick stage. It only adds packages and one ZFS
dataset. **It does not wipe disks, and it does not change the host's own network configuration.**

## What it sets up

- **Incus**, from Debian Trixie `main` (6.0 LTS). The install pulls in the QEMU and OVMF
  dependencies, so both containers and virtual machines work.
- **Storage**, on a dedicated dataset on your existing pool: `<pool>/incus`, for example
  `zroot/incus`. The script detects the pool name automatically, from the booted root dataset, so
  this works no matter what you named the pool in step 0. Because this dataset lives on the
  encrypted pool, all Incus data inherits that encryption.
- **Two networks and profiles:**
  - **`default`: NAT.** Guests sit behind a managed bridge (`incusbr0`), on a private subnet with
    outbound NAT. Nothing on your LAN is exposed. Reach a service through a port forward or a
    reverse proxy. The host can talk to these guests.
  - **`lan`: macvlan.** Guests get a real IP address on your LAN, from your router's DHCP, through a
    macvlan interface on the host's uplink network card. This needs no change to the host's static
    networking, so it cannot break your SSH or dropbear access. Caveat: by design, macvlan guests
    can reach the LAN and each other, but not the host itself. If you need traffic between the host
    and a guest, use the `default` (NAT) profile.
- **Accelerator profiles (GPU and NPU).** On hardware with an AMD GPU, an XDNA NPU, or both, the
  script creates reusable add-on profiles that pass those devices into containers. The target box is
  a [Minisforum N5 Pro](https://www.minisforum.com/products/n5-pro), with a Ryzen AI 9 HX PRO 370: a
  Radeon 890M iGPU and a 50-TOPS XDNA2 NPU. The two profiles are `gpu` (the `/dev/dri` render node,
  for VAAPI transcoding) and `npu` (`/dev/accel/accel0`). Stack a profile onto an instance, for
  example `incus launch images:debian/13 c1 -p default -p gpu`. See
  [GPU and NPU access](#gpu-and-npu-access) for the details, the VM approach, and the kernel
  requirement for the NPU.
- **Local management.** The script adds your admin user to the `incus-admin` group, so this user can
  drive Incus over the local unix socket. The script does not open a remote TLS port. You can manage
  Incus remotely later, over SSH, if you want.

## Requirements

- A machine already installed through [step 0](<../0 - OS Install/INSTALL.md>): Debian Trixie,
  booted from a **root-on-ZFS** boot environment (`<pool>/ROOT/<id>`). The script refuses to run
  anywhere else. This is also what stops the script from running on the live USB by mistake.
- **root** on that system (`sudo`).
- Network access, to fetch the `incus` package and, for the smoke test or first launches, container
  images.
- For the `lan` (macvlan) profile to be useful, you need a LAN with **DHCP** (your router), so
  guests can get an address.
- For **virtual machines**, you need hardware virtualization (VT-x or AMD-V, plus nested
  virtualization if this box is itself a VM). The script checks for `/dev/kvm` and warns if this is
  missing. Containers work regardless.
- For the **GPU profile**, the `amdgpu` driver and firmware must be active. The script installs
  `firmware-amd-graphics` and looks for `/dev/dri/renderD*`. For the **NPU profile**, the `amdxdna`
  driver must be present. This driver was mainlined in Linux **6.14**, but Debian Trixie ships
  **6.12**, so the NPU needs a newer kernel first (see [GPU and NPU access](#gpu-and-npu-access)).
  The script reports a missing device and skips its profile. A missing device never stops the
  script.

## Getting the script onto the machine

Copy `incus-install.sh` to the box. This is the only file that you need:

```sh
scp "1 - Hypervisor Install/incus-install.sh" <admin_user>@<nas-ip>:~/
```

Then, on the box:

```sh
chmod +x incus-install.sh
sudo ./incus-install.sh
```

To skip the per-phase "proceed?" prompts, run:

```sh
sudo ASSUME_YES=1 ./incus-install.sh
```

Run `./incus-install.sh --help` at any time to print the header and usage block.

You can review the `CONFIG` block near the top of the script. **You do not need to edit it.** The
script prompts for every value at the start of the run, with the CONFIG value already filled in as
the default. Press Enter to accept the default, or type a replacement.

| Variable | Meaning | Default |
| --- | --- | --- |
| `INCUS_DATASET` | Dataset created under the detected pool (`<pool>/<this>`) | `incus` |
| `STORAGE_POOL` | Incus storage-pool name | `default` |
| `BRIDGE_NAME` | Managed NAT bridge for the `default` profile | `incusbr0` |
| `BRIDGE_IPV4` | `incusbr0` IPv4 address: `auto` picks a free private subnet, or set one, for example `10.20.0.1/24` | `auto` |
| `LAN_PROFILE` | Name of the macvlan LAN profile | `lan` |
| `RUN_SMOKE_TEST` | `yes`, `no`, or `ask`: launch and delete a throwaway container at the end | `ask` |
| `SETUP_ACCEL` | `yes`, `no`, or `ask`: create the GPU and NPU passthrough profiles | `ask` |
| `GPU_PROFILE` | Name of the GPU add-on profile | `gpu` |
| `NPU_PROFILE` | Name of the NPU add-on profile | `npu` |
| `SETUP_NPU_KERNEL` | `no`, `ask`, or `yes`: pull a backports kernel and ZFS to enable the NPU (you can override this with an environment variable, for example `SETUP_NPU_KERNEL=ask`) | `no` |
| `ADMIN_USER` | User added to `incus-admin` (auto-detected from `$SUDO_USER`) | (detected) |
| `ASSUME_YES` | `1` skips per-phase pauses (env var, not CONFIG) | `0` |

You cannot configure the **ZFS pool** here. The script detects it automatically, from the booted
root. The script also detects the **macvlan parent network card** automatically, as the interface
that owns the default route. The script prompts you only if it cannot determine this.

## What it does, phase by phase

0. **Preflight.** The script checks that you are root on Debian Trixie, and that the system booted
   from a `ROOT/` ZFS dataset. It finds the pool name and checks that the pool is `ONLINE`. It
   checks for `/dev/kvm`, and warns if this is absent. It detects the GPU and NPU device nodes, and
   the uplink network card for the macvlan profile. It picks the admin user. Then it shows a summary
   for you to confirm.
1. **Install Incus.** The script runs `apt install incus`, with its QEMU dependencies. It starts the
   daemon. It checks that `incus info` responds.
2. **ZFS dataset.** The script creates `<pool>/incus`, if this is absent. It checks that the dataset
   inherits the pool's encryption.
3. **Initialize Incus.** The script feeds a preseed file to `incus admin init`. This creates the
   `default` (zfs) storage pool, the `incusbr0` NAT network, and the `default` (NAT) and `lan`
   (macvlan) profiles. Then the script checks that each one exists.
4. **GPU and NPU profiles (optional).** The script installs GPU firmware. For each device that is
   present, it creates a container add-on profile: `gpu` (a `physical` gpu device) and `npu` (a
   `unix-char` passthrough of `/dev/accel/accel0`). The script skips a device that is not present,
   and prints guidance.
5. **Local admin access.** The script adds the admin user to `incus-admin`.
6. **Smoke test (optional).** The script launches a throwaway container on the NAT profile. It waits
   for the container to get an IP address. Then it deletes the container. A failure in this phase
   only prints a warning.
7. **NPU kernel (optional, default off).** This phase runs only if `SETUP_NPU_KERNEL` is enabled,
   the NPU is absent, and the kernel version is below 6.14. It pulls a newer kernel and matching ZFS
   from trixie-backports. It checks the ZFS DKMS build, the initramfs key, and the rebuilt
   ZFSBootMenu image. Then it stops. **It does not reboot the box.** See
   [Enabling the NPU](#enabling-the-npu-newer-kernel-required).

## After install

1. Log the admin user out and back in, or run `newgrp incus-admin`. This makes the new group
   membership take effect. **If you skip this step, `incus` commands report a permission error.**
2. Launch things:

   ```sh
   incus launch images:debian/13 c1                    # container, NAT (default profile)
   incus launch images:debian/13 c2 -p lan             # container, real LAN IP (macvlan)
   incus launch images:debian/13 media -p default -p gpu  # container with the GPU (transcoding)
   incus launch images:debian/13 ai -p default -p npu     # container with the NPU
   incus launch images:debian/13 v1 --vm               # virtual machine
   incus list                                          # see instances and their IPs
   ```

3. Incus data lives on ZFS, under `<pool>/incus`. The pool's encryption covers this data. Your
   normal ZFS snapshots and backups also cover it.

### Host and guest traffic over the LAN, instead of macvlan

This repository uses macvlan for the `lan` profile because it needs no change to the host's
networking. If you need the host and its LAN guests to talk directly, replace macvlan with a real
host bridge. Create a Linux bridge, add the uplink network card to it as a member, and move the
host's static IP onto the bridge (through `/etc/systemd/network/`). Then point the profile's `eth0`
device at that bridge, with `nictype: bridged, parent: <br>`.

**Do this work at the console, not over SSH. A mistake here takes the box off the network.**

## GPU and NPU access

The [Minisforum N5 Pro](https://www.minisforum.com/products/n5-pro) has an **AMD Ryzen AI 9 HX PRO
370** with two accelerators worth exposing to guests:

| Device | What it is | Host driver | Device node | Userspace |
| --- | --- | --- | --- | --- |
| **GPU** | Radeon 890M iGPU (RDNA 3.5), AV1 and H.265 encode and decode | `amdgpu` (in Trixie's 6.12) | `/dev/dri/renderD128` | Mesa VAAPI (`vainfo`, `ffmpeg -hwaccel vaapi`) |
| **NPU** | XDNA2 NPU, ~50 TOPS | `amdxdna` (**Linux 6.14 or later**) | `/dev/accel/accel0` | AMD XRT / Ryzen AI |

The practical choice is this: use containers for GPU and NPU workloads. A container shares the
accelerator with the host and other containers, through a passed-through device node. There is no
exclusive handover, and no driver conflict. A VM, in contrast, needs full PCI (VFIO) passthrough.
This passthrough takes the only integrated device away from the host (see
[GPU and NPU in a VM](#gpunpu-in-a-vm-advanced)).

### Containers (the easy, supported path)

The installer creates two add-on profiles. Stack one onto a normal instance. Each profile carries
only the device. The root disk and network card come from `default` or `lan`:

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

Internally, the profiles are just:

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

- Both accelerators are shared. Several containers, and the host, can use them at the same time.
  There is no exclusive lock.
- For VAAPI in an unprivileged container, the `gpu` device maps the render node for you. If a
  workload still cannot open the render node, check that the application's user is in the guest's
  `render` group.
- AMD's NPU userspace (XRT and the Ryzen AI stack) is new and changes quickly. The `npu` container
  is experimental, and AMD's current install steps apply inside it.

### Enabling the NPU: newer kernel required

Debian Trixie ships **Linux 6.12**. The `amdxdna` NPU driver was mainlined in **6.14**. By default,
`/dev/accel/accel0` does not exist, and the installer skips the `npu` profile. To enable the NPU,
you must move to a newer kernel from **trixie-backports**, but on this box that move is **not** a
simple, standalone kernel bump.

#### Why the kernel, ZFS, and ZFSBootMenu change together

- **ZFS is a DKMS (out-of-tree) module.** OpenZFS only builds against kernel versions up to the
  version it declares as supported. If you install a kernel newer than your ZFS version supports,
  `zfs.ko` does not build. Then the root pool does not import, and the OS does not boot. Trixie's
  ZFS is version 2.3.x, and it supports up to about kernel 6.16. `trixie-backports` carries ZFS
  2.4.x, which supports up to about kernel 7.0. **The fix: install the kernel and ZFS from
  backports in one apt transaction, so DKMS builds a matching module. Never install the kernel
  alone.**
- **The step-0 build also rebuilds ZFSBootMenu.** The step-0 hook `/etc/kernel/postinst.d/zbm` runs
  `generate-zbm` on every kernel install, after it rotates the last-good image to
  `VMLINUZ-BACKUP.EFI`. `generate-zbm` builds ZBM against the newest kernel, so ZBM's own kernel and
  ZFS move together too. This is another reason the DKMS build must succeed.
- **The OS kernel and initramfs live inside the ZFS boot environment** (`/boot`). The initramfs
  re-embeds `/etc/zfs/zroot.key`, so the new kernel can still unlock the root pool.

Your rollback ladder has three levels, and step 0 builds all of them:

- The pre-apt ZFS snapshot (`apt_*`), taken automatically before the install.
- The `_rescue` boot environment.
- The "ZFSBootMenu Backup" EFI entries (the last-good ZBM).

ZBM also lets you pick an older kernel from within the boot environment, at its menu.

#### Automated path (recommended)

The installer has an opt-in phase for exactly this, off by default. This phase acts only when the
NPU is absent and the running kernel is below 6.14. It installs the kernel and ZFS together. It
checks the result before you reboot. **It does not reboot the box:**

```sh
sudo SETUP_NPU_KERNEL=ask ./incus-install.sh    # ask=confirm first; yes=no prompt
```

The phase reboots nothing, and you can re-run it safely. After it finishes, reboot the box. Then
check that the NPU is present. Then re-run the script, so it creates the `npu` profile. This process
needs two passes, because the new kernel only takes effect after a reboot.

Once the phase checks the new kernel, it also pins the kernel to that minor version series. See
[Keeping the kernel in step with ZFS](#keeping-the-kernel-in-step-with-zfs).

#### Manual path (equivalent)

```sh
echo 'deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware' \
  | sudo tee /etc/apt/sources.list.d/backports.list
sudo apt update
# kernel + matching ZFS + initramfs + firmware, all from backports, one transaction:
sudo apt -t trixie-backports install \
     linux-image-amd64 linux-headers-amd64 zfs-dkms zfsutils-linux zfs-initramfs firmware-amd-graphics
```

**Check this before you reboot.** This check is what the automated phase runs, and it decides
whether the new kernel is safe, or maybe unbootable:

```sh
NEWK=$(ls -1 /lib/modules | sort -V | tail -1)
dkms status | grep zfs                       # zfs built for $NEWK
modinfo -k "$NEWK" zfs >/dev/null && echo "zfs.ko OK for $NEWK"
lsinitramfs /boot/initrd.img-$NEWK | grep etc/zfs/zroot.key   # key embedded
lsinitrd /boot/efi/EFI/zbm/VMLINUZ.EFI | grep -E 'zfs|dropbear'  # ZBM rebuilt with zfs (+dropbear)
```

If any check fails, **do not reboot into the new kernel.** Boot the previous kernel from the ZBM
menu, or from the "ZFSBootMenu Backup" EFI entry, and investigate the problem.

Then reboot. Check `uname -r` (6.14 or later), `lsmod | grep amdxdna`, and
`ls -l /dev/accel/accel0`. Then re-run `sudo ./incus-install.sh`, to create the `npu` profile. You
can also add the profile by hand, with the `incus profile device add` line above.

If the driver loads but the device node does not appear, the NPU firmware is missing. Check that the
backports `firmware-amd-graphics` or `linux-firmware` package is installed. Finally, pin the kernel
to its version series, as the next section describes, so the kernel cannot later outpace ZFS.

#### Keeping the kernel in step with ZFS

ZFS is a DKMS module, and OpenZFS caps support at one kernel minor version. Every `7.0.x` build
works, but the next minor version (`7.1`) can fail to build until OpenZFS, and so backports
`zfs-dkms`, catches up. If the kernel gets ahead of ZFS, `zfs.ko` does not build, and the root pool
does not import. Two things keep you safe:

- **Backports does not upgrade automatically.** It is `NotAutomatic` (low priority), so a plain
  `sudo apt upgrade` will **not** pull a newer backports kernel. The kernel only moves when you run
  `apt -t trixie-backports …` yourself. There is no silent drift.
- **The series pin.** The automated phase writes `/etc/apt/preferences.d/90-zfs-kernel-series`. This
  file pins the kernel meta-packages to the checked minor version series. As a result, `7.0.x` point
  and ABI updates, such as security fixes, still install, even on a plain `apt upgrade`. Meanwhile
  the file holds back `7.1` and later:

  ```none
  Package: linux-image-amd64 linux-headers-amd64
  Pin: version 7.0.*
  Pin-Priority: 1001
  ```

  Check the pin with `apt-cache policy linux-image-amd64`. The `7.0.*` versions sit at priority
  1001, and any `7.1` version sits below it.

  To move to a newer series later, do this deliberately. First, check that `trixie-backports`
  `zfs-dkms` supports the new series. Then change the version in that file, or remove the file.
  Re-run the upgrade, and check the DKMS build again before you reboot. If you want to freeze the
  exact kernel instead, and skip even in-series security updates, use
  `sudo apt-mark hold linux-image-amd64 linux-headers-amd64`.

### GPU/NPU in a VM (advanced)

Incus's `gpu` and `unix-char` passthrough, described above, works only in containers. Giving an
accelerator to a VM needs full **VFIO PCI passthrough**. This passthrough unbinds the device from
the host, and hands it to one guest exclusively:

1. Enable the IOMMU on the host. Step 0 sets the kernel command line through ZFSBootMenu, so add the
   IOMMU flags there rather than to GRUB:

   ```sh
   sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=0 amd_iommu=on iommu=pt" <pool>/ROOT
   sudo generate-zbm && sudo reboot
   ```

2. Find the device and its IOMMU group, with `lspci -nnk`, then
   `ls /sys/kernel/iommu_groups/*/devices/`. Everything in the group moves together.
3. Bind it to `vfio-pci` and attach it to the VM:

   ```sh
   incus config device add v1 gpu gpu gputype=physical pci=0000:c5:00.0   # GPU, by PCI addr
   incus config device add v1 npu pci  address=0000:c5:00.1               # NPU, raw PCI passthrough
   ```

The problem on this box is this: there is **one** iGPU and **one** NPU. Passing either device to a
VM takes it away from the host and from every container. Also, integrated-GPU passthrough is fragile
on this platform. **For the built-in devices, use containers, not VFIO.** VFIO to a VM makes sense
mainly if you add a **discrete GPU** in the PCIe x16 slot. In that case, the iGPU stays with the host
and the containers, and the discrete GPU goes to the VM.

## Building images with distrobuilder

The steps above provision containers imperatively: launch a stock image, then run `apt install` at
runtime. A service that you run for real needs more than this. Bake its OS, packages, and static
config into a **reproducible, versioned Incus image**, with
[`distrobuilder`](https://github.com/lxc/distrobuilder). Keep only the stateful, secret-bearing
parts as a thin provisioning step.

The machinery for building and running images lives here, in the hypervisor layer, because it is
generic. Each **image definition** is one YAML file, kept next to its service in
[`../2 - Containers/`](<../2 - Containers/INSTALL.md>).

**The build needs root access. The container still runs unprivileged.** `distrobuilder` needs host
root only at build time, because it runs `debootstrap`, `chroot`, and `mknod`. The image it produces
carries no notion of privilege. Incus runs the resulting container **unprivileged**, exactly like
every container above: root inside the container maps to a harmless UID on the host. So building the
image as root does not change your runtime security.

**The image is the disposable base. The state lives on a separate volume.** Put the slow,
deterministic layer (the OS, packages, and static config) in the image. Put persistent data on a
separate Incus custom volume. Then a base-image update is a rootfs swap that leaves your data alone.
Never bake a secret or per-instance setup into a shared image.

**Per-instance settings go in `user.*` keys, not in the image.** `incus rebuild` keeps an instance's
config and devices while it replaces the rootfs, so a `user.*` key survives an update. An image can
read a `user.*` key back at runtime, through an **Incus template** baked in with distrobuilder's
`template` generator:

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

Pass the values at deploy time, with `--config user.acme_email=…`. The container then regenerates
its own configuration after every update, with no script re-running. Step 2 uses exactly this
pattern, for the proxy's Caddyfile and LAN address, and for Nextcloud's nginx vhost.

Between the two mechanisms, use this general rule: a setting, such as a hostname, an address, or an
email, goes in a `user.*` key. A secret, such as an API token or a database password, belongs on the
volume, at mode `600`. This is because a `user.*` key is visible in `incus config show`, and it also
travels inside `incus export` archives and instance copies.

### The `image.sh` helper

`image.sh`, in this folder, wraps the whole lifecycle. `distrobuilder` is not packaged in Debian
`main`. On the first `build`, the script offers to install it, as a Go build into
`/usr/local/bin`, after a prompt. Only the build step uses `sudo`. Every `incus` call runs as your
incus-admin user.

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

Internally, these are just:

```sh
sudo distrobuilder build-incus example.yaml ./out
incus image import ./out/incus.tar.xz ./out/rootfs.squashfs --alias example
incus init example demo -p default   # + incus config device add … disk (the volume)
incus rebuild example demo           # update: rootfs from the new image, config/volumes kept
```

The `update` step is the point of this split. After it runs, the instance's
`/etc/homelab-image-version` marker shows the new image, while a file written to the mounted volume
(`/srv/data`) still survives. The rootfs is fresh, and the state is preserved.

**`update` refuses to run on an instance that has snapshots.** `incus rebuild` does not run when the
instance has any snapshot, so a snapshot taken "just in case" before an upgrade is exactly what
blocks the upgrade. `image.sh update` checks for this first, and tells you, instead of failing with
an unclear error. Snapshot the state volume instead. The rootfs is disposable by design:

```sh
incus storage volume snapshot default demo-data
```

**A note on reproducibility.** `apt` still floats within the suite between builds. For a build
pinned to an exact point in time, point the definition's repositories at
[`snapshot.debian.org`](https://snapshot.debian.org/). Also pin anything that you fetch by hand in a
`post-packages` action. A URL like `latest.tar.gz` makes the image a moving target, and this defeats
the purpose of building a fixed image. This extra step is optional hardening, beyond the example.

**Not every service needs to be an image.** This machinery suits a service that carries little or no
state, where a rootfs replacement really is just an update. A stateful service, with a database,
generated config that holds secrets, or plugins installed at runtime, is usually better as a plain
container, upgraded in place. This is because making a rootfs swap safe means moving every one of
those things onto a volume first. Step 2 has one service of each kind, and explains the choice. See
[Two deployment models](<../2 - Containers/INSTALL.md#two-deployment-models-and-how-to-choose>).

## Re-running

The script is safe to run again. `incus admin init --preseed` is idempotent: it creates what is
missing, and merges the rest. The ZFS dataset is only created if it is absent. The `gpu` and `npu`
profiles are only created or added when they are missing. Adding a user who is already a member of a
group has no effect. Running the script again is, in fact, the intended way to pick up the `npu`
profile, after you move to a kernel version of 6.14 or later. If a run stops with an error, read the
`[FAIL]` line. It names the exact command and line that failed. Fix the problem, and run the script
again.
