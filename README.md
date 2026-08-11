# homelab

This repository is a step-by-step build and configuration guide for a Debian NAS and homelab box.
Each step has its own numbered directory with a self-contained `INSTALL.md` walkthrough. Do the
steps in order.

**Work in progress.** The later steps are not complete yet.

## Why?

- **Encryption first.** Many home NAS and homelab systems encrypt data poorly, or not at all. This
  build encrypts the ZFS root pool from end to end.
- **Learning.** This project gives hands-on experience with private cloud technology and privacy.
- **Hardware and AI.** This project runs local AI models for coding.

## Hardware

Built on a [Minisforum N5 Pro](https://www.minisforum.com/products/n5-pro) AI NAS:

- **CPU:** AMD Ryzen AI 9 HX PRO 370 (12 cores / 24 threads, Zen 5)
- **GPU:** integrated Radeon 890M (RDNA 3.5), AV1/H.265 hardware transcode
- **NPU:** AMD XDNA 2, ~50 TOPS
- **Memory:** 2× DDR5 SO-DIMM, up to 96 GB ECC
- **Storage:** 5× SATA bays + 3× M.2 NVMe (or 1× M.2 + 2× U.2); PCIe x16 slot
- **Network:** 10 GbE + 5 GbE

## Steps

| # | Step | Description | Status |
|---|---|---|---|
| 0 | [OS Install](<0 - OS Install/INSTALL.md>) | This step installs Debian Trixie on an encrypted, three-disk raidz1 ZFS root. It boots through [ZFSBootMenu](https://zfsbootmenu.org/), with remote SSH unlock (dropbear) for headless reboots. | Done |
| 1 | [Hypervisor Install](<1 - Hypervisor Install/INSTALL.md>) | This step adds a virtualization layer on the base OS. It installs [Incus](https://linuxcontainers.org/incus/) (containers and VMs) on a dedicated dataset of the encrypted ZFS pool. Incus gets a NAT bridge and a macvlan LAN profile. | Done |
| 2 | [Containers](<2 - Containers/INSTALL.md>) | This step adds two services on Incus. [Caddy](https://caddyserver.com/) is a shared reverse-proxy ingress with real Let's Encrypt certificates, through Cloudflare DNS-01 with no open ports. Caddy is a reproducible [distrobuilder](https://github.com/lxc/distrobuilder) image, and an update swaps its rootfs. [Nextcloud](https://nextcloud.com/) is the first service, with nginx, PHP-FPM, PostgreSQL, and Redis. Nextcloud is a stateful container, upgraded in place, with data on its own encrypted ZFS volume. | Done |

## Development container

`.devcontainer/` describes the environment for writing this repository: linters, the Incus client,
and [Claude Code](https://claude.com/claude-code), all running inside the container instead of on
the workstation. Nothing in the devcontainer runs on the NAS. The installer scripts still declare no
dependencies and still target the real box.

The devcontainer image is `mcr.microsoft.com/devcontainers/base:trixie`. This is the same Debian
release that the NAS runs. As a result, `incus-client` and the linters come from the Debian package
repository, not from a backport.

| Tool | Source | Used for |
|---|---|---|
| `shellcheck`, `shfmt` | apt | linting and formatting the installers |
| `yamllint`, `python3-yaml` | apt | checking the distrobuilder definitions in `2 - Containers/` |
| `incus-client` | apt | driving the box from your desk, once you configure a remote |
| `node`, `python`, `gh` | devcontainer features | tooling that assumes one of them |
| `claude` | `ghcr.io/anthropics/devcontainer-features/claude-code` | the agent, sandboxed from your home directory |
| `uv` | `post-create.sh` | ephemeral Python tools — `uv run --with <pkg>`, no venv to maintain |

### Running it

This machine uses rootless Podman, not Docker. Point the Dev Containers extension at Podman before
you start.

Add this line to the VS Code user settings:

```json
"dev.containers.dockerPath": "podman"
```

Then run **Dev Containers: Reopen in Container**. The first build pulls the base image and four
features. This takes a few minutes. Later starts are quick.

After the container starts, run `claude` and complete the browser login. Copy the URL that `claude`
prints into your host browser. Credentials stay on the `homelab-claude` named volume, so a
**Rebuild Container** does not need another login.

### Podman specifics

`devcontainer.json` sets `--userns=keep-id` with `updateRemoteUserUID: false`. **Do not remove
either setting.** Without them, rootless Podman maps the container user to a subuid from
`/etc/subuid`. Then every file that you write under `/workspaces` gets a UID owner that does not
exist on the host. The two settings work as a pair: `keep-id` does the UID mapping, and the
extension's own `chown` step must not interfere.

Named volumes arrive root-owned under Podman. Unlike Docker Desktop, the extension does not correct
this, so `post-create.sh` takes ownership of `~/.claude` and `/commandhistory` before any other step
runs. Without that step, Claude Code cannot write its credentials, and the login failure gives no
clear error.

### What it does not do

This devcontainer has no egress firewall. Anthropic's reference devcontainer adds `NET_ADMIN` and
`NET_RAW`, then runs an iptables allowlist. If the container does not run in privileged mode, this
method is unreliable. This container isolates the agent from your home directory, not from the
network. **If you run untrusted plugins or hooks in this container, add the firewall first.**
