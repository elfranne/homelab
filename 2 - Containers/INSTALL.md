# Step 2 — Containers: a reverse-proxy ingress + Nextcloud

Step 1 gave us [Incus](https://linuxcontainers.org/incus/). This step starts running
actual **services** on it, in a way that scales to many services later. It has two
parts:

1. **`reverse-proxy-install.sh`** — a single [Caddy](https://caddyserver.com/) container
   that is the homelab's one HTTPS entrypoint. It obtains **real Let's Encrypt
   certificates over the DNS-01 challenge** (via Cloudflare) — so no inbound port is
   ever opened — and forwards to private backend containers. **Run this once.**
2. **`nextcloud-install.sh`** — [Nextcloud](https://nextcloud.com/) as a native Debian
   container (nginx + PHP-FPM + PostgreSQL + Redis), private on the NAT bridge, with its
   user data on its own encrypted ZFS volume. It registers itself with the proxy. **This
   is the first service; future services follow the same recipe.**

Both are interactive, fail-fast, idempotent, and only talk to Incus — **they change
nothing on the host.** Run them as a user in the `incus-admin` group (or root), from the
box or anywhere `incus` reaches it.

## Why this shape

- **System containers, not VMs.** Nextcloud (and most self-hosted web apps) is just a
  PHP app + database — no kernel of its own needed. Containers are lighter, live on the
  encrypted `<pool>/incus` ZFS pool from step 1, and (unlike a VM on this single-iGPU
  box) can still borrow the `gpu` profile later for photo/video transcoding.
- **One shared TLS ingress.** Rather than each service juggling its own certificates,
  one Caddy container terminates TLS for all of them. Adding a service is one small file.
- **DNS-01, so nothing is exposed.** The ACME DNS-01 challenge proves you control the
  domain by writing a DNS record over the Cloudflare API — no port 80/443 open to the
  internet. You get a **publicly-trusted certificate for a LAN-only service.**
- **Backends stay private.** Only the proxy holds a LAN IP. Nextcloud sits on the NAT
  bridge, unreachable from the LAN except through the proxy.

## Topology

```
   LAN clients ─▶ cloud.<domain>  (DNS-only A record ─▶ proxy LAN IP)
                        │
   ┌──────── proxy (Caddy) container ─────────┐
   │  eth0: incusbr0 NAT  → default route:      │  reaches the internet (Cloudflare API
   │        internet + private backends         │  for DNS-01) and the backend containers
   │  eth1: macvlan on the uplink, STATIC LAN IP │  LAN clients connect here; no gateway
   │        (ingress only)                       │  on it, so no dual-default-route mess
   └───────────────────┬─────────────────────────┘
                       ▼  http://<nextcloud NAT IP>:80
     nextcloud container  (default profile, NAT only — never on the LAN)
     ├─ nginx + PHP-FPM + PostgreSQL + Redis + Nextcloud
     └─ data on an Incus custom ZFS volume (own snapshots, inherits encryption)
```

**Why the proxy is dual-homed.** From step 1, macvlan guests reach the LAN and each
other but **not the host**, and NAT guests are private behind `incusbr0`. A macvlan-only
proxy therefore couldn't reach a NAT-only backend. Giving the proxy a foot on **both**
networks makes it the single public entrypoint while every backend stays private — and
the host's networking is never touched. `eth0` (NAT, from the step-1 `default` profile)
carries the default route; `eth1` (macvlan on the same uplink the `lan` profile uses) is
a **static LAN address clients connect to** — it deliberately has no gateway, so there is
no ambiguity about which interface originates outbound traffic (always `eth0`).

## Requirements

- Steps 0 and 1 complete: Incus running, with the `default` (NAT) and `lan` (macvlan)
  profiles and the `default` storage pool. The scripts check for these and refuse
  otherwise.
- A **domain on Cloudflare** and a **Cloudflare API token** (see below).
- A free **static LAN IP** for the proxy (e.g. `192.168.1.50/24`) that your router won't
  hand out via DHCP.
- Network access from the containers (to fetch packages, the Caddy binary, and the
  Nextcloud release).

## Cloudflare API token

Caddy needs a token to solve DNS-01. Create a **scoped API token** (not the Global API
Key) at *Cloudflare dashboard → My Profile → API Tokens → Create Token → Edit zone DNS*:

- **Permissions:** `Zone → DNS → Edit`
- **Zone Resources:** `Include → Specific zone → <your domain>`

That's the least privilege that works. The token is only ever used by Caddy for the ACME
challenge; nothing inbound is exposed. It is **never stored in the scripts** — you paste
it at the prompt (hidden) or pass it as `$CF_API_TOKEN`, and it lands only in
`/etc/caddy/caddy.env` (mode `600`) inside the proxy container.

## 1. Install the reverse proxy (run once)

Copy the script to the box and run it:

```sh
scp "2 - Containers/reverse-proxy-install.sh" <admin_user>@<nas-ip>:~/
ssh <admin_user>@<nas-ip>
chmod +x reverse-proxy-install.sh
./reverse-proxy-install.sh            # or: CF_API_TOKEN=... ./reverse-proxy-install.sh
```

It prompts for the proxy's static LAN IP, a Let's Encrypt contact email, and the
Cloudflare token, then:

| Phase | What happens |
|---|---|
| 0 | Preflight: `incus` reachable, `default`/`lan` profiles present; reads the macvlan parent NIC from the `lan` profile. |
| 1 | Prompts (LAN IP, ACME email, Cloudflare token). |
| 2 | Launches the `proxy` container on NAT (`eth0`), adds a macvlan `eth1`, and gives `eth1` the **static LAN IP** via systemd-networkd (no gateway). |
| 3 | Installs **Caddy built with the Cloudflare DNS module** (fetched from Caddy's download API) + a systemd unit whose `EnvironmentFile` holds the token. |
| 4 | Writes a base `Caddyfile` (global ACME email + `import /etc/caddy/conf.d/*.caddy`) and starts Caddy. |

Config knobs (all prompted; editing the CONFIG block is optional):

| Variable | Meaning | Default |
|---|---|---|
| `PROXY_NAME` | Incus container name | `proxy` |
| `PROXY_LAN_IP` | Static LAN IP for `eth1`, CIDR (your DNS target) | (prompted) |
| `LAN_PROFILE` | Step-1 macvlan profile whose parent NIC is reused | `lan` |
| `ACME_EMAIL` | Let's Encrypt contact email | (prompted) |
| `CONF_DIR` | Where per-service site files are imported from | `/etc/caddy/conf.d` |

After it finishes, the proxy answers on its LAN IP. Point each service's DNS record there
as a **DNS-only (grey-cloud) A record** — `nextcloud-install.sh` reminds you of the exact
record to create.

## 2. Install Nextcloud

```sh
scp "2 - Containers/nextcloud-install.sh" <admin_user>@<nas-ip>:~/
ssh <admin_user>@<nas-ip>
chmod +x nextcloud-install.sh
./nextcloud-install.sh
```

It prompts for the hostname (e.g. `cloud.example.com`), the admin username + password,
and the phone region, then:

| Phase | What happens |
|---|---|
| 0 | Preflight: `incus` reachable, `default` storage pool present, `proxy` container up with Caddy active; reads the proxy's NAT IP. |
| 1 | Prompts (hostname, admin user/password, phone region). |
| 2 | Launches the `nextcloud` container (NAT only), creates the **`nextcloud-data` Incus custom volume**, and attaches it at `/var/www/nextcloud/data`. |
| 3 | Installs nginx + PHP-FPM (+ the Nextcloud PHP modules) + PostgreSQL + Redis; tunes PHP (512 MB, OPcache, APCu on CLI); creates the PostgreSQL role + database with a generated password. |
| 4 | Downloads and checksum-verifies the current Nextcloud release, unpacks it, and installs the official nginx vhost (plain HTTP :80 — TLS is the proxy's job). |
| 5 | Runs `occ maintenance:install`, then sets the trusted domain, reverse-proxy awareness (`overwriteprotocol=https`, `trusted_proxies`), Redis/APCu caching, the maintenance window and phone region, and a systemd-timer **cron** every 5 minutes. |
| 6 | Writes `/etc/caddy/conf.d/<hostname>.caddy` into the proxy (its own DNS-01 certificate) and reloads Caddy. |

Config knobs (all prompted where it matters):

| Variable | Meaning | Default |
|---|---|---|
| `NC_NAME` | Incus container name | `nextcloud` |
| `NC_DOMAIN` | Public hostname | (prompted) |
| `NC_ADMIN_USER` | Nextcloud admin account | `admin` |
| `NC_DATA_VOLUME` | Incus custom volume for user data | `nextcloud-data` |
| `NC_PHONE_REGION` | `default_phone_region` (ISO 3166-1 alpha-2) | `DK` |
| `DB_NAME` / `DB_USER` | PostgreSQL database / role (password generated) | `nextcloud` |

## 3. DNS and first login

1. Create the DNS record the script prints — `cloud.<domain> → <proxy LAN IP>`, as a
   **DNS-only / grey-cloud** A record. Because certificates come via DNS-01, the name can
   point at a private LAN IP and still get a publicly-trusted certificate; it simply isn't
   reachable from outside your LAN (which is the point).
2. Browse to `https://cloud.<domain>` from a **LAN client**. The very first request may
   take a few seconds while Caddy obtains the certificate over DNS-01.
3. Log in with the admin account you set, then check **Settings → Administration →
   Overview** — the proxy headers, Redis locking, cron, and maintenance window are all
   configured so it should be a clean bill of health.

Quick check from a LAN machine:

```sh
curl -I https://cloud.<domain>     # 200/302 with a valid Let's Encrypt cert — no -k needed
```

## Image definitions (one YAML per image)

The two scripts above provision *running* containers imperatively. As the homelab grows,
the better pattern is to bake each service's OS + packages + static config into a
**reproducible `distrobuilder` image** and keep only the stateful setup as a thin step.
This folder is where those **image definitions** live — **one YAML file per image** —
sitting beside the service they build.

- [`example.yaml`](example.yaml) — a worked example: a minimal Debian 13 + nginx image
  with a baked landing page and a rootfs version marker. It's the reference for the
  create → deploy → update → destroy lifecycle.
- Real services are added the same way over time (e.g. `nextcloud.yaml`, `proxy.yaml`),
  each its own file here.

The **generic build/deploy/update/destroy machinery is not in this folder** — it belongs
to the hypervisor layer. Build and manage any image here with `image.sh` from step 1:

```sh
"../1 - Hypervisor Install/image.sh" build   example.yaml
"../1 - Hypervisor Install/image.sh" deploy  example demo --volume default/demo-data:/srv/data
"../1 - Hypervisor Install/image.sh" update  example demo      # after editing the YAML
"../1 - Hypervisor Install/image.sh" destroy demo --image example --volume default/demo-data
```

See [**Building images with distrobuilder**](<../1 - Hypervisor Install/INSTALL.md#building-images-with-distrobuilder>)
in the hypervisor step for the full procedure, the build-root-vs-unprivileged-runtime
explanation, and the image-vs-volume split.

## Adding more services later (the recipe)

Every future service is the same pattern behind the same proxy:

1. Launch a container on the **NAT** `default` profile (private).
2. Install the service; have it listen on plain HTTP inside the container.
3. Drop one site file into the proxy at `/etc/caddy/conf.d/<host>.caddy`:
   ```
   app.<domain> {
       tls { dns cloudflare {env.CF_API_TOKEN} }
       reverse_proxy <container NAT IP>:<port>
   }
   ```
   then `incus exec proxy -- systemctl reload caddy`.
4. Add the `app.<domain> → <proxy LAN IP>` DNS-only record.

Each site gets **its own certificate** automatically (per-service, not a wildcard).

## Backups

Nextcloud's files live on the `nextcloud-data` Incus volume and its database inside the
container — both on the encrypted step-1 ZFS pool, so they ride your normal pool
snapshots. For an app-consistent point-in-time copy of the files:

```sh
incus storage volume snapshot default nextcloud-data
```

For upgrades, the pre-apt ZFS snapshotting from step 0 and per-container snapshots
(`incus snapshot <name>`) give you one-command rollback.

## Notes and caveats

- **Proxy target is an IP.** The Caddy site file points at the Nextcloud container's
  current NAT IP (stable across restarts under Incus DHCP). If you ever rebuild the
  container and its IP changes, just re-run `nextcloud-install.sh` — it refreshes the
  site file.
- **Host ↔ Nextcloud.** The host can reach NAT guests, so `incus exec nextcloud -- …`
  and `occ` work normally. The host cannot reach the proxy's *macvlan* LAN IP (step-1
  caveat) — administer the proxy via `incus exec proxy -- …` instead.
- **Remote access** (outside the LAN) is intentionally out of scope here — add a
  Cloudflare Tunnel or a WireGuard VPN as a later step rather than opening ports.
- **Optional GPU transcoding.** For Nextcloud Memories previews/transcoding, stack the
  step-1 `gpu` profile onto the container (`incus profile add nextcloud gpu`) and install
  the guest VAAPI drivers — see step 1's *GPU and NPU access*.

## Re-running

Both scripts are safe to re-run. Containers, the data volume, the Caddy binary, and the
per-service site file are only created/added when missing; the Nextcloud install step is
skipped once `occ status` reports it installed, while the reverse-proxy and caching
config are simply re-applied. If a run aborts, read the `[FAIL]` line (it names the exact
command and line), fix the cause, and run again.
