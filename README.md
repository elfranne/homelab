# homelab

Step-by-step build and configuration of my Debian-based NAS/homelab box. Each step lives in its own numbered directory with a self-contained `INSTALL.md`
walkthrough; work through them in order.

**Work in progress** — later steps are still being written.

## Why?

- **Encryption first** — home storage (NAS, homelab) too often handles data encryption poorly, or not at all; this build encrypts the ZFS root pool end to end.
- **Learning** — hands-on with private-cloud technology and privacy.
- **Hardware & AI** — running local AI models for coding.

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
| 0 | [OS Install](<0 - OS Install/INSTALL.md>) | Debian Trixie on an encrypted three-disk raidz1 ZFS root, booted via [ZFSBootMenu](https://zfsbootmenu.org/) with remote SSH unlock (dropbear) for headless reboots. | Done |
| 1 | [Hypervisor Install](<1 - Hypervisor Install/INSTALL.md>) | Virtualization layer on top of the base OS: [Incus](https://linuxcontainers.org/incus/) (containers + VMs) on a dedicated dataset of the encrypted ZFS pool, with a NAT bridge and a macvlan LAN profile. | Done |
