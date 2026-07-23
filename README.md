# homelab

Step-by-step build and configuration of my Debian-based NAS/homelab box. Each
step lives in its own numbered directory with a self-contained `INSTALL.md`
walkthrough; work through them in order.

**Work in progress** — later steps are still being written.

## Steps

| # | Step | Description | Status |
|---|---|---|---|
| 0 | [OS Install](<0 - OS Install/INSTALL.md>) | Debian Trixie on an encrypted three-disk raidz1 ZFS root, booted via [ZFSBootMenu](https://zfsbootmenu.org/) with remote SSH unlock (dropbear) for headless reboots. | Done |
| 1 | [Hypervisor Install](<1 - Hypervisor Install/INSTALL.md>) | Virtualization layer on top of the base OS. | Planned |
