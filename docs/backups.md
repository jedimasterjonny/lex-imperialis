# Backups

Backups land on the NAS from two directions. Three fleet and photo data sets —
container volumes, home directories, and the photo library — are each guarded
twice: against silent corruption where they sit (a btrfs scrub) and against loss
of the NAS itself (an off-site mirror). The operator's laptop separately backs
itself up to the NAS over Time Machine — scrubbed like the rest, but not mirrored
off-site, since the laptop is its own second copy. Six layers:

| Layer | Protects | On the NAS | Cadence | Owned by |
| --- | --- | --- | --- | --- |
| Podman volume backup | container state on `solar` and `rogue-trader` | per-host restic repo under `astropath` | weekly, Wed 00:00 / 01:00 | `podman_backup` role — this repo |
| Home directory backup | `/home` on `solar`, `scholam`, and `rogue-trader` | per-host restic repo under `astropath` | weekly, Thu 01:00 / 02:00 / 03:00 | `home_backup` role — this repo |
| Photo library | the Google Photos archive | `/scriptorum/photos` | on demand | [`negative-space`](https://github.com/jedimasterjonny/negative-space) — external |
| Laptop Time Machine | the operator's laptop | `time-machine` SMB share, a sibling of `scriptorum` on the same array (1 TB cap) | hourly when the laptop is on the network | macOS + DSM — external |
| Bit-rot scrub | every block on both arrays | `scriptorum` + `astropath` | monthly | DSM — NAS-side |
| Off-site mirror | the podman + home restic repos and the photo library | Hetzner storage box, via rogue-trader | podman Wed 02:00 · home Thu 04:00 · photos Tue 03:00 | DSM Hyper Backup — NAS-side |

Times are each host's local clock — `solar`, `scholam` and `auspex` on
Europe/London, `rogue-trader` and the NAS on UTC year-round.

The first two are Ansible-managed — `podman_backup` and `home_backup`, both thin
consumers of the shared `restic_backup` engine. The rest are DSM tasks on the
NAS or an external app — recorded here, not codified. `auspex` runs neither
role: its Prometheus TSDB and Alertmanager state have no copy, accepted as
derived data. Recovery is in [`disaster-recovery.md`](disaster-recovery.md).

## Podman volume backup

`podman_backup` snapshots every podman named volume on `solar` and
`rogue-trader` — databases, app config, the Plex library and history, the
WordPress site — with restic to `/nfs/astropath/<hostname>-podman-backup`,
weekly, keeping 8 weekly then 6 monthly snapshots. Every container on the host
is stopped for the snapshot — under two minutes — and restarted before the
integrity check, so the databases are quiesced rather than caught mid-write.
Each run `restic check`s the repo and re-reads a rotating slice of the data
packs — the whole repo over successive runs — so structural corruption and
bit-rot inside the repo page as `PodmanBackupFailed` instead of surfacing at
restore; a missed run raises `PodmanBackupOverdue`. The two hosts are staggered
— `solar` Wednesday 00:00 and `rogue-trader` Wednesday 01:00 — because their
clocks differ: `solar` is on Europe/London and `rogue-trader` on UTC year-round,
so one shared slot would put both on the astropath export at the same instant
for the whole GMT half of the year. Staggered, both finish well inside the
Wednesday 02:00 UTC off-site mirror window below. `scholam` carries no podman
repo: its only podman workload, `node_exporter`, defines no named volume, so
`podman_backup` is left off its play. Container media on the NFS shares is
deliberately out of the repo — it lives on the NAS and is re-acquirable. Role
mechanics: [`roles/podman_backup/README.md`](../roles/podman_backup/README.md).

## Home directory backup

`home_backup` snapshots `/home` on `solar`, `scholam`, and `rogue-trader` with
restic to `/nfs/astropath/<hostname>-home-backup`, weekly, keeping the same 8
weekly then 6 monthly snapshots as the podman backup — all are thin consumers of
a shared `restic_backup` engine. No quiescing: home directories are backed up
live and read across the run, so a file being written can be captured torn —
home directories tolerate that, a database would not. The snapshot is `/home`
minus re-acquirable churn (caches, virtualenvs, `node_modules`, the rootless
podman store) and minus `.vault_pass`: the repo key comes from the vault, so the
vault password is deliberately in no snapshot. Restoring it is a prerequisite of
recovery, not an output of it. Each run `restic check`s the repo (the same
rotating data-pack re-read), so corruption pages as `HomeBackupFailed` rather
than surfacing at restore; a missed run raises `HomeBackupOverdue`. The hosts
are staggered (`solar` Thu 01:00, `scholam` Thu 02:00, `rogue-trader` Thu 03:00)
so they don't snapshot to the astropath export at once. Its off-site mirror is a
NAS-side Hyper Backup task at Thu 04:00, after all three runs. Role mechanics:
[`roles/home_backup/README.md`](../roles/home_backup/README.md).

## Photo library — negative-space

A Google Photos Takeout, exported by hand onto the NAS, is turned into a
chronological, largely deduplicated, metadata-clean library at
`/scriptorum/photos` by
[`negative-space`](https://github.com/jedimasterjonny/negative-space), the
operator's Python app. It runs on demand from the laptop; the heavy I/O runs on
the NAS over SSH, since the Takeout is ~800 GB and the wire is the bottleneck.
The app is external to this repo and not deployed by it — what it produces is
the library the scrub and the mirror below protect.

## Laptop Time Machine

The operator's laptop backs itself up to the NAS over Time Machine, into a 1
TB-capped SMB share (`time-machine`), a sibling of `scriptorum` on the same HDD
array. macOS drives it — hourly while the laptop is on the network, best-effort
and with no overdue alert — and DSM's part is a per-share SMB Time Machine
toggle plus the Bonjour advertisement that makes it selectable; it neither
schedules nor thins the backup. It rides the monthly btrfs scrub like everything
on that array, but is not mirrored off-site: the laptop still holds the current
data, though the restore-point history exists only here.

## Bit-rot scrub

DSM runs a btrfs data scrub monthly across both arrays — `scriptorum` and
`astropath` — reading every block against its checksum and recovering any
mismatch from the array's redundancy, so silent bit-rot in the photo library or
the restic repos is corrected in place rather than copied to the off-site
mirror. It complements restic's own data-pack re-read, which covers the podman
and home repos alike. For the media and the Time Machine share, which have no
off-site copy at all, the scrub is the only protection there is.

## Off-site mirror

Three Synology Hyper Backup tasks mirror the on-NAS backups to a Hetzner storage
box over rsync — each a plain mirror (latest state only, no version history),
encrypted in transit. They do not reach the box directly: each targets the
`storagebox_gateway` forward on `rogue-trader`, which is what lets the box
refuse every source outside Hetzner — a Hetzner Console setting, not this
repo's. That gate is Hetzner's network, so it removes internet-wide scanning and
nothing more; the box's real protection remains its SSH credentials. Every repo
is encrypted with a per-host restic key held in the vault, so the off-site copy
is opaque to the provider — and unreadable without the vault password, which is
the single key to every backup. `photos-backup` is not a restic repo: the
library is mirrored in the clear. Each is a true mirror — a file removed on the
NAS is removed off-site too, so a pruned restic snapshot or a deleted photo does
not linger. Because there is no version history, the off-site copy protects
against loss of the NAS and nothing else: for the restic repos that is
survivable, since their snapshot history travels inside the repo, but
`/scriptorum/photos` has no share snapshots on either volume, so a deleted or
corrupted photo is gone from both copies within a week. They sit on separate
weekly slots so they don't contend on the uplink, each after the run it copies
so it never captures a mid-write repo:

- **`podman-backup`** — the two `*-podman-backup` restic repos (`solar`,
  `rogue-trader`), Wednesday 02:00, after both hosts' Wednesday runs.
- **`home-backup`** — the `*-home-backup` restic repos (`solar`, `scholam`,
  `rogue-trader`), Thursday 04:00, after the hosts' Thursday runs.
- **`photos-backup`** — the `/scriptorum/photos` library, Tuesday 03:00.

Routing through `rogue-trader` makes it a single point of failure for all three.
`ProbeDown` covers the forward's reachability (auspex, `tcp_ssh_banner`) but not
its authorisation: the box enforces its source restriction inside sshd, so a
refused source still answers with a banner and the probe stays green while every
mirror fails — only the Hyper Backup task notification catches that. Its
`autoupdate` reboot moved from Wed 03:00 to 06:00 so a transactional reboot
cannot cut the Wed 02:00 mirror — see `playbooks/rogue-trader.yml` for the
four-hour assumption.

A failed run alerts by email. This is the only geographic redundancy: the media
library is not mirrored (it is re-acquirable), so a total NAS loss keeps the
container state, the home backups, and the photos, not the media,
`pathfinder-books`, the DSM `homes` share, or the laptop's Time Machine history
(the laptop itself is unaffected). `restic check` proves the repos are
structurally sound and their packs re-hash clean; it does not prove a restore
works end to end, and no restore drill is scheduled or recorded.
