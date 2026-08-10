# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A documented, step-by-step build of a Debian Trixie NAS/homelab box (Minisforum N5 Pro).
It contains **only Bash installer scripts, distrobuilder YAML image definitions, and Markdown
walkthroughs** — no application code, no build system, no test suite, no dependencies.

The deliverable is the *pair*: each script plus the `INSTALL.md` that explains it. A change to
a script's behaviour, phases, or CONFIG block is incomplete until the sibling `INSTALL.md`
(and, if the step's summary changes, the `README.md` table) matches it.

## Layout and the step contract

Numbered directories are sequential build stages, each self-contained:

| Dir | Runs on | Produces |
|---|---|---|
| `0 - OS Install/` | Debian Trixie **live USB**, as root | Encrypted raidz1 ZFS root + ZFSBootMenu + dropbear remote unlock |
| `1 - Hypervisor Install/` | The **installed system**, as root | Incus on `<pool>/incus`, NAT + macvlan profiles, gpu/npu profiles; plus `image.sh` |
| `2 - Containers/` | Anywhere `incus` reaches the box, as an `incus-admin` user | Caddy ingress (image + `caddy-provision.sh`) and Nextcloud (`nextcloud-install.sh`, imperative) |

Each script's **Phase 0 preflight asserts the previous step's outcome** and dies with a message
naming the step to run first (e.g. `incus-install.sh` refuses unless booted from a `<pool>/ROOT/<id>`
dataset; step-2 scripts refuse unless the `default`/`lan` profiles exist). Preserve that chain when
adding a step.

Directory names contain spaces — always quote paths (`"1 - Hypervisor Install/image.sh"`).

## Verifying changes

Nothing here can be executed or tested locally: the scripts wipe disks, need root on the target
box, or drive a live Incus daemon. The only local check is syntax:

```sh
bash -n "0 - OS Install/zbm-install.sh"        # already allowlisted in .claude/settings.local.json
bash -n "1 - Hypervisor Install/incus-install.sh"
```

The image definitions can at least be parsed and checked against distrobuilder's schema — valid
generators (`dump`/`copy`/`template`/`hostname`/`hosts`/`remove`/`cloud-init`/`fstab`/`incus-agent`),
valid action triggers (`post-unpack` → `post-update` → `post-packages` → `post-files`, in that
order), valid template `when` values (`create`/`copy`/`start`). There is no `distrobuilder validate`
subcommand, and no PyYAML in the system Python — use a throwaway venv in the scratchpad.

Beyond that, correctness is established by **reading**: trace the phase, check the idempotency
guard, check `set -Eeuo pipefail` interactions (see below). Never propose "just run it to see".

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

- **Idempotent.** Every script is documented as safe to re-run, and re-running is sometimes the
  *intended* workflow (e.g. `incus-install.sh` after a reboot into a ≥6.14 kernel, to pick up the
  `npu` profile). Create/add only when missing; skip when already done.
- **Fail-fast, no dry-run.** Errors abort via the ERR trap rather than limping forward.
- **CONFIG values are defaults, not settings.** The user is prompted for each with the CONFIG value
  pre-filled in `[brackets]`. Adding a knob means adding it to the CONFIG block, the prompt flow,
  *and* the CONFIG table in `INSTALL.md`.
- **`set -e` hazards.** Helpers whose "not found" case is normal must not return non-zero into an
  unguarded context — commit `eeacd12` fixed exactly that. Use `|| true` / explicit guards.
- **Interactive reads use `</dev/tty`**, since stdin may be a pipe or a chroot.
- **Secrets are never stored in the repo.** Prompted hidden or taken from the environment
  (`CF_API_TOKEN`), written straight into the container at mode `600` via `cwrite`.
- **Phases that need a reboot stop; they never reboot** (the GPU/NPU kernel phase, step 1).

`zbm-install.sh` is the exception in shape: it is two stages in one file. Stage 1 runs in the live
USB, records everything it prompted for into `/mnt/root/zbm-install.env`, then chroots and re-invokes
itself as `--stage2`, which calls `load_state()` to recover it. Anything Stage 2 needs must be
written to that state file by Stage 1.

## Architecture facts that span files

**Networking (why the proxy is dual-homed).** Step 1 creates two profiles: `default` = NAT behind
`incusbr0` (host *can* reach these guests), and `lan` = macvlan on the uplink NIC (guests get real
LAN IPs but — by macvlan design — **cannot reach the host**, and the host cannot reach them). A
macvlan-only proxy therefore couldn't reach NAT-only backends, so the `caddy` container sits on
both: `eth0` NAT carries the default route and reaches backends + the internet; `eth1` macvlan holds
a static LAN IP with **no gateway**, so outbound traffic is never ambiguous. Every service container
stays NAT-only and is reached only through the proxy. Consequence: administer the proxy via
`incus exec caddy -- …`, never by connecting to its LAN IP from the host.

**TLS via DNS-01, no open ports.** Caddy (built with the Cloudflare DNS module) gets real Let's
Encrypt certs by writing DNS records through a scoped Cloudflare token. Adding a service = one file
at `/var/lib/homelab/conf.d/<host>.caddy` in the proxy + `systemctl reload caddy` + a grey-cloud A
record pointing at the proxy's LAN IP. Per-service certs, not a wildcard. That directory is on the
proxy's **state volume**, not in its rootfs, so registered services survive an image update — and the
baked `Caddyfile` template imports it from there.

**Kernel ↔ ZFS ↔ ZFSBootMenu are one coupled unit.** ZFS is DKMS and caps support at a kernel minor;
a kernel ahead of ZFS means `zfs.ko` won't build → root pool won't import → **unbootable**. So the
kernel and `zfs-dkms` must move in a *single* apt transaction from backports, the DKMS build /
initramfs key / rebuilt ZBM image must be verified **before** rebooting, and the kernel is pinned to
its verified minor series via `/etc/apt/preferences.d/90-zfs-kernel-series`. Step 0 installs a
`/etc/kernel/postinst.d/zbm` hook that rotates `VMLINUZ-BACKUP.EFI` and re-runs `generate-zbm` on
every kernel install. Rollback ladder: pre-apt `apt_*` ZFS snapshots, the `_rescue` boot environment,
and the "ZFSBootMenu Backup" EFI entries. Never touch kernel packaging without preserving all of it.

**Kernel cmdline lives in ZFS, not GRUB** — `zfs set org.zfsbootmenu:commandline=… <pool>/ROOT`
followed by `generate-zbm`.

**Accelerators are container-only.** `gpu` (`/dev/dri` render node) and `npu` (`/dev/accel/accel0`)
are *add-on* profiles carrying just the device, stacked onto `default`/`lan`
(`incus launch … -p default -p gpu`). VM passthrough would need VFIO and would take the box's only
iGPU/NPU away from the host.

## Images: definitions vs machinery

Deliberately split, and the docs cross-reference both directions:

- **Generic lifecycle machinery** lives in step 1: `image.sh build|deploy|update|destroy|status`
  (wraps `distrobuilder build-incus`, `incus image import`, `incus init`, `incus rebuild`).
  Only `build` uses `sudo`; the resulting container still runs **unprivileged**.
- **Image definitions** live beside their service in `2 - Containers/`, **one YAML per image**; the
  image alias is the YAML basename. `example.yaml` is the minimal reference, `caddy.yaml` the real one.

### Not every service gets an image — this is deliberate

**Stateless-ish services get a distrobuilder image and are updated by `incus rebuild`; stateful
services stay ordinary containers and are upgraded in place.** Caddy is the first, Nextcloud the
second. Nextcloud *was* converted to an image (`nextcloud.yaml` + `nextcloud-provision.sh`) and was
deliberately converted back — **do not re-propose it.** The reasons, all still true:

- A rootfs swap would destroy the PostgreSQL cluster, `config.php` (which holds the DB password) and
  web-installed apps unless every one is redirected onto a volume, which is a lot of machinery.
- It makes the repo, not Debian, responsible for tracking Nextcloud releases, PHP compatibility, and
  PostgreSQL major bumps (a manual `pg_upgrade` of the cluster on the volume).
- No one in the LXD/Incus world runs Nextcloud that way; distrobuilder is used for base OS images.
- A VM was also considered and rejected: it takes the box's only iGPU away from the host and every
  container (accelerator profiles are container-only), needs `incus-agent` for the `incus exec`-heavy
  scripts, and routes the data volume over virtiofs.

When adding a service, ask *what happens if its root filesystem disappears.* "Nothing much" → YAML.
Anything involving a database → a script shaped like `nextcloud-install.sh`, with an `upgrade`
subcommand.

### For image-backed services: the three places state can live

`incus rebuild` (what `image.sh update` runs) **destroys the entire rootfs**. Exactly three things
survive, and `caddy.yaml` is built around them:

1. **Instance `user.*` keys** → per-instance *settings*. Images read them back at runtime through
   Incus templates baked in with distrobuilder's `template` generator
   (`config_get("user.x", "…")`, `when: [create, start]`). This is what makes an update
   self-healing: the fresh rootfs re-renders its own config with no script re-running. Keep
   `pongo: false` on those entries — `pongo: true` renders at *build* time instead.
2. **Attached custom volumes** → *secrets* and all mutable state, mounted at `/var/lib/homelab`.
   Secrets go here at mode `600`, never in `user.*` keys, which are visible in `incus config show`
   and travel inside `incus export` and instance copies.
3. **Instance devices** → the volume itself, and Caddy's macvlan `eth1`.

So: **image = disposable base (OS, packages, static config); everything else is volume or `user.*`.**
Never bake secrets or per-instance setup into a shared image. The non-obvious trap is Caddy's ACME
store — redirected via `XDG_DATA_HOME`, because losing it re-issues every cert against Let's
Encrypt's 5-per-week duplicate limit. Its `conf.d/` is on the volume for the same reason, which is
why `nextcloud-install.sh` registers at `/var/lib/homelab/conf.d/`, not `/etc/caddy/conf.d/`.

Two further constraints:

- **`incus rebuild` refuses when the instance has snapshots.** For image-backed services snapshot the
  *volume*, never the instance; `image.sh update` pre-checks and says so. The reverse holds for
  in-place services — `incus snapshot nextcloud` is the correct rollback there, since its rootfs is
  never replaced.
- **Pin anything fetched in a `post-packages` action.** A `latest` URL makes the image a moving
  target, which defeats the point of building one.

## Prose style

The Markdown is explanatory, not reference-dump: it states *why* a choice was made, names the
trade-off, and flags the caveat. Tables for config knobs and phase-by-phase walkthroughs, fenced `sh`
blocks for anything the user types, bold for hazards. Match it — em dashes, second person, no
marketing tone. Commit subjects are imperative and terse ("Add step 2: Caddy ingress + Nextcloud
service container").
