# CLAUDE.md

This file gives guidance to Claude Code (claude.ai/code) for work in this repository.

## What this repo is

This repository is a documented, step-by-step build of a Debian Trixie NAS and homelab box
(Minisforum N5 Pro). It contains only Bash installer scripts, distrobuilder YAML image definitions,
and Markdown walkthroughs. It has no application code, no build system, no test suite, and no
dependencies.

The one exception is `.devcontainer/`. It describes the environment for writing this repository:
linters, the Incus client, and Claude Code. This environment never runs on the NAS. Tools for
writing the repository stay in `.devcontainer/`, and the installer scripts stay free of
dependencies. See the "Development container" section of README.md.

The deliverable is a pair: the script, and the `INSTALL.md` file that explains it. A change to a
script's behavior, phases, or CONFIG block is not complete until the matching `INSTALL.md` file
matches it. If the step's summary changes, update the `README.md` table too.

## Layout and the step contract

Numbered directories are sequential build stages, each self-contained:

| Dir | Runs on | Produces |
|---|---|---|
| `0 - OS Install/` | Debian Trixie **live USB**, as root | Encrypted raidz1 ZFS root, ZFSBootMenu, and dropbear remote unlock |
| `1 - Hypervisor Install/` | The **installed system**, as root | Incus on `<pool>/incus`, NAT and macvlan profiles, gpu and npu profiles, and `image.sh` |
| `2 - Containers/` | Anywhere `incus` reaches the box, as an `incus-admin` user | Caddy ingress (image and `caddy-provision.sh`) and Nextcloud (`nextcloud-install.sh`, imperative) |

Each script's Phase 0 preflight step checks the outcome of the previous step. If the check fails,
the script stops and prints a message that names the step to run first. For example,
`incus-install.sh` refuses to run unless the system booted from a `<pool>/ROOT/<id>` dataset. The
step-2 scripts refuse to run unless the `default` and `lan` profiles exist. Keep this chain of
checks when you add a new step.

Directory names contain spaces. Always put quotes around each path, for example
`"1 - Hypervisor Install/image.sh"`.

## Verifying changes

You cannot run or test these scripts locally. The scripts wipe disks, need root access on the
target box, or drive a live Incus daemon. The only local check is syntax:

```sh
bash -n "0 - OS Install/zbm-install.sh"        # already allowlisted in .claude/settings.local.json
bash -n "1 - Hypervisor Install/incus-install.sh"
```

You can parse the image definitions and check them against distrobuilder's schema. Check for valid
generators: `dump`, `copy`, `template`, `hostname`, `hosts`, `remove`, `cloud-init`, `fstab`, and
`incus-agent`. Check for valid action triggers, in this order: `post-unpack`, then `post-update`,
then `post-packages`, then `post-files`. Check for valid template `when` values: `create`, `copy`,
and `start`. There is no `distrobuilder validate` subcommand, so parse the YAML file yourself.

PyYAML is available for this. It comes preinstalled in the dev container, through apt's
`python3-yaml` package, and it is also present in the workstation's system Python. If you are ever
on a machine without PyYAML, use `uv run --with pyyaml python -c …`. This is faster than building a
virtual environment.

Beyond this, you establish correctness by reading the code, not by running it. Trace the phase.
Check the idempotency guard. Check the `set -Eeuo pipefail` interactions (see below). Do not suggest
running a script only to check what it does.

## Script anatomy (every installer follows this skeleton)

```
#!/usr/bin/env bash          # header comment block = the --help text; explains what/where/why
set -Eeuo pipefail
CONFIG block                 # defaults only — every value is re-prompted at runtime
log/ok/warn/die/phase        # colour helpers, TTY-gated
on_err + trap ... ERR        # prints "[FAIL] line N: exit C while running: <cmd>"
confirm/require_yes/pause    # ASSUME_YES=1 short-circuits all three
helpers                      # need_cmd, cexec, cwrite, ct_exists, wait_for_ip, …
run() { phase 0 …; phase 1 … }
usage(); main "$@"           # dispatch on --help / subcommand
```

Non-negotiable contracts, because the docs promise them:

- **Idempotent.** Every script is safe to run again, and running it again is sometimes the intended
  way to use it. For example, run `incus-install.sh` again after a reboot into kernel version 6.14
  or later, to get the `npu` profile. Each script creates or adds an item only when it does not
  exist yet. It skips an item that already exists.
- **Fail-fast, no dry run.** An error stops the script through the ERR trap. The script does not
  continue after an error.
