# Installing with zbm-install.sh

`zbm-install.sh` installs Debian Trixie onto an encrypted, three-disk raidz1 ZFS root. The system
boots through ZFSBootMenu (ZBM), with remote SSH unlock (dropbear). Remote unlock lets you unlock
and reboot the box without physical access. The script is interactive and fail-fast. Every
destructive step needs confirmation. Any error stops the script immediately. The script does not
continue after an error.

**This erases every disk you select. There is no dry-run mode.**

## Requirements

- A machine with **at least 3 disks** (NVMe or SATA) and **UEFI** firmware. The script detects the
  `p` partition suffix for NVMe disks automatically.
- A **Debian Trixie live ISO**, booted in UEFI mode. The live environment's `/etc/os-release` file
  must report `ID=debian` and `VERSION_CODENAME=trixie`. If it does not, the script refuses to run,
  because it writes Trixie apt sources and debootstraps Trixie.
- Network access from the live environment. The script installs packages, and it clones or
  downloads ZFSBootMenu and dracut-crypt-ssh.
- An SSH **public** key (`*.pub`). You must control the matching private key. This key authorizes
  remote unlock.

## Getting the script onto the target machine

The live USB session is a fresh, temporary environment. You must copy `zbm-install.sh` and your SSH
public key into it every time. When you finish, the script and your `*.pub` key sit together in the
same directory, for example `/home/user/`.

Push with scp from your workstation:

1. On the **live-booted target**, install sshd. The live session does not include it by default.
   The sshd service starts automatically after installation. Then find the session's IP address.

   The live user is `user`, with the default password `live`. The `scp` command below authenticates
   as this user. The `root` account has no password and cannot log in over SSH.

   ```sh
   sudo apt update && sudo apt install -y openssh-server
   ip -4 addr show                              # note the live session's IP
   ```
2. On your **workstation**, run this command. Log in as the live user `user`, with password `live`:
   ```sh
   scp zbm-install.sh ~/.ssh/id_ed25519.pub user@<live-ip>:~/
   ```
3. Go back to the target. Connect with `ssh user@<live-ip>`, or continue on the console. The files
   are now in `/home/user/`. Run the installer from there, with `sudo ./zbm-install.sh`.

## 1. Prepare

1. Boot the target machine from the Debian Trixie live USB, in UEFI mode. Get a root shell, for
   example with `sudo -i`.
