# Installing with zbm-install.sh

`zbm-install.sh` installs Debian Trixie onto an encrypted, three-disk raidz1
ZFS root, booted via ZFSBootMenu (ZBM) with remote SSH unlock (dropbear) so
you can unlock and reboot the box without physical access. It is interactive
and fail-fast: every destructive step requires confirmation, and any error
aborts immediately rather than limping forward.

**This erases every disk you select. There is no dry-run mode.**

## Requirements

- A machine with **at least 3 disks** (NVMe/SATA — the script auto-detects
  the `p` partition suffix for NVMe) and **UEFI** firmware.
- A **Debian Trixie live ISO**, booted in UEFI mode. The live environment's
  `/etc/os-release` must report `ID=debian` and `VERSION_CODENAME=trixie` —
  the script refuses to run otherwise, since it writes Trixie apt sources
  and debootstraps Trixie.
- Network access from the live environment (the script installs packages
  and clones/downloads ZFSBootMenu + dracut-crypt-ssh).
- An SSH **public** key (`*.pub`) you control the private half of — this is
  what authorizes remote unlock.

## Getting the script onto the target machine

The live USB session is a fresh, throwaway environment — `zbm-install.sh`
and your SSH public key have to be copied into it every time. This ends
with the script and your `*.pub` key sitting together in the same
directory, e.g. `/home/user/`.

Push with scp from your workstation:

1. On the **live-booted target**, sshd isn't installed in the live session,
   so install it — the service starts automatically once installed. Then note
   its IP (the live user is `user` with the default password `live` — that's
   what the scp below authenticates as; root has no password and can't log in
   over SSH):

   ```sh
   sudo apt update && sudo apt install -y openssh-server
   ip -4 addr show                              # note the live session's IP
   ```

2. From your **workstation** (log in as the live user `user`, password `live`):

   ```sh
   scp zbm-install.sh ~/.ssh/id_ed25519.pub user@<live-ip>:~/
   ```

3. Back on the target, `ssh user@<live-ip>` or continue on the console —
   the files are now in `/home/user/`. Run the installer from there with
   `sudo ./zbm-install.sh`.

## 1. Prepare

1. Boot the target machine from the Debian Trixie live USB, UEFI mode, and
   get a root shell (`sudo -i` or similar).
2. Get `zbm-install.sh` onto that live session. See
   [Getting the script onto the target machine](#getting-the-script-onto-the-target-machine)
   below.
3. Put your SSH **public** key file (e.g. `id_ed25519.pub`) in the same
   directory as `zbm-install.sh`. Leave exactly one `*.pub` file there — if
   there are several, the script will ask you to pick one interactively
   (or refuse under `ASSUME_YES=1`; see below).
4. Optionally review the `CONFIG` block near the top of `zbm-install.sh`.
   **Editing it is not required** — every value below is prompted for
   interactively at the start of the run (the script shows the CONFIG value
   as the default in `[brackets]`, so you press Enter to accept it or type a
   replacement). Editing the block just changes those pre-filled defaults.

   | Variable | Meaning | Default |
   | --- | --- | --- |
   | `TIMEZONE` | System timezone | `Etc/UTC` |
   | `KEYMAP` | Console keymap — installed OS's TTY (written to both `/etc/vconsole.conf` and `/etc/default/keyboard`) *and* baked into the ZFSBootMenu image, so the passphrase prompt matches your physical keyboard. Must be a vconsole keymap name (validated at runtime against `localectl list-keymaps`), e.g. `us`, `dk`, `de`, `uk`; this equals the X11 layout code for most layouts | `dk` |
   | `POOL_NAME` | ZFS pool name | `zroot` |
   | `EFI_SIZE` | Per-disk EFI partition size | `+1g` |
   | `COMPRESSION` | ZFS compression algorithm | `zstd` |
   | `ENCRYPTION_ALG` | ZFS native encryption algorithm | `aes-256-gcm` |
   | `ZPOOL_COMPAT` | zpool feature compatibility set | `openzfs-2.2-linux` |
   | `ARC_MAX_BYTES` | ARC cap in bytes; empty = no cap (ZFS default, ~50% RAM) | `""` |
   | `DROPBEAR_PORT` | SSH port ZBM's dropbear listens on pre-boot | `222` |
   | `ZBM_VERSION` | Pinned ZFSBootMenu release tag | `v3.1.0` |
   | `CRYPT_SSH_COMMIT` | Pinned `dracut-crypt-ssh` commit | (see script) |
   | `ASSUME_YES` | `1` skips per-phase pauses (env var, not CONFIG) | `0` |

   The boot-environment dataset name is **not** configurable — it's
   auto-detected from the live environment's `/etc/os-release` `ID` (`debian`
   on a Trixie ISO). Disks, hostname, admin username, the remote-unlock
   network interface, and its static IP/gateway/netmask have no CONFIG
   default either — they're all prompted for interactively at runtime
   (see below).