- **CONFIG values are defaults, not settings.** The script prompts the user for each value, with the
  CONFIG value already filled in `[brackets]`. To add a new option, add it in three places: the
  CONFIG block, the prompt flow, and the CONFIG table in `INSTALL.md`.
- **`set -e` hazards.** A helper whose "not found" result is normal must not return a nonzero exit
  code into an unguarded context. Commit `eeacd12` fixed exactly this problem. Use `|| true`, or use
  an explicit guard.
- **Interactive reads use `</dev/tty`**, because stdin can be a pipe or a chroot.
- **Secrets never go into the repository.** The script prompts for a secret with hidden input, or it
  reads the secret from the environment (`CF_API_TOKEN`). Then `cwrite` writes the secret directly
  into the container, at file mode `600`.
- **A phase that needs a reboot stops the script. It never reboots the box itself.** Example: the
  GPU and NPU kernel phase, in step 1.

`zbm-install.sh` has a different shape: it is two stages in one file. Stage 1 runs on the live USB.
It records every value it prompted for into `/mnt/root/zbm-install.env`. Then it chroots into the
new system and runs itself again as `--stage2`. Stage 2 calls `load_state()` to read that file back.
Stage 1 must write to that file anything that Stage 2 needs.

## Architecture facts that span files

**Networking: why the proxy has two network interfaces.** Step 1 creates two Incus profiles.

The `default` profile is NAT behind `incusbr0`. With this profile, the host can reach the guest
containers.

The `lan` profile is macvlan on the uplink network card. With this profile, guests get real LAN IP
addresses. By the design of macvlan, these guests cannot reach the host, and the host cannot reach
them.

A proxy on the `lan` profile alone cannot reach the NAT-only backend containers. For this reason,
the `caddy` container has two network interfaces. The `eth0` interface uses NAT: it carries the
default route, and it reaches both the backend containers and the internet. The `eth1` interface
uses macvlan: it holds a static LAN IP address with no gateway, so outbound traffic never has two
possible routes.

Every service container stays on the NAT-only `default` profile. You can reach a service container
only through the proxy. As a result, administer the proxy through `incus exec caddy -- …`. Do not
connect to the proxy's LAN IP from the host.

**TLS through DNS-01, with no open ports.** Caddy includes the Cloudflare DNS module. Caddy gets
real Let's Encrypt certificates by writing DNS records, through a scoped Cloudflare token.

To add a service, do three things: add one file at `/var/lib/homelab/conf.d/<host>.caddy` in the
proxy, run `systemctl reload caddy`, and add a grey-cloud A record that points at the proxy's LAN IP
address.

Each service gets its own certificate. Caddy does not use one wildcard certificate for every
service. The `conf.d/` directory is on the proxy's state volume, not in its root file system. As a
result, registered services survive an image update, and the built-in `Caddyfile` template imports
the directory from there.

**The kernel, ZFS, and ZFSBootMenu form one connected system.** ZFS uses DKMS, so ZFS support is
limited to one kernel minor version at a time. If the kernel gets ahead of ZFS, `zfs.ko` does not
build. Then the root pool does not import, and the box does not boot.

For this reason, the kernel and `zfs-dkms` must move together, in a single apt transaction from
backports. Before you reboot, check the DKMS build, the initramfs key, and the rebuilt ZBM image.
Then the kernel stays pinned to its verified minor version series, through
`/etc/apt/preferences.d/90-zfs-kernel-series`.

Step 0 installs a `/etc/kernel/postinst.d/zbm` hook. On every kernel install, this hook rotates
`VMLINUZ-BACKUP.EFI` and runs `generate-zbm` again.

The rollback ladder has three levels: the pre-apt `apt_*` ZFS snapshots, the `_rescue` boot
environment, and the "ZFSBootMenu Backup" EFI entries. Never change kernel packaging without keeping
all three levels in place.

**The kernel command line lives in ZFS, not in GRUB.** Set it with
`zfs set org.zfsbootmenu:commandline=… <pool>/ROOT`, then run `generate-zbm`.

**Accelerators work only in containers, not in VMs.** The `gpu` profile carries the `/dev/dri`
render node. The `npu` profile carries `/dev/accel/accel0`. Both are add-on profiles: stack one onto
`default` or `lan`, for example `incus launch … -p default -p gpu`.

VM passthrough needs VFIO, and it takes the box's only iGPU and NPU away from the host.

## Images: definitions vs machinery

This repository splits image definitions from image machinery on purpose. The documentation for
each cross-references the other.