2. Get `zbm-install.sh` onto that live session. See
   [Getting the script onto the target machine](#getting-the-script-onto-the-target-machine)
   below.
3. Put your SSH **public** key file, for example `id_ed25519.pub`, in the same directory as
   `zbm-install.sh`. Leave exactly one `*.pub` file in that directory. If there are several, the
   script asks you to pick one interactively. Under `ASSUME_YES=1`, the script refuses instead (see
   below).
4. You can review the `CONFIG` block near the top of `zbm-install.sh`, but this step is optional.
   **You do not need to edit it.** The script prompts you for every value below, at the start of the
   run. Each prompt shows the CONFIG value as a default, in `[brackets]`. Press Enter to accept the
   default, or type a replacement. If you edit the block, you only change these pre-filled defaults.

   | Variable | Meaning | Default |
   |---|---|---|
   | `TIMEZONE` | System timezone | `Etc/UTC` |
   | `KEYMAP` | Console keymap for the installed OS's TTY. The installer writes it to both `/etc/vconsole.conf` and `/etc/default/keyboard`, and also bakes it into the ZFSBootMenu image, so the passphrase prompt matches your physical keyboard. This value must be a vconsole keymap name, checked at runtime against `localectl list-keymaps`. Examples: `us`, `dk`, `de`, `uk`. For most layouts, this value equals the X11 layout code. | `dk` |
   | `POOL_NAME` | ZFS pool name | `zroot` |
   | `EFI_SIZE` | Per-disk EFI partition size | `+1g` |
   | `COMPRESSION` | ZFS compression algorithm | `zstd` |
   | `ENCRYPTION_ALG` | ZFS native encryption algorithm | `aes-256-gcm` |
   | `ZPOOL_COMPAT` | zpool feature compatibility set | `openzfs-2.2-linux` |
   | `ARC_MAX_BYTES` | ARC cap, in bytes. An empty value means no cap (the ZFS default, about 50% of RAM). | `""` |
   | `DROPBEAR_PORT` | SSH port ZBM's dropbear listens on pre-boot | `222` |
   | `ZBM_VERSION` | Pinned ZFSBootMenu release tag | `v3.1.0` |
   | `CRYPT_SSH_COMMIT` | Pinned `dracut-crypt-ssh` commit | (see script) |
   | `ASSUME_YES` | `1` skips per-phase pauses (env var, not CONFIG) | `0` |

   The boot-environment dataset name is **not** configurable. The script detects it automatically,
   from the live environment's `/etc/os-release` `ID` value (`debian` on a Trixie ISO). Several
   other items have no CONFIG default: the disks, the hostname, the admin username, the
   remote-unlock network interface, and its static IP address, gateway, and netmask. The script
   prompts you for all of these at runtime (see below).

## 2. Run

```sh
sudo ./zbm-install.sh
```

You can skip the non-destructive per-phase "proceed?" pauses. The disk-wipe confirmation and the
`ERASE` prompt still happen every time:

```sh
sudo ASSUME_YES=1 ./zbm-install.sh
```

Run `./zbm-install.sh --help` at any time. This prints the script's header and usage block.

The script runs in two stages, one after the other, in a single invocation:

### Stage 1: live environment

Runs directly in the live USB session.

1. **Preflight.** The script checks three things: the session runs as root, the machine booted in
   UEFI mode, and the live image is Trixie. Then it prompts you interactively, in this order:
   - A **hostname or FQDN** (default `nas`). You can enter a fully qualified name, for example
     `nas.example.com`. The script writes the short label to `/etc/hostname`, and resolves the full
     name through `/etc/hosts`.
   - An **admin username**. The script checks that the name is valid and not `root`, then gives this
     user `sudo` access.
   - The **tunable settings**: timezone, keymap, pool name, EFI size, compression, encryption, zpool
     compatibility, ARC cap, dropbear port, and the ZBM and crypt-ssh versions. Each prompt shows its
     CONFIG-block default first. Then the script shows a summary for you to check.
   - The **network interface** for ZBM's remote unlock. The script detects the interfaces, shows the
     link state and any current IPv4 address for each, and pre-selects the first interface with an
     active link.
   - A **static IP address, gateway, and netmask** for that interface. The script pre-fills these
     from the interface's current lease, usually a DHCP lease, in the live environment. Press Enter
     to reuse the DHCP address as a static value. There is no DHCP option for remote unlock, because
     dropbear needs a static address this early in boot. The script applies this same static
     configuration to the installed OS, through systemd-networkd, on the same interface. As a
     result, the box keeps the same IP address after boot.
   - The **disks**. The script detects them, shows the size, model, and transport for each, and asks
     you to pick at least 3, or type `all`. It flags the disk it thinks is the live USB, so you do
     not select it by mistake.
   - Your **`*.pub` key**. The script reads the key, shows the key and its fingerprint, and asks you
     to confirm that this is the key to authorize.
2. **Phase 1.** The script installs ZFS tooling into the live environment, and loads the `zfs`
   kernel module.
3. **Phase 2 (destructive).** The script shows exactly which disks it will erase, and requires you
   to type `ERASE`, not just `y` or `N`, before it partitions any disk. First, the script cleans up
   any stale pool or array from a previous failed run. Then it partitions each disk, into an EFI
   partition and a ZFS partition.
4. **Phase 3.** The script builds a 3-way mirrored EFI System Partition, at `/dev/md0`, with mdadm
   metadata version 1.0 so the firmware can still read it. Then it formats this partition as FAT32.
5. **Phase 4.** The script prompts for a ZFS **passphrase**, typed twice, with 8 characters or more.
   You will enter this passphrase at every boot. Then the script creates the encrypted raidz1 pool.
6. **Phase 5.** The script creates the `ROOT` boot-environment dataset and the `/home` dataset, and
   sets `bootfs`.
7. **Phase 6.** The script re-imports the pool under `/mnt`, and debootstraps Debian Trixie into it.
   It copies in the hostid, `resolv.conf`, the encryption key, your SSH key, and a recorded state
   file. This state file holds the disk list, the identity information, the network config, and all
   the tunable settings, for Stage 2 to use. Then the script chroots into `/mnt`, and **runs Stage 2
   automatically**.
8. **Phase 7 (after Stage 2 returns).** The script unmounts and exports the pool, and offers to
   reboot the machine.

### Stage 2: inside the chroot (automatic)

You do not run this stage yourself. Stage 1 calls `zbm-install.sh --stage2` inside the chroot for
you. Before this call, the script reads back the disk list, hostname, admin username, network
config, and tunable settings that Stage 1 recorded earlier.

8. **Phase 8.** The script sets the hostname and the `/etc/hosts` file. It writes the apt sources:
   main, security, and updates. It sets the locale, the timezone, and the console keymap (`KEYMAP`),
   writing this keymap to both `/etc/vconsole.conf` and `/etc/default/keyboard`. It installs
   `openssh-server` and `sudo`.

   The script also configures the installed OS's **static networking**. It writes a
   `systemd-networkd` `.network` file that reuses the same IP address, gateway, and netmask from
   Stage 1, on the same network interface. If the copied `resolv.conf` file has no usable nameserver,
   the script falls back to the gateway as the resolver.

   Then the script creates the admin user, and prompts you to **set a password** for both the admin
   user and `root`. If you type the password wrong, the script asks again. It does not stop the
   install.
9. **Phase 9.** The script installs the Linux kernel and ZFS through DKMS. It checks that the ZFS
   kernel module built for the installed kernel. If you set an ARC cap, the script applies it. The
   script enables the ZFS services, mounts the EFI partition, rebuilds the initramfs, and checks that
   the encryption key transferred correctly.

   The script also installs a pre-apt ZFS auto-snapshot hook. This hook is a `DPkg::Pre-Invoke`
   entry. It snapshots the booted root before every `apt` operation, then prunes old snapshots so
   only the newest 20 `apt_` snapshots remain. With this hook, you can undo a package upgrade with
   one reboot, into a ZBM boot environment.
10. **Phase 10.** The script builds ZFSBootMenu from source, pinned to `ZBM_VERSION`. It bakes in the
    `dracut-crypt-ssh` module, pinned to `CRYPT_SSH_COMMIT`, and dracut's `i18n` module, for
    `KEYMAP`. It generates dedicated dropbear host keys, and installs your authorized key. It writes
    the ZBM config, with the static IP configuration from Stage 1 and `rd.vconsole.keymap` baked
    into the kernel command line. Then it builds the image.

    Before it continues, the script checks that dropbear and the authorized key are both inside the
    built image. It also runs a best-effort check on the keymap.

    The script keeps a `VMLINUZ-BACKUP.EFI` copy, and registers both a primary and a backup EFI boot
    entry on every disk. It also installs a kernel postinst hook. This hook rotates the backup and
    rebuilds ZBM on every kernel update.
11. **Phase 11.** The script snapshots the freshly installed root, as `@base_install`, and clones it
    into a `_rescue` boot environment. If the main system ever breaks, you can select this boot
    environment from the ZBM menu.

Control then returns to Stage 1, to finish the install and offer a reboot.

## 3. After install

Remove the USB stick. Then reboot the machine. At boot:

1. ZFSBootMenu first prompts for your ZFS passphrase **on the local console**. **Check this locally
   at least once before you rely on remote unlock.** This is the one prompt where the console keymap
   (`KEYMAP`) matters. If your passphrase has punctuation or symbols, check that they type correctly
   on the physical keyboard. You cannot change the keymap interactively at this prompt.
2. To unlock the box remotely instead, connect to dropbear by SSH while ZBM is waiting:
   ```sh
   ssh -p <DROPBEAR_PORT> root@<nas-ip>
   ```
   Then run `zfsbootmenu`. This command can also start automatically. Enter the passphrase there.
3. After the OS boots, connect normally, on port 22:
   ```sh
   ssh <admin_user>@<nas-ip>
   ```

## Re-running and recovering from a failed attempt

You can safely run the script again after a failure. Phase 2 detects and cleans up a stale `/mnt`
mount, an already-imported pool of the same name, or a leftover `/dev/md0` from a previous attempt,
before it wipes disks again.

If the script stops mid-run, read the `[FAIL]` message first. This message names the exact line and
command that failed. The system can be left in a partial state, so check this state before you run
the script again.

If the main ZFSBootMenu image becomes unbootable after a kernel update, use the firmware boot menu.
Select one of the **"ZFSBootMenu Backup"** EFI entries. This entry points at the last known-good
image.