## 2. Run

```sh
sudo ./zbm-install.sh
```

Or, to skip the non-destructive per-phase "proceed?" pauses (the disk-wipe
confirmation and `ERASE` prompt always still happen):

```sh
sudo ASSUME_YES=1 ./zbm-install.sh
```

Run `./zbm-install.sh --help` at any time to print the script's header/usage
block.

The script runs in two stages, back to back, in a single invocation:

### Stage 1 — live environment

Runs directly in the live USB session.

1. **Preflight** — checks you're root, UEFI-booted, and on a Trixie live
   image. Then, interactively:
   - Prompts for a **hostname or FQDN** (default `nas`; an FQDN like
     `nas.example.com` is accepted — its short label goes in `/etc/hostname`
     and the full name is resolved via `/etc/hosts`) and an **admin
     username** (validated, non-root, gets `sudo`).
   - Walks you through the **tunable settings** (timezone, keymap, pool
     name, EFI size, compression, encryption, zpool compat, ARC cap,
     dropbear port, ZBM/crypt-ssh versions), each pre-filled with its
     CONFIG-block default, then shows a summary to confirm.
   - Detects network interfaces, shows link state and any current IPv4
     address for each, and asks which NIC ZBM's remote unlock should use
     (it pre-selects the first one with an active link).
   - Prompts for a **static IP, gateway, and netmask** for that NIC,
     pre-filling the defaults from that NIC's current (usually DHCP) lease
     in the live environment — press Enter to reuse the DHCP address as a
     static config. There is no DHCP option for remote unlock (dropbear
     needs a static address this early in boot). The **same** static config
     is also applied to the installed OS (via systemd-networkd) on that NIC,
     so the box keeps the same IP after boot.
   - Detects disks, shows size/model/transport for each, and asks you to
     pick **at least 3** (or type `all`). Flags the disk it thinks is the
     live USB so you don't select it by mistake.
   - Reads your `*.pub` key, shows the key and fingerprint, and asks you to
     confirm it's the one to authorize.
2. **Phase 1** — installs ZFS tooling into the live environment and loads
   the `zfs` kernel module.
3. **Phase 2 (destructive)** — shows exactly which disks will be wiped and
   requires you to type `ERASE` (not just y/N) before partitioning. Cleans
   up any stale pool/array from a previous failed run, then partitions each
   disk (EFI + ZFS partitions).
4. **Phase 3** — builds a 3-way mirrored EFI System Partition (`/dev/md0`,
   mdadm metadata 1.0, so firmware can still read it) and formats it FAT32.
