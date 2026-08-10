# Step 2 — Containers: a Caddy ingress + Nextcloud

Step 1 gave us [Incus](https://linuxcontainers.org/incus/) and the generic image machinery.
This step starts running actual **services** on it, in a way that scales to many services
later. It has two parts:

1. **`caddy.yaml` + `caddy-provision.sh`** — a [Caddy](https://caddyserver.com/) container
   that is the homelab's one HTTPS entrypoint. It obtains **real Let's Encrypt certificates
   over the DNS-01 challenge** (via Cloudflare) — so no inbound port is ever opened — and
   forwards to private backend containers. **Deploy this once.**
2. **`nextcloud-install.sh`** — [Nextcloud](https://nextcloud.com/) as a native Debian
   container (nginx + PHP-FPM + PostgreSQL + Redis), private on the NAT bridge, with user
   data on its own encrypted ZFS volume. It registers itself with Caddy. **This is the first
   service; future services follow whichever of the two recipes below fits.**

Both are interactive, fail-fast, idempotent, and only talk to Incus — **they change nothing
on the host.** Run them as a user in the `incus-admin` group (or root), from the box or
anywhere `incus` reaches it.

## Two deployment models, and how to choose

These two services are built in deliberately different ways, and the difference is the most
important thing on this page.

| | **Image model** (Caddy) | **In-place model** (Nextcloud) |
|---|---|---|
| Defined by | `caddy.yaml`, a distrobuilder image definition | `nextcloud-install.sh`, run against a stock image |
| Deployed by | `image.sh build` → `caddy-provision.sh` | `nextcloud-install.sh` |
| Updated by | `image.sh update caddy caddy` — the rootfs is **replaced** | `./nextcloud-install.sh upgrade` — `apt` + the official Nextcloud updater |
| State lives | on a custom volume; nothing in the rootfs matters | in the container, plus user files on a volume |
| Rollback | snapshot the **volume** (instance snapshots block `rebuild`) | `incus snapshot nextcloud` — the whole container |

**The rule: services that carry little or no state get an image; stateful services stay
ordinary containers and are upgraded in place.**

Caddy fits the image model almost perfectly — it is a single binary plus a config file, and
the only things it accumulates are certificates and per-service site files, both of which
live happily on a volume. Rebuilding it is genuinely a rootfs swap.

Nextcloud does not. It is a PHP application with a PostgreSQL cluster, a `config.php` holding
the database password, and apps installed from the web UI — all of which a rootfs swap would
destroy unless every one of them is redirected onto a volume first. That is possible, and an
earlier revision of this repo did it, but the machinery is substantial and it makes **you**,
not Debian, responsible for tracking Nextcloud releases, PHP compatibility and PostgreSQL
major upgrades (a major bump would mean a manual `pg_upgrade` of the cluster on the volume).
Upgrading in place is also what essentially every other Nextcloud-on-LXD/Incus deployment
does, so it is the better-trodden path.

If you add a service later, ask what happens if its root filesystem disappears. If the answer
is "nothing much", write a YAML. If the answer involves a database, write a script.

## Why this shape otherwise

- **System containers, not VMs.** Nextcloud is just a PHP app + database — no kernel of its
  own needed. Containers are lighter, live on the encrypted `<pool>/incus` ZFS pool from step
  1, and — unlike a VM on this single-iGPU box — can still borrow the `gpu` profile later for
  photo/video transcoding. A VM would need VFIO passthrough of the only integrated GPU,
  taking it from the host and every container.
- **One shared TLS ingress.** Rather than each service juggling its own certificates, one
  Caddy container terminates TLS for all of them. Adding a service is one small file.
- **DNS-01, so nothing is exposed.** The ACME DNS-01 challenge proves you control the domain
  by writing a DNS record over the Cloudflare API — no port 80/443 open to the internet. You
  get a **publicly-trusted certificate for a LAN-only service.**
- **Backends stay private.** Only Caddy holds a LAN IP. Nextcloud sits on the NAT bridge,
  unreachable from the LAN except through the ingress.

## Topology

```
   LAN clients ─▶ cloud.<domain>  (DNS-only A record ─▶ caddy LAN IP)
                        │
   ┌──────────── caddy container ─────────────┐
   │  eth0: incusbr0 NAT  → default route:      │  reaches the internet (Cloudflare API
   │        internet + private backends         │  for DNS-01) and the backend containers
   │  eth1: macvlan on the uplink, STATIC LAN IP │  LAN clients connect here; no gateway
   │        (ingress only)                       │  on it, so no dual-default-route mess
   └───────────────────┬─────────────────────────┘
                       ▼  http://<nextcloud NAT IP>:80
     nextcloud container  (default profile, NAT only — never on the LAN)
     ├─ nginx + PHP-FPM + PostgreSQL + Redis + Nextcloud
     └─ user data on an Incus custom ZFS volume (own snapshots, inherits encryption)
```

**Why Caddy is dual-homed.** From step 1, macvlan guests reach the LAN and each other but
**not the host**, and NAT guests are private behind `incusbr0`. A macvlan-only ingress
therefore couldn't reach a NAT-only backend. Giving it a foot on **both** networks makes it
the single public entrypoint while every backend stays private — and the host's networking is
never touched. `eth0` (NAT, from the step-1 `default` profile) carries the default route;
`eth1` (macvlan on the same uplink the `lan` profile uses) is a **static LAN address clients
connect to** — it deliberately has no gateway, so there is no ambiguity about which interface
originates outbound traffic (always `eth0`).

## How the Caddy image survives an update

`image.sh update` runs `incus rebuild`, which **throws the entire root filesystem away**.
Exactly three things survive it, and `caddy.yaml` is built around them:

| Survives a rebuild | Used for |
|---|---|
| Instance `user.*` config keys | per-instance **settings** (LAN IP, ACME email) |
| Attached **custom volumes** | **secrets** and all mutable state |
| Instance **devices** | the state volume itself, and the macvlan `eth1` |

Everything stateful lives on the `caddy-state` volume, mounted at **`/var/lib/homelab`**:

| Path | Contents |
|---|---|
| `caddy.env` | the Cloudflare token, mode `600` |
| `conf.d/*.caddy` | one file per service — this is where `nextcloud-install.sh` registers |
| `caddy/` | the **ACME store** — certificates and account keys |

Settings are `user.*` keys, and the image carries **Incus templates** that re-render the
matching file at every container start:

| Key | Renders |
|---|---|
| `user.acme_email` | the global e-mail in `/etc/caddy/Caddyfile` |
| `user.lan_ip` | `Address=` in `/etc/systemd/network/10-eth1.network` |

So after `image.sh update`, the fresh rootfs regenerates its own Caddyfile and LAN address
with nothing re-running.

**Why the ACME store must be on the volume.** Let's Encrypt allows only **5 certificates per
week for the same set of names**. A rebuild that discarded Caddy's data directory would
re-issue every certificate you hold, and a few updates in one week would lock you out of your
own certificates until the limit refilled. `XDG_DATA_HOME` in the baked systemd unit redirects
it onto the volume.

**Secrets are not `user.*` keys.** They would be readable in `incus config show` and would ride
along inside `incus export` tarballs and instance copies. They go on the volume at mode `600`
instead, and the baked units point at those paths.

## Requirements

- Steps 0 and 1 complete: Incus running, with the `default` (NAT) and `lan` (macvlan) profiles
  and the `default` storage pool. The scripts check for these and refuse otherwise.
- A **domain on Cloudflare** and a **Cloudflare API token** (see below).
- A free **static LAN IP** for the ingress (e.g. `192.168.1.50/24`) that your router won't hand
  out via DHCP.
- Network access from the containers (the build fetches packages and the Caddy binary;
  Nextcloud fetches its release; Caddy needs the Cloudflare API at runtime).

## Cloudflare API token

Caddy needs a token to solve DNS-01. Create a **scoped API token** (not the Global API Key) at
*Cloudflare dashboard → My Profile → API Tokens → Create Token → Edit zone DNS*:

- **Permissions:** `Zone → DNS → Edit`
- **Zone Resources:** `Include → Specific zone → <your domain>`

That's the least privilege that works. The token is only ever used by Caddy for the ACME
challenge; nothing inbound is exposed. It is **never stored in the repo** — you paste it at
the prompt (hidden) or pass it as `$CF_API_TOKEN`, and it lands only in
`/var/lib/homelab/caddy.env` (mode `600`) on the ingress's state volume.

## 1. Build and deploy Caddy (run once)

Build the image on the box (the build needs root; the container still runs **unprivileged**):

```sh
"1 - Hypervisor Install/image.sh" build "2 - Containers/caddy.yaml"
```

Then copy the provisioning script over and run it:

```sh
scp "2 - Containers/caddy-provision.sh" <admin_user>@<nas-ip>:~/
ssh <admin_user>@<nas-ip>
chmod +x caddy-provision.sh
./caddy-provision.sh            # or: CF_API_TOKEN=... ./caddy-provision.sh
```

It prompts for the static LAN IP, a Let's Encrypt contact email, and the Cloudflare token,
then:

| Phase | What happens |
|---|---|
| 0 | Preflight: `incus` reachable, `default`/`lan` profiles and the `caddy` image present; reads the macvlan parent NIC from the `lan` profile. On a re-run, pre-fills the prompts from the instance's existing `user.*` keys. |
| 1 | Prompts (LAN IP, ACME email, Cloudflare token). |
| 2 | `incus init` from the image with `user.lan_ip` / `user.acme_email` set **before first start**, creates and attaches the `caddy-state` volume at `/var/lib/homelab`, adds the macvlan `eth1`, and starts (or restarts) the container. |
| 3 | Writes the token to `/var/lib/homelab/caddy.env` (mode `600`), restarts Caddy, `caddy validate`s, then **verifies the templates actually rendered** — the LAN IP is on `eth1` and the ACME email is in the Caddyfile. |

Config knobs (all prompted; editing the CONFIG block is optional):

| Variable | Meaning | Default |
|---|---|---|
| `CADDY_NAME` | Incus instance name | `caddy` |
| `CADDY_IMAGE` | Image alias — the basename of `caddy.yaml` | `caddy` |
| `CADDY_LAN_IP` | Static LAN IP for `eth1`, CIDR (your DNS target) | (prompted) |
| `LAN_PROFILE` | Step-1 macvlan profile whose parent NIC is reused | `lan` |
| `ACME_EMAIL` | Let's Encrypt contact email | (prompted) |
| `STATE_VOLUME` | Custom volume holding token, sites and ACME store | `caddy-state` |
| `STATE_PATH` | Where that volume is mounted in the container | `/var/lib/homelab` |

After it finishes, Caddy answers on its LAN IP. Point each service's DNS record there as a
**DNS-only (grey-cloud) A record** — `nextcloud-install.sh` reminds you of the exact record.

## 2. Install Nextcloud

```sh
scp "2 - Containers/nextcloud-install.sh" <admin_user>@<nas-ip>:~/
ssh <admin_user>@<nas-ip>
chmod +x nextcloud-install.sh
./nextcloud-install.sh
```

It prompts for the hostname (e.g. `cloud.example.com`), the admin username + password, and the
phone region, then:

| Phase | What happens |
|---|---|
| 0 | Preflight: `incus` reachable, `default` storage pool present, `caddy` up with Caddy active; reads the ingress's NAT IP. |
| 1 | Prompts (hostname, admin user/password, phone region). The password prompt is skipped when Nextcloud is already installed. |
| 2 | Launches the `nextcloud` container (NAT only), creates the **`nextcloud-data` volume**, and attaches it at `/var/www/nextcloud/data`. |
| 3 | Installs nginx + PHP-FPM (+ the Nextcloud PHP modules) + PostgreSQL + Redis; tunes PHP (512 MB, OPcache, APCu on CLI); creates the PostgreSQL role + database with a generated password. |
| 4 | Downloads and checksum-verifies the current Nextcloud release, unpacks it, and installs the official nginx vhost (plain HTTP :80 — TLS is the ingress's job). |
| 5 | Runs `occ maintenance:install`, then sets the trusted domain, reverse-proxy awareness (`overwriteprotocol=https`, `trusted_proxies`), Redis/APCu caching, the maintenance window, the phone region, a systemd-timer **cron** every 5 minutes, and the **database index/column maintenance**. |
| 6 | Writes `/var/lib/homelab/conf.d/<hostname>.caddy` into the **Caddy container's volume** and reloads Caddy. |

Config knobs (all prompted where it matters):

| Variable | Meaning | Default |
|---|---|---|
| `NC_NAME` | Incus container name | `nextcloud` |
| `NC_IMAGE` | Base image launched | `images:debian/13` |
| `NC_DOMAIN` | Public hostname | (prompted) |
| `NC_ADMIN_USER` | Nextcloud admin account | `admin` |
| `NC_DATA_VOLUME` | Incus custom volume for user data | `nextcloud-data` |
| `NC_PHONE_REGION` | `default_phone_region` (ISO 3166-1 alpha-2) | `DK` |
| `DB_NAME` / `DB_USER` | PostgreSQL database / role (password generated) | `nextcloud` |

## 3. DNS and first login

1. Create the DNS record the script prints — `cloud.<domain> → <caddy LAN IP>`, as a
   **DNS-only / grey-cloud** A record. Because certificates come via DNS-01, the name can point
   at a private LAN IP and still get a publicly-trusted certificate; it simply isn't reachable
   from outside your LAN (which is the point).
2. Browse to `https://cloud.<domain>` from a **LAN client**. The very first request may take a
   few seconds while Caddy obtains the certificate over DNS-01.
3. Log in with the admin account you set, then check **Settings → Administration → Overview** —
   the proxy headers, Redis locking, cron, maintenance window and database indices are all
   configured, so it should be a clean bill of health.

Quick check from a LAN machine:

```sh
curl -I https://cloud.<domain>     # 200/302 with a valid Let's Encrypt cert — no -k needed
```

## Updating

**Caddy — swap the rootfs.** Edit `caddy.yaml`, bump both `serial` and the marker in the
`post-packages` action, then:

```sh
"1 - Hypervisor Install/image.sh" build  "2 - Containers/caddy.yaml"
"1 - Hypervisor Install/image.sh" update caddy caddy
```

Nothing needs re-running afterwards: the templates re-render on start, and the volume carries
the token, the site files and the ACME store.

**Nextcloud — in place.**

```sh
./nextcloud-install.sh upgrade
```

That offers to take an Incus snapshot first, runs `apt-get upgrade` inside the container, then
Nextcloud's **official `updater.phar`** (which swaps the code, takes its own backup, and runs
`occ upgrade`), then the post-upgrade database maintenance, then restarts PHP-FPM and nginx.

The updater is used rather than the documented "move the old directory aside and unpack the
new one" procedure because the data volume is mounted *inside* `/var/www/nextcloud` — you
cannot move a directory that contains a mount point.

Re-running `./nextcloud-install.sh` with no arguments is separate: it re-applies configuration
and the ingress registration, and never touches the Nextcloud version.

## Backups and rollback

The two models want different things here, and using the wrong one is a real trap.

**Nextcloud — snapshot the instance.** Its rootfs is never replaced, so a whole-container
snapshot is a valid, one-command rollback covering the code *and* the database together:

```sh
incus snapshot create nextcloud before-something
incus snapshot restore nextcloud before-something
```

User files live on the `nextcloud-data` volume and are snapshotted separately:

```sh
incus storage volume snapshot default nextcloud-data
```

**Caddy — snapshot the volume, never the instance.** `incus rebuild` **refuses to run on an
instance that has snapshots**, so a snapshot taken "just in case" before an update is exactly
what would block that update. `image.sh update` checks first and tells you. The rootfs is
disposable by design; everything worth keeping is on the volume:

```sh
incus storage volume snapshot default caddy-state
```

Both volumes are on the encrypted step-1 ZFS pool, so they also ride your normal pool
snapshots, and step 0's pre-apt ZFS snapshots still cover the host.

## Adding more services later

Pick a model using the rule at the top of this page.

**Stateless-ish → image.** Write `<service>.yaml`: OS + packages + static config, anything
per-instance as a `template` generator reading `config_get("user.<key>", "…")`, anything
mutable redirected to `/var/lib/homelab`. Then:

```sh
"1 - Hypervisor Install/image.sh" build  "2 - Containers/<service>.yaml"
"1 - Hypervisor Install/image.sh" deploy <service> <instance> \
    --volume default/<service>-state:/var/lib/homelab --config user.<key>=<value>
```

**Stateful → script.** Copy the shape of `nextcloud-install.sh`: launch a stock container on
the NAT `default` profile, install and configure it, put the data on its own volume, and give
it an `upgrade` subcommand.

Either way, register it with the ingress by dropping one site file into the Caddy container at
`/var/lib/homelab/conf.d/<host>.caddy`:

```
app.<domain> {
    tls { dns cloudflare {env.CF_API_TOKEN} }
    reverse_proxy <container NAT IP>:<port>
}
```

then `incus exec caddy -- systemctl reload caddy`, and add the
`app.<domain> → <caddy LAN IP>` DNS-only record. Each site gets **its own certificate**
automatically (per-service, not a wildcard).

## Image definitions in this folder

- [`caddy.yaml`](caddy.yaml) — the Caddy ingress.
- [`example.yaml`](example.yaml) — a minimal worked example (Debian 13 + nginx, a baked landing
  page and a rootfs version marker). The smallest illustration of the create → deploy → update
  → destroy lifecycle.

The **generic build/deploy/update/destroy machinery is not in this folder** — it belongs to the
hypervisor layer. See
[**Building images with distrobuilder**](<../1 - Hypervisor Install/INSTALL.md#building-images-with-distrobuilder>)
in step 1 for the full procedure, the build-root-vs-unprivileged-runtime explanation, and the
image-vs-volume split.

## Notes and caveats

- **Ingress target is an IP.** The Caddy site file points at the Nextcloud container's current
  NAT IP (stable across restarts under Incus DHCP). If you ever delete and recreate the
  container and its IP changes, re-run `nextcloud-install.sh` to refresh the site file.
- **Host ↔ Nextcloud.** The host can reach NAT guests, so `incus exec nextcloud -- …` and `occ`
  work normally. The host cannot reach Caddy's *macvlan* LAN IP (step-1 caveat) — administer it
  via `incus exec caddy -- …` instead.
- **PostgreSQL majors.** Debian does not upgrade PostgreSQL across majors automatically; when
  Trixie's successor moves on, that is a deliberate `pg_upgrade`, not an `apt` away.
- **Remote access** (outside the LAN) is intentionally out of scope here — add a Cloudflare
  Tunnel or a WireGuard VPN as a later step rather than opening ports.
- **Optional GPU transcoding.** For Nextcloud Memories previews/transcoding, stack the step-1
  `gpu` profile onto the container (`incus profile add nextcloud gpu`) and install the guest
  VAAPI drivers — see step 1's *GPU and NPU access*. This is one of the reasons Nextcloud is a
  container and not a VM.

## Re-running

Both scripts are safe to re-run, and re-running is the intended way to change an answer.
Containers, volumes, devices and the per-service site file are only created when missing;
`user.*` keys and the Nextcloud configuration are simply re-applied, and the Nextcloud install
step is skipped once `occ status` reports it installed. If a run aborts, read the `[FAIL]` line
(it names the exact command and line), fix the cause, and run again.