- **Generic lifecycle machinery.** This lives in step 1, in
  `image.sh build|deploy|update|destroy|status`. This script wraps `distrobuilder build-incus`,
  `incus image import`, `incus init`, and `incus rebuild`. Only the `build` subcommand uses `sudo`.
  The resulting container still runs **unprivileged**.
- **Image definitions.** These live beside their service in `2 - Containers/`, one YAML file per
  image. The image alias is the YAML file's base name. `example.yaml` is the minimal reference.
  `caddy.yaml` is the real image definition.

### Not every service gets an image (this is deliberate)

**Services that hold little or no state get a distrobuilder image, and `incus rebuild` updates
them. Services with state stay as ordinary containers, and an upgrade happens in place.** Caddy is
the first kind. Nextcloud is the second kind.

Nextcloud was once converted to an image (`nextcloud.yaml` and `nextcloud-provision.sh`). The
project converted it back on purpose. **Do not propose converting it again.** The reasons are still
true:

- A rootfs swap destroys the PostgreSQL cluster, `config.php` (which holds the database password),
  and any web-installed app, unless every one of these moves onto a volume first. Redirecting all of
  them onto a volume needs a lot of extra machinery.
- If this repository converts Nextcloud to an image, the repository becomes responsible for
  Nextcloud releases, PHP compatibility, and PostgreSQL major version upgrades, instead of Debian. A
  PostgreSQL major version upgrade needs a manual `pg_upgrade` of the cluster on the volume.
- No one in the LXD or Incus community runs Nextcloud this way. That community uses distrobuilder
  for base OS images.
- The project also considered a VM for Nextcloud, and rejected this option. A VM takes the box's
  only iGPU away from both the host and every container, because accelerator profiles work only in
  containers. A VM also needs `incus-agent`, for the scripts that rely heavily on `incus exec`. A VM
  routes the data volume through virtiofs.

When you add a new service, ask this question: what happens if its root file system disappears? If
the answer is "nothing much," write a YAML image definition. If the service uses a database, write a
script shaped like `nextcloud-install.sh`, with an `upgrade` subcommand.

### For image-backed services: the three places state can live

`incus rebuild`, which is what `image.sh update` runs, destroys the entire root file system.
Exactly three things survive a rebuild, and `caddy.yaml` is built around these three things:

1. **Instance `user.*` keys hold per-instance settings.** At runtime, images read these settings
   back through Incus templates. Distrobuilder's `template` generator bakes these templates into the
   image, with `config_get("user.x", "…")` and `when: [create, start]`. This is why an update is
   self-healing: the fresh root file system renders its own config again, with no script re-running.
   Keep `pongo: false` on these entries. If `pongo: true` is set, the template renders at build time
   instead of at runtime.
2. **Attached custom volumes hold secrets and all mutable state.** Incus mounts this volume at
   `/var/lib/homelab`. Secrets go here, at file mode `600`. Never put a secret in a `user.*` key.
   Anyone can see a `user.*` key with `incus config show`, and it also travels inside `incus export`
   and instance copies.
3. **Instance devices hold the volume itself, and Caddy's macvlan `eth1`.**

In short: **the image holds only the disposable base: the OS, packages, and static config.
Everything else lives on a volume or in a `user.*` key.** Never bake a secret or per-instance setup
into a shared image.

The non-obvious risk is Caddy's ACME store. The image redirects this store through
`XDG_DATA_HOME`. If you lose this store, Caddy re-issues every certificate, against Let's Encrypt's
limit of 5 duplicate certificates per week. For the same reason, the `conf.d/` directory is also on
the volume. This is why `nextcloud-install.sh` registers its service at
`/var/lib/homelab/conf.d/`, not at `/etc/caddy/conf.d/`.

Two further constraints:

- **`incus rebuild` refuses to run when the instance has snapshots.** For an image-backed service,
  snapshot the volume, never the instance. `image.sh update` checks this before it runs, and reports
  the problem if you have an instance snapshot. The opposite rule holds for a service that runs in
  place. There, `incus snapshot nextcloud` is the correct way to roll back, because its root file
  system is never replaced.
- **Pin the version of anything that a `post-packages` action fetches.** A `latest` URL makes the
  image a moving target. This defeats the purpose of building a fixed image.

## Prose style

The Markdown explains reasoning. It is not a reference dump. Each walkthrough states why the author
made a choice, names the trade-off, and flags the caveat. Use tables for config knobs and for
phase-by-phase walkthroughs. Use fenced `sh` code blocks for anything the user types. Use bold text
for hazards. Match the existing style: dashes for asides, second person, and no marketing tone.
Write commit subjects in the imperative, and keep them terse, for example
"Add step 2: Caddy ingress + Nextcloud service container".