5. **Phase 4** — prompts for a ZFS **passphrase** (typed twice, ≥8 chars —
   you'll enter this at every boot) and creates the encrypted raidz1 pool.
6. **Phase 5** — creates the `ROOT`/boot-environment and `/home` datasets
   and sets `bootfs`.
7. **Phase 6** — re-imports the pool under `/mnt`, debootstraps Debian
   Trixie into it, copies in the hostid, resolv.conf, encryption key, your
   SSH key, and a recorded state file (disk list, identity, network config,
   and all the tunable settings) for Stage 2, then chroots into `/mnt` and
   **runs Stage 2 automatically**.
8. **Phase 7 (after Stage 2 returns)** — unmounts and exports the pool, and
   offers to reboot.

### Stage 2 — inside the chroot (automatic)

You won't invoke this yourself; Stage 1 calls `zbm-install.sh --stage2`
inside the chroot for you, after recovering the disk list, hostname, admin
username, network config, and tunable settings Stage 1 recorded.

1. **Phase 8** — sets hostname/hosts, apt sources (main + security +
   updates), locale, timezone, console keymap (`KEYMAP`, written to
   `/etc/vconsole.conf` and `/etc/default/keyboard`), installs
   `openssh-server`/`sudo`, and configures the installed OS's **static
   networking** — writing a `systemd-networkd` `.network` file that reuses
   the same IP/gateway/netmask from Stage 1 on the same NIC (with a resolver
   fallback to the gateway if the copied `resolv.conf` has no usable
   nameserver). Then creates the admin user and prompts you to **set a
   password** for both the admin user and root (retries on typo instead of
   aborting).
2. **Phase 9** — installs the Linux kernel and ZFS (DKMS), verifies the ZFS
   kernel module actually built for the installed kernel, applies the ARC
   cap if set, enables ZFS services, mounts the EFI partition, rebuilds the
   initramfs, and verifies the encryption key made it in. Also installs a
   pre-apt ZFS auto-snapshot hook (a `DPkg::Pre-Invoke` that snapshots the
   booted root before every `apt` operation and then prunes so only the
   newest 20 `apt_` snapshots remain) — one-reboot undo for package upgrades
   via a ZBM boot environment.
3. **Phase 10** — builds ZFSBootMenu from source (pinned to `ZBM_VERSION`)
    with the `dracut-crypt-ssh` module (pinned to `CRYPT_SSH_COMMIT`) and
    dracut's `i18n` module (for `KEYMAP`) baked in, generates dedicated
    dropbear host keys, installs your authorized key, writes the ZBM config
    with the static IP config from Stage 1 and `rd.vconsole.keymap` baked
    into the kernel command line, and builds the image. Verifies dropbear
    and the authorized key actually ended up inside the built image before
    continuing (and does a best-effort check for the keymap). Keeps a
    `VMLINUZ-BACKUP.EFI` copy and registers **both** primary and backup EFI
    boot entries on **every** disk, plus a kernel postinst hook that rotates
    the backup and rebuilds ZBM on every kernel update.
4. **Phase 11** — snapshots the freshly-installed root
    (`@base_install`) and clones it into a `_rescue` boot environment,
    selectable from the ZBM menu if the main system ever breaks.

Control then returns to Stage 1 to finalize and offer a reboot.

## 3. After install

Remove the USB stick and reboot. At boot:

1. ZFSBootMenu prompts for your ZFS passphrase **on the local console**
   first — verify this locally at least once. This is the one prompt where
   the console keymap (`KEYMAP`) actually matters: if your passphrase has
   punctuation or symbols, make sure they type correctly on the physical
   keyboard before you rely on it — there's no way to change the keymap
   interactively at this prompt.
2. To unlock remotely instead, SSH into dropbear while ZBM is waiting:

   ```sh
   ssh -p <DROPBEAR_PORT> root@<nas-ip>
   ```

   then run `zfsbootmenu` (or it may run automatically) and enter the
   passphrase there.
3. Once the OS has booted, connect normally on port 22:

   ```sh
   ssh <admin_user>@<nas-ip>
   ```

## Re-running / recovering from a failed attempt

The script is written to be safely re-run after a failure: Phase 2 detects
and cleans up a stale `/mnt` mount, an already-imported pool of the same
name, or a leftover `/dev/md0` from a previous attempt before wiping disks
again. If it aborts mid-run, read the `[FAIL]` message (it names the exact
line and command that failed) before re-running — the system may be left in
a partial state that's worth inspecting first.

If the main ZFSBootMenu image is ever unbootable after a kernel update, use
the firmware boot menu to select one of the **"ZFSBootMenu Backup"** EFI
entries, which points at the last known-good image.
