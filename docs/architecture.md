# Architecture

The stack at a glance. Four hosts, described declaratively by Ansible; container
workloads are podman quadlets behind a single caddy reverse proxy, except the NAS
(Docker Compose) and the exporters/tunnel (systemd). The cloud edge (Cloudflare,
Hetzner, GCP/Firebase) is OpenTofu, state in HCP. CI validates and deploys the
cloud + website; the Ansible fleet deploys itself via the `gitops_reconcile`
timer. Everything renders from source in this repo.

Diagrams are [Mermaid](https://mermaid.js.org) — they render inline on GitHub.

**Legend**

```mermaid
flowchart LR
  h["host / role / container / CI job / managed resource"]:::host
  x(["external / SaaS / actor"]):::ext
  d[("data store / volume")]:::store
  t[["scheduled timer / oneshot"]]:::timer
  h -->|"sync / request"| x
  h -.->|"async / scrape / tunnel"| d
  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
  classDef timer fill:#f3e9fb,stroke:#8a53c1,color:#2e0d4d;
```

---

## 1. Fleet & network topology

`scholam` is the control host: it drives the fleet over SSH (over WireGuard for
the public VPS) and runs the self-applying `gitops_reconcile` timer. The NAS is
the NFS server (media + backups) and the monitoring hub.

```mermaid
flowchart TB
  internet(["Internet"]):::ext

  subgraph home["Home LAN"]
    direction TB
    scholam["scholam<br/>control host · workstation<br/>Tumbleweed · incus + libvirt<br/>molecule runner · gitops timer"]:::host
    solar["solar<br/>homelab server · Tumbleweed<br/>caddy · arr + Plex · grafana · homepage"]:::host
    nas["administratum<br/>Synology NAS · DSM / Docker<br/>Prometheus · blackbox · NFS server"]:::host
  end

  subgraph hz["Hetzner Cloud"]
    rt["rogue-trader<br/>public VPS · Leap 16<br/>caddy · WordPress"]:::host
  end

  subgraph edge["Cloud edge — OpenTofu"]
    cf(["Cloudflare<br/>3 zones · DNS · WAF · TLS"]):::ext
    fb(["Firebase Hosting<br/>jonnyoc.uk site"]):::ext
  end

  scholam -->|"SSH · ansible apply"| solar
  scholam -->|"SSH · ansible apply"| nas
  scholam -.->|"SSH over WireGuard"| rt

  solar -->|"NFS 4.1: scriptorum (media)<br/>astropath (backups)"| nas
  rt -.->|"NFS astropath (over WireGuard)"| nas
  nas -.->|"Prometheus scrape (over WireGuard)"| rt

  internet --> cf
  cf -->|"proxied origin (WordPress)"| rt
  cf -->|"DNS-only apex"| fb

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
```

---

## 2. `solar` — service stack (podman quadlets)

caddy is the only thing publishing ports (80/443). Every backend is portless on
`caddy.network`; internal apps import a wildcard vhost snippet, the public
`homepage` gets an apex site block. The **arr** apps and transmission share the
WireGuard sidecar's network namespace — a kill-switch: if the tunnel is down
(or unconfigured), their traffic has nowhere to go. Plex is host-networked for
discovery + hardware transcode. Exporters sit on the host network. The media
share mounts at `/data` for Plex, transmission, and the `*arr` importers
(radarr/sonarr/lidarr) plus beets; each app keeps its state in a per-app named
volume.

```mermaid
flowchart TB
  lan(["LAN clients"]):::ext
  cfdns(["Cloudflare DNS-01<br/>(wildcard TLS)"]):::ext
  media[("NFS media<br/>/nfs/scriptorum/arr-data → /data")]:::store
  prom(["Prometheus @ NAS<br/>scrape + alerting — see §4"]):::ext

  caddy["caddy · reverse proxy<br/>:80 :443 · on caddy.network"]:::host
  grafana["grafana<br/>caddy.network · grafana.* · internal"]:::host
  homepage["homepage<br/>caddy.network · apex · public"]:::host
  beets["beets<br/>caddy.network · beets.* · web UI + timers"]:::host
  recyclarr["recyclarr<br/>caddy.network · config-sync worker"]:::host
  plex["Plex<br/>host network · /dev/dri · tmpfs transcode"]:::host

  subgraph vpn["netns = container:wireguard · kill-switch · transmission + *arr mount /data"]
    direction TB
    wg["wireguard · VPN sidecar / netns owner<br/>on caddy.network · alias → radarr / sonarr / lidarr / prowlarr / transmission"]:::host
    radarr["radarr"]:::host
    sonarr["sonarr"]:::host
    lidarr["lidarr"]:::host
    prowlarr["prowlarr"]:::host
    flaresolverr["flaresolverr"]:::host
    transmission["transmission"]:::host
  end

  nodeexp["node_exporter :9100<br/>host network"]:::host
  cadv["cadvisor :8080<br/>host network"]:::host
  am["alertmanager :9093<br/>host network"]:::host

  lan --> caddy
  caddy -.->|"ACME DNS-01"| cfdns
  caddy --> grafana
  caddy --> homepage
  caddy --> beets
  caddy -->|"via wg alias"| wg
  wg --- radarr
  wg --- sonarr
  wg --- lidarr
  wg --- prowlarr
  wg --- flaresolverr
  wg --- transmission

  media --> plex
  media --> beets

  grafana -->|"datasource"| prom
  prom -.->|"scrape"| nodeexp
  prom -.->|"scrape"| cadv
  prom -.->|"scrape"| am

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
```

---

## 3. `rogue-trader` — public WordPress stack

The public VPS. caddy fronts a three-container WordPress stack (Apache/PHP +
MariaDB + Redis) on `caddy.network`; Cloudflare proxies the apex to it with
`ssl=strict`. SSH is closed on the public interface — it rides the WireGuard
tunnel (LAN source), which also carries NFS-backups and the metrics scrape.

```mermaid
flowchart TB
  cf(["Cloudflare (proxied)<br/>emmasedit.com · WAF · rate-limit"]):::ext
  cfdns(["Cloudflare DNS-01"]):::ext
  nas(["NAS: NFS astropath server<br/>+ Prometheus scraper"]):::ext

  subgraph rt["rogue-trader (Leap 16)"]
    direction TB

    subgraph hnet["host network (bind: WireGuard IP)"]
      direction LR
      nodeexp["node_exporter :9100"]:::host
      cadv["cadvisor :8080"]:::host
    end

    caddy["caddy<br/>:80 :443"]:::host

    subgraph cnet["caddy.network"]
      direction TB
      wp["wordpress<br/>Apache/PHP · (public)"]:::host
      db["wordpress-db<br/>MariaDB"]:::host
      redis["wordpress-redis<br/>object cache"]:::host
    end

    subgraph timers["systemd timers"]
      direction LR
      wgre[["wireguard-reresolve<br/>keeps tunnel up on WAN-IP change"]]:::timer
      wptimers[["wp-cron 5m · db-dump daily<br/>update-check 6h"]]:::timer
    end

    vols[("volumes: wordpress-html (wp) ·<br/>wordpress-db (db) ·<br/>wordpress-db-dump (dump job)")]:::store
  end

  nas -.->|"scrape over WireGuard"| nodeexp
  nas -.->|"scrape over WireGuard"| cadv
  nodeexp ~~~ caddy
  cadv ~~~ caddy

  cf --> caddy
  caddy -.->|"ACME DNS-01"| cfdns
  caddy --> wp
  wp -->|"Requires/After"| db
  wp -->|"Wants/After"| redis
  wp ---|"wordpress-html"| vols
  db ---|"wordpress-db"| vols
  wptimers -.->|"wp-cron · dumps · metrics"| wp

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
  classDef timer fill:#f3e9fb,stroke:#8a53c1,color:#2e0d4d;
```

---

## 4. Observability & alerting

Prometheus runs on the NAS (Docker Compose — the NAS has no podman). It scrapes
node/cAdvisor exporters across the fleet plus a co-located blackbox_exporter that
probes the public sites. Alerts route to Alertmanager on `solar`, then out to
Discord and a healthchecks.io dead-man's-switch. Grafana (on `solar`) reads
Prometheus back over the LAN. Batch jobs publish outcomes as node_exporter
**textfile** metrics.

```mermaid
flowchart LR
  subgraph nas["administratum (NAS · Docker Compose)"]
    direction TB
    prometheus["Prometheus :9090<br/>scrape + rules"]:::host
    blackbox["blackbox_exporter :9115<br/>(loopback)"]:::host
    tsdb[("TSDB<br/>/volume2/astropath/prometheus/data")]:::store
  end

  subgraph targets["Scrape targets (host network)"]
    direction TB
    ne_solar["solar: node_exporter + cAdvisor"]:::host
    ne_rt["rogue-trader: node_exporter + cAdvisor<br/>(over WireGuard)"]:::host
    ne_sch["scholam: node_exporter"]:::host
  end

  subgraph textfiles["node_exporter textfile metrics (host-scoped producers)"]
    direction TB
    tf[("autoupdate (all) · podman_backup (solar, rt)<br/>gitops_reconcile (scholam) · beets pipeline (solar)<br/>wordpress dump/cron/updates (rt)")]:::store
  end

  am["Alertmanager :9093 @ solar"]:::host
  grafana["Grafana @ solar"]:::host
  discord(["Discord webhook"]):::ext
  deadman(["healthchecks.io<br/>dead-man's-switch"]):::ext
  sites(["public sites<br/>jonnyoc.uk · emmasedit.com · jonnyoc.co.uk"]):::ext

  prometheus -.->|"scrape"| ne_solar
  prometheus -.->|"scrape"| ne_rt
  prometheus -.->|"scrape"| ne_sch
  prometheus -->|"probe via"| blackbox
  blackbox -.->|"HTTP 2xx + TLS expiry"| sites
  tf --- ne_solar
  tf --- ne_rt
  tf --- ne_sch
  prometheus --- tsdb
  prometheus -.->|"scrape :9093"| am
  prometheus -->|"push alerts"| am
  am --> discord
  am -->|"Watchdog heartbeat"| deadman
  grafana -->|"datasource"| prometheus

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
```

> The NAS runs **no** node_exporter by design: its host metrics are DSM's domain,
> its free space is seen via the NFS mounts, and a total NAS outage trips the
> deadman (Prometheus dies with it, the heartbeat stops).

---

## 5. GitOps reconcile & backup / DR

Two independent loops. **GitOps** is anchored on `scholam` + `origin/main`: a
root timer pulls `origin/main` and applies the whole fleet — the sanctioned
unattended-apply path. **Backup** is anchored on the NAS: `podman_backup`
restic-snapshots every podman named volume to a per-host repo on the NAS, which a
Synology Hyper Backup task then replicates off-site.

```mermaid
flowchart TB
  gh(["GitHub · origin/main"]):::ext

  subgraph scholam["scholam"]
    gtimer[["gitops-reconcile.timer<br/>every 15m · Persistent"]]:::timer
    gsh["gitops-reconcile.sh<br/>fetch+reset · short-circuit on SHA<br/>ansible-playbook site.yml --diff"]:::host
    gpause[("pause flag · last-applied-sha<br/>out-of-band: vault_pass + SSH key")]:::store
  end

  site["playbooks/site.yml<br/>solar → rogue-trader → administratum → scholam (last)"]:::host

  subgraph backup["podman_backup (solar + rogue-trader)"]
    btimer[["podman-backup.timer<br/>Wed 01:00"]]:::timer
    bsh["podman-backup.sh<br/>quiesce quadlets · restic backup<br/>forget/prune · check"]:::host
  end

  vols[("podman named volumes<br/>DBs · app config · Plex · WordPress")]:::store
  restic[("restic repos @ NAS<br/>/nfs/astropath/&lt;host&gt;-podman-backup")]:::store
  hyper[["Synology Hyper Backup<br/>Wed 02:00"]]:::timer
  offsite(["off-site storage box"]):::ext

  gtimer --> gsh
  gsh --> gpause
  gsh -->|"fetch + reset --hard"| gh
  gsh -->|"apply"| site

  btimer --> bsh
  bsh -.->|"read volume mountpoints"| vols
  vols -->|"restic snapshot"| restic
  restic --> hyper
  hyper --> offsite

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
  classDef timer fill:#f3e9fb,stroke:#8a53c1,color:#2e0d4d;
```

> **DR** (`docs/disaster-recovery.md`): rebuild a host declaratively
> (`bootstrap` → `make apply PLAY=<host>`) then `podman-restore.sh` returns the
> volume state. `scholam`'s only state is the repo + `.vault_pass`; the NAS is
> the backup target, recovered via DSM + the off-site set.

---

## 6. Cloud edge & public request routing

One OpenTofu workspace manages three Cloudflare zones, the Hetzner firewall, and
the Firebase project — sharing one state so the Hetzner VM's live IP feeds the
Cloudflare apex record directly (origin IP never committed).

```mermaid
flowchart TB
  visitor(["Visitor"]):::ext

  subgraph cf["Cloudflare (OpenTofu-managed)"]
    direction TB
    z1["emmasedit.com<br/>proxied · WAF · cache · rate-limit"]:::host
    z2["jonnyoc.uk<br/>apex DNS-only · www edge-redirect"]:::host
    z3["jonnyoc.co.uk<br/>redirect zone → jonnyoc.uk"]:::host
  end

  rt["rogue-trader<br/>WordPress origin (Hetzner)"]:::host
  fw["hcloud vpc-firewall<br/>allow tcp 80/443 only"]:::host
  fbhost(["Firebase Hosting<br/>jonnyoc-website"]):::ext

  visitor --> z1
  visitor --> z2
  visitor --> z3
  z1 -->|"ssl=strict, proxied"| rt
  fw --- rt
  z2 -->|"apex A (DNS-only)"| fbhost
  z3 -->|"301"| z2

  hcloud(["Hetzner API"]):::ext
  hcloud -.->|"origin IP → apex A/AAAA<br/>(plan time, never committed)"| z1
  hcloud -.->|"server id → apply_to"| fw

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
```

---

## 7. CI/CD & IaC pipeline

`VAULT_PASSWORD` is the only classic CI secret; everything GCP-facing is keyless
via Workload Identity Federation. Note the split: **CI deploys the cloud edge and
the website; it does not deploy the Ansible fleet** — that is `gitops_reconcile`'s
job (§5). Ansible CI only lints and molecule-tests.

```mermaid
flowchart TB
  dev(["Developer / Renovate"]):::ext

  subgraph pr["Pull request"]
    lint["lint.yml<br/>pre-commit + gitleaks"]:::host
    mol["molecule.yml<br/>discover → changed roles + motd"]:::host
    tfplan["terraform.yml<br/>tofu plan → PR comment<br/>(+ weekly drift cron)"]:::host
    fbprev["firebase PR<br/>30-day preview channel"]:::host
    gosum["hugo-gosum-autofix"]:::host
  end

  subgraph tiers["Molecule tiers"]
    direction LR
    incus["incus: default + leap<br/>(free containers)"]:::host
    hetzt["hetzner<br/>(billable VM)"]:::host
  end

  subgraph main["Merge → main"]
    tfapply["terraform.yml<br/>tofu apply (ungated)"]:::host
    fblive["firebase merge<br/>live channel"]:::host
  end

  subgraph auth["Auth"]
    vault[("VAULT_PASSWORD<br/>only classic CI secret")]:::store
    wif(["GCP Workload Identity Federation<br/>tofu-plan · tofu-apply · firebase SAs"]):::ext
  end

  hcp(["HCP Terraform Cloud<br/>remote state"]):::ext
  cfhet(["Cloudflare · Hetzner"]):::ext
  fbdeploy(["Firebase Hosting"]):::ext
  gitops[["gitops_reconcile timer<br/>(deploys Ansible fleet, §5)"]]:::timer

  dev --> lint
  dev --> mol
  dev --> tfplan
  dev --> fbprev
  dev --> gosum
  mol --> incus
  mol --> hetzt
  hetzt -.->|"ansible-vault → hcloud token"| vault

  tfplan -.-> wif
  tfplan -.->|"vault-var.sh → TF_*"| vault
  fbprev -.-> wif
  fbprev -->|"preview channel"| fbdeploy

  main -->|"gitops timer pulls main"| gitops
  tfapply --> hcp
  tfapply --> cfhet
  tfapply -.-> wif
  tfapply -.->|"vault-var.sh → TF_*"| vault
  fblive --> fbdeploy
  fblive -.-> wif

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef ext fill:#fff4e6,stroke:#d98324,color:#5c3b00;
  classDef store fill:#eef7ee,stroke:#4a8a4a,color:#123312;
  classDef timer fill:#f3e9fb,stroke:#8a53c1,color:#2e0d4d;
```

---

## 8. Ansible role composition (per-host layering)

Roles compose in a set order per play: a baseline (account, SSH, firewall), then
the podman runtime and `autoupdate`, then caddy and the service backends; the
monitoring agents and `podman_backup` trail. `podman` must run first (it creates
the quadlet dir); `caddy` before any backend that drops a proxy snippet. Ordering
is enforced by the play — there are no `meta/dependencies`. The NAS runs none of
these (see matrix).

```mermaid
flowchart TB
  subgraph base["Baseline (openSUSE fleet)"]
    direction LR
    common["common"]:::host
    sshd["sshd"]:::host
    firewalld["firewalld"]:::host
  end

  subgraph rt_runtime["Runtime + early maintenance"]
    direction LR
    podman["podman<br/>(quadlet dir · netavark)"]:::host
    autoupdate[["autoupdate"]]:::timer
    wgre[["wireguard_reresolve<br/>(rogue-trader)"]]:::timer
    nfs["nfs"]:::host
    caddy["caddy"]:::host
  end

  subgraph svc["Service backends (podman quadlets)"]
    direction LR
    arr["arr + Plex"]:::host
    wordpress["wordpress"]:::host
    grafana["grafana"]:::host
    homepage["homepage"]:::host
  end

  subgraph obs["Agents / batch (trailing)"]
    direction LR
    nodeexp["node_exporter"]:::host
    cadvisor["cadvisor"]:::host
    alertmanager["alertmanager"]:::host
    podbak[["podman_backup"]]:::timer
  end

  subgraph ctrl["scholam-only"]
    direction LR
    incus["incus"]:::host
    libvirt["libvirt"]:::host
    dev["dev (+ stow)"]:::host
    gitops[["gitops_reconcile"]]:::timer
  end

  base --> rt_runtime
  podman --> svc
  caddy --> svc
  nfs --> arr
  rt_runtime --> obs
  base --> ctrl

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
  classDef timer fill:#f3e9fb,stroke:#8a53c1,color:#2e0d4d;
```

**Role → host matrix**

| Role | scholam | solar | rogue-trader | administratum |
|---|:--:|:--:|:--:|:--:|
| common · sshd · firewalld | ✅ | ✅ | ✅ | — |
| podman · autoupdate | ✅ | ✅ | ✅ | — |
| nfs | — | ✅ | ✅ | — |
| caddy | — | ✅ | ✅ | — |
| node_exporter | ✅ | ✅ | ✅ | — |
| cadvisor | — | ✅ | ✅ | — |
| podman_backup | — | ✅ | ✅ | — |
| arr · grafana · homepage · alertmanager | — | ✅ | — | — |
| wordpress · wireguard_reresolve | — | — | ✅ | — |
| incus · libvirt · dev · gitops_reconcile | ✅ | — | — | — |
| prometheus · blackbox_exporter · docker_prune | — | — | — | ✅ |

> The NAS (`administratum`) is not an openSUSE/podman host: it runs Docker
> Compose stacks unprivileged and gets none of the baseline roles. `stow`
> (dotfiles) and `motd` are omitted from the matrix — `stow` is pulled in by
> `common`/`dev` rather than assigned per host, and `motd` exists only as the
> molecule test exemplar.

---

## 9. Molecule test tiers

Each role ships molecule scenarios that CI runs against. Tiers share
role-agnostic create/destroy playbooks under `molecule/<tier>/`; a role keeps one
`converge`/`verify`, symlinked into its other scenarios. `motd` is the exemplar
carrying all four tiers.

```mermaid
flowchart LR
  role["roles/&lt;role&gt;/molecule/&lt;scenario&gt;"]:::host

  subgraph incus["incus (free containers)"]
    direction TB
    def["default · Tumbleweed"]:::host
    leap["leap · Leap 16<br/>(LEAP_ROLES subset)"]:::host
  end
  vm["libvirt · local full-boot VM"]:::host
  hz["hetzner · real Cloud VM (billable)<br/>= CI form of libvirt"]:::host

  cov["check-role-test-coverage.sh<br/>(pre-commit): default|libvirt required;<br/>libvirt ⇒ hetzner; LEAP_ROLES ⇒ leap"]:::host

  role -->|"primary (most roles)"| def
  role -.->|"+ leap if in LEAP_ROLES"| leap
  role -->|"or libvirt (no container tier)"| vm
  vm -->|"requires hetzner in CI"| hz
  cov -.->|"enforces coverage"| role

  classDef host fill:#e6f0ff,stroke:#3b6db3,color:#0b2545;
```
