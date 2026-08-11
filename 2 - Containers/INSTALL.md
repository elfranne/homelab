# Step 2: Containers (Caddy Ingress and Nextcloud)

Step 1 gave us [Incus](https://linuxcontainers.org/incus/) and the generic image machinery.
This step runs real **services** on Incus, in a way that scales to many services later. It has
two parts:

1. **`caddy.yaml` and `caddy-provision.sh`.** This is a [Caddy](https://caddyserver.com/)
   container, the homelab's one HTTPS entry point. It gets real Let's Encrypt certificates
   through the DNS-01 challenge, using Cloudflare. As a result, no inbound port ever opens.
   Caddy forwards each request to a private backend container. **Deploy this once.**
2. **`nextcloud-install.sh`.** This installs [Nextcloud](https://nextcloud.com/) as a native
   Debian container, with nginx, PHP-FPM, PostgreSQL, and Redis. The container stays private on
   the NAT bridge. User data lives on its own encrypted ZFS volume. Nextcloud registers itself
   with Caddy. **This is the first service. A future service follows whichever of the two
   recipes below fits it.**

Both scripts are interactive, fail-fast, and idempotent. Both talk only to Incus. **Neither
script changes anything on the host.** Run them as a user in the `incus-admin` group, or as
root. Run them from the box itself, or from anywhere that `incus` reaches it.

## Two deployment models, and how to choose

This repository builds these two services in different ways, on purpose. This difference is
the most important idea on this page.

| | **Image model** (Caddy) | **In-place model** (Nextcloud) |
| --- | --- | --- |
| Defined by | `caddy.yaml`, a distrobuilder image definition | `nextcloud-install.sh`, run against a stock image |
| Deployed by | `image.sh build`, then `caddy-provision.sh` | `nextcloud-install.sh` |
| Updated by | `image.sh update caddy caddy`: this **replaces** the root file system | `./nextcloud-install.sh upgrade`: `apt`, and the official Nextcloud updater |
| State lives | on a custom volume, and nothing in the rootfs matters | in the container, and user files on a volume |
| Rollback | snapshot the **volume** (instance snapshots block `rebuild`) | `incus snapshot nextcloud`: the whole container |

**The rule is this: a service that carries little or no state gets an image. A stateful service
stays an ordinary container, and you upgrade it in place.**

Caddy fits the image model almost perfectly. It is a single binary and a config file. The only
things that Caddy collects are certificates and per-service site files, and both live well on a
volume. A rebuild of Caddy is truly just a root file system swap.

Nextcloud does not fit the image model. Nextcloud is a PHP application with a PostgreSQL
cluster, a `config.php` file that holds the database password, and apps installed from the web
interface. A rootfs swap destroys all of these, unless every one of them moves onto a volume
first.

Moving everything onto a volume is possible. An earlier revision of this repository did exactly
that. But the extra machinery is substantial, and it makes you, not Debian, responsible for
tracking Nextcloud releases, PHP compatibility, and PostgreSQL major version upgrades. A
PostgreSQL major version upgrade needs a manual `pg_upgrade` of the cluster on the volume.

Upgrading Nextcloud in place is also what almost every other Nextcloud deployment on LXD or
Incus does. This makes it the more common path.

If you add a service later, ask this question: what happens if its root file system
disappears? If the answer is "nothing much," write a YAML file. If the answer involves a
database, write a script.

## Why this shape otherwise

- **System containers, not VMs.** Nextcloud is only a PHP application and a database. It needs
  no kernel of its own. Containers are lighter, and they live on the encrypted `<pool>/incus`
  ZFS pool from step 1. A container can also borrow the `gpu` profile later, for photo and video
  transcoding. A VM on this single-iGPU box cannot do this. A VM needs VFIO passthrough of the
  only integrated GPU, and this takes the GPU away from the host and every container.
- **One shared TLS ingress.** Instead of each service managing its own certificates, one Caddy
  container terminates TLS for all of them. Adding a new service needs only one small file.
- **DNS-01, so nothing is exposed.** The ACME DNS-01 challenge proves that you control the
  domain, by writing a DNS record through the Cloudflare API. No port 80 or 443 opens to the
  internet. You get a publicly trusted certificate for a LAN-only service.
- **Backends stay private.** Only Caddy holds a LAN IP address. Nextcloud sits on the NAT
  bridge. You cannot reach Nextcloud from the LAN, except through the ingress.

## Topology

```none
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

**Why Caddy has two network interfaces.** From step 1, a macvlan guest can reach the LAN and
other macvlan guests, but it cannot reach the host. A NAT guest stays private behind
`incusbr0`. For this reason, an ingress with only macvlan cannot reach a NAT-only backend.

Caddy has an interface on both networks instead. This makes Caddy the single public entry
point, while every backend stays private, and the host's own networking never changes. The
`eth0` interface uses NAT, from the step-1 `default` profile, and it carries the default route.
The `eth1` interface uses macvlan, on the same uplink that the `lan` profile uses, and it is a
static LAN address that clients connect to. `eth1` has no gateway on purpose, so there is no
question about which interface starts outbound traffic. Outbound traffic always starts on
`eth0`.

## How the Caddy image survives an update

`image.sh update` runs `incus rebuild`, which destroys the entire root file system. Exactly
three things survive a rebuild, and `caddy.yaml` is built around them:

| Survives a rebuild | Used for |
| --- | --- |
| Instance `user.*` config keys | per-instance **settings** (LAN IP, ACME email) |
| Attached **custom volumes** | **secrets** and all mutable state |
| Instance **devices** | the state volume itself, and the macvlan `eth1` |

Everything stateful lives on the `caddy-state` volume, mounted at **`/var/lib/homelab`**:

| Path | Contents |
| --- | --- |
| `caddy.env` | the Cloudflare token, mode `600` |
| `conf.d/*.caddy` | one file per service. `nextcloud-install.sh` registers here |
| `caddy/` | the **ACME store**: certificates and account keys |

Settings are `user.*` keys, and the image carries **Incus templates** that re-render the
matching file at every container start:

| Key | Renders |
| --- | --- |
| `user.acme_email` | the global email in `/etc/caddy/Caddyfile` |
| `user.lan_ip` | `Address=` in `/etc/systemd/network/10-eth1.network` |

As a result, after `image.sh update`, the fresh root file system regenerates its own Caddyfile
and LAN address. No script needs to run again.

**Keep the ACME store on the volume.** Let's Encrypt allows only 5 certificates per week for the
same set of names. If a rebuild discards Caddy's data directory, it re-issues every certificate
you hold. Repeated updates within one week can then lock you out of your own certificates,
until the limit resets. `XDG_DATA_HOME` in the baked systemd unit redirects the ACME store onto
the volume, so a rebuild does not touch it.

**Never put a secret in a `user.*` key.** Anyone can read a `user.*` key with
`incus config show`, and the key also travels inside `incus export` tarballs and instance
copies. Instead, secrets go on the volume, at file mode `600`, and the baked systemd units point
at those paths.

## Requirements

- Steps 0 and 1 complete. Incus must be running, with the `default` (NAT) and `lan` (macvlan)
  profiles, and the `default` storage pool. The scripts check for these and refuse to run
  otherwise.
- A domain on Cloudflare, and a Cloudflare API token (see below).
- A free static LAN IP for the ingress, for example `192.168.1.50/24`, that your router does
  not hand out over DHCP.
- Network access from the containers. The build fetches packages and the Caddy binary.
  Nextcloud fetches its own release. Caddy needs the Cloudflare API at runtime.

## Cloudflare API token

Caddy needs a token to solve the DNS-01 challenge. Create a scoped API token, not the Global
API Key. In the Cloudflare dashboard, go to My Profile, then API Tokens, then Create Token,
then Edit zone DNS:

- **Permissions:** `Zone`, then `DNS`, then `Edit`
- **Zone Resources:** `Include`, then `Specific zone`, then `<your domain>`

That is the least amount of privilege that works. Caddy uses the token only for the ACME
challenge. No inbound access is exposed. **The token is never stored in the repository.** You
paste it at the prompt, where the input is hidden, or you pass it as `$CF_API_TOKEN`. The
token lands only in `/var/lib/homelab/caddy.env`, at file mode `600`, on the ingress's state
volume.

## 1. Build and deploy Caddy (run once)

Build the image on the box. The build needs root access, but the container still runs
**unprivileged**:

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
| --- | --- |
| 0 | Preflight check: `incus` is reachable, the `default` and `lan` profiles and the `caddy` image exist. The script reads the macvlan parent network card from the `lan` profile. On a repeat run, the script pre-fills the prompts from the instance's existing `user.*` keys. |
| 1 | Prompts for the LAN IP, the ACME email, and the Cloudflare token. |
| 2 | Runs `incus init` from the image, with `user.lan_ip` and `user.acme_email` set before the first start. Creates and attaches the `caddy-state` volume at `/var/lib/homelab`. Adds the macvlan `eth1`. Starts, or restarts, the container. |
| 3 | Writes the token to `/var/lib/homelab/caddy.env`, at mode `600`. Restarts Caddy. Runs `caddy validate`. Then checks that the templates actually rendered: the LAN IP is on `eth1`, and the ACME email is in the Caddyfile. |

Config knobs (all prompted for). Editing the CONFIG block is optional:

| Variable | Meaning | Default |
| --- | --- | --- |
| `CADDY_NAME` | Incus instance name | `caddy` |
| `CADDY_IMAGE` | Image alias: the basename of `caddy.yaml` | `caddy` |
| `CADDY_LAN_IP` | Static LAN IP for `eth1`, CIDR (your DNS target) | (prompted) |
| `LAN_PROFILE` | Step-1 macvlan profile whose parent NIC is reused | `lan` |
| `ACME_EMAIL` | Let's Encrypt contact email | (prompted) |
| `STATE_VOLUME` | Custom volume holding token, sites and ACME store | `caddy-state` |
| `STATE_PATH` | Where that volume is mounted in the container | `/var/lib/homelab` |

After the script finishes, Caddy answers on its LAN IP address. Point each service's DNS
record at this IP address, as a DNS-only (grey-cloud) A record. `nextcloud-install.sh` reminds
you of the exact record to create.

## 2. Install Nextcloud

```sh
scp "2 - Containers/nextcloud-install.sh" <admin_user>@<nas-ip>:~/
ssh <admin_user>@<nas-ip>
chmod +x nextcloud-install.sh
./nextcloud-install.sh
```

It prompts for the hostname, for example `cloud.example.com`, the admin username and password,
and the phone region. Then:

| Phase | What happens |
| --- | --- |
| 0 | Preflight check: `incus` is reachable, the `default` storage pool exists, and the `caddy` container is up with Caddy active. The script reads the ingress's NAT IP address. |
| 1 | Prompts for the hostname, the admin username and password, and the phone region. The script skips the password prompt when Nextcloud is already installed. |
| 2 | Launches the `nextcloud` container (NAT only), creates the **`nextcloud-data` volume**, and attaches it at `/var/www/nextcloud/data`. |
| 3 | Installs nginx, PHP-FPM with the Nextcloud PHP modules, PostgreSQL, and Redis. Tunes PHP: 512 MB memory limit, OPcache, and APCu on the CLI. Creates the PostgreSQL role and database, with a generated password. |
| 4 | Downloads the current Nextcloud release and checks its checksum. Unpacks the release. Installs the official nginx vhost, on plain HTTP port 80. TLS is the ingress's job, not this container's. |
| 5 | Runs `occ maintenance:install`. Then sets the trusted domain, reverse-proxy awareness (`overwriteprotocol=https` and `trusted_proxies`), Redis and APCu caching, the maintenance window, the phone region, a systemd-timer **cron** job every 5 minutes, and the **database index and column maintenance**. |
| 6 | Writes `/var/lib/homelab/conf.d/<hostname>.caddy` into the **Caddy container's volume** and reloads Caddy. |

Config knobs, prompted where relevant:

| Variable | Meaning | Default |
| --- | --- | --- |
| `NC_NAME` | Incus container name | `nextcloud` |
| `NC_IMAGE` | Base image launched | `images:debian/13` |
| `NC_DOMAIN` | Public hostname | (prompted) |
| `NC_ADMIN_USER` | Nextcloud admin account | `admin` |
| `NC_DATA_VOLUME` | Incus custom volume for user data | `nextcloud-data` |
| `NC_PHONE_REGION` | `default_phone_region` (ISO 3166-1 alpha-2) | `DK` |
| `DB_NAME`, `DB_USER` | PostgreSQL database and role (password generated) | `nextcloud` |

## 3. DNS and first login

1. Create the DNS record that the script prints: `cloud.<domain>` pointing at
   `<caddy LAN IP>`, as a DNS-only (grey-cloud) A record. Because certificates come from
   DNS-01, the name can point at a private LAN IP and still get a publicly trusted
   certificate. The name is not reachable from outside your LAN. This is the point of the
   design.
2. Open `https://cloud.<domain>` from a **LAN client**. The first request can take a few
   seconds, while Caddy gets the certificate through DNS-01.
3. Log in with the admin account that you set. Then go to Settings, then Administration, then
   Overview. Check that the overview shows a clean bill of health: proxy headers, Redis
   locking, cron, the maintenance window, and database indices are all configured.

Quick check from a LAN machine:

```sh
curl -I https://cloud.<domain>     # 200/302 with a valid Let's Encrypt cert — no -k needed
```

## Updating

**Caddy: swap the root file system.** Edit `caddy.yaml`. Bump both `serial` and the marker in
the `post-packages` action. Then run:

```sh
"1 - Hypervisor Install/image.sh" build  "2 - Containers/caddy.yaml"
"1 - Hypervisor Install/image.sh" update caddy caddy
```

Nothing needs to run again afterward. The templates re-render at container start, and the
volume carries the token, the site files, and the ACME store.

**Nextcloud: upgrade in place.**

```sh
./nextcloud-install.sh upgrade
```

This command offers to take an Incus snapshot first. It runs `apt-get upgrade` inside the
container. Then it runs Nextcloud's official `updater.phar`, which swaps the code, takes its
own backup, and runs `occ upgrade`. Then it runs the post-upgrade database maintenance.
Finally, it restarts PHP-FPM and nginx.

The script uses the updater, instead of Nextcloud's documented "move the old directory aside
and unpack the new one" procedure. The reason is that the data volume is mounted inside
`/var/www/nextcloud`. You cannot move a directory that contains a mount point.

Running `./nextcloud-install.sh` again, with no arguments, does something different. It
re-applies the configuration and the ingress registration. It never touches the Nextcloud
version.

## Backups and rollback

The two models need different backup methods here. Using the wrong method is a real risk.

**Nextcloud: snapshot the instance.** Its root file system is never replaced, so a snapshot of
the whole container is a valid, one-command rollback. This snapshot covers both the code and
the database together:

```sh
incus snapshot create nextcloud before-something
incus snapshot restore nextcloud before-something
```

User files live on the `nextcloud-data` volume and are snapshotted separately:

```sh
incus storage volume snapshot default nextcloud-data
```

**Caddy: snapshot the volume, never the instance.** `incus rebuild` refuses to run on an
instance that has snapshots. If you take a snapshot "just in case" before an update, that
snapshot blocks the update. `image.sh update` checks for this first, and tells you if it finds
a snapshot. The root file system is disposable by design. Everything worth keeping is on the
volume:

```sh
incus storage volume snapshot default caddy-state
```

Both volumes are on the encrypted step-1 ZFS pool. As a result, your normal pool snapshots also
cover them. Step 0's pre-apt ZFS snapshots still cover the host.

## Adding more services later

Pick a model using the rule at the top of this page.

**A service with little or no state: use an image.** Write `<service>.yaml`. Include the OS,
packages, and static config. Put anything per-instance into a `template` generator that reads
`config_get("user.<key>", "…")`. Redirect anything mutable to `/var/lib/homelab`. Then:

```sh
"1 - Hypervisor Install/image.sh" build  "2 - Containers/<service>.yaml"
"1 - Hypervisor Install/image.sh" deploy <service> <instance> \
    --volume default/<service>-state:/var/lib/homelab --config user.<key>=<value>
```

**A stateful service: use a script.** Copy the shape of `nextcloud-install.sh`. Launch a stock
container on the NAT `default` profile. Install and configure it. Put the data on its own
volume. Give the script an `upgrade` subcommand.

Either way, register the service with the ingress. Add one site file into the Caddy container,
at `/var/lib/homelab/conf.d/<host>.caddy`:

```cfg
app.<domain> {
    tls { dns cloudflare {env.CF_API_TOKEN} }
    reverse_proxy <container NAT IP>:<port>
}
```

Then run `incus exec caddy -- systemctl reload caddy`. Add the `app.<domain>` DNS-only record,
pointing at `<caddy LAN IP>`. Each site gets its own certificate automatically. This is
per-service, not a wildcard.

## Image definitions in this folder

- [`caddy.yaml`](caddy.yaml): the Caddy ingress.
- [`example.yaml`](example.yaml): a minimal worked example. It uses Debian 13 and nginx, with a
  baked landing page and a root file system version marker. This is the smallest illustration
  of the create, deploy, update, and destroy lifecycle.

The generic build, deploy, update, and destroy machinery is not in this folder. It belongs to
the hypervisor layer. See
[**Building images with distrobuilder**](<../1 - Hypervisor Install/INSTALL.md#building-images-with-distrobuilder>)
in step 1, for the full procedure, the difference between the build root and the unprivileged
runtime, and the split between image and volume.

## Notes and caveats

- **The ingress target is an IP address.** The Caddy site file points at the Nextcloud
  container's current NAT IP address, which stays stable across restarts under Incus DHCP. If
  you delete and recreate the container, and its IP address changes, run
  `nextcloud-install.sh` again to refresh the site file.
- **Host and Nextcloud.** The host can reach NAT guests, so `incus exec nextcloud -- …` and
  `occ` work normally. The host cannot reach Caddy's macvlan LAN IP address, as noted in step
  1. Administer Caddy through `incus exec caddy -- …` instead.
- **PostgreSQL major versions.** Debian does not upgrade PostgreSQL across major versions
  automatically. When the successor to Trixie arrives, a major version upgrade needs a
  deliberate `pg_upgrade`. It is not as simple as one `apt` command.
- **Remote access from outside the LAN is out of scope here, on purpose.** Add a Cloudflare
  Tunnel or a WireGuard VPN as a later step, instead of opening ports.
- **Optional GPU transcoding.** For Nextcloud Memories previews and transcoding, stack the
  step-1 `gpu` profile onto the container, with `incus profile add nextcloud gpu`. Install the
  guest VAAPI drivers too. See step 1's "GPU and NPU access" section. This is one of the
  reasons why Nextcloud runs as a container, not a VM.

## Re-running

Both scripts are safe to run again, and running them again is the intended way to change an
answer. A container, volume, device, or per-service site file is created only when it does not
exist yet. The scripts re-apply the `user.*` keys and the Nextcloud configuration every time.
The Nextcloud install step is skipped once `occ status` reports that Nextcloud is installed. If
a run stops with an error, read the `[FAIL]` line, which names the exact command and line
number. Fix the cause, then run the script again.
