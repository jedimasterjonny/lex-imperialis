# Backups

Backups land on the NAS from two directions. Three fleet and photo data sets —
container volumes, home directories, and the photo library — are each guarded
twice: against silent corruption where they sit (a btrfs scrub) and against loss
of the NAS itself (an off-site mirror). The operator's laptop separately backs
itself up to the NAS over Time Machine — scrubbed like the rest, but not mirrored
off-site, since the laptop is its own second copy. Six layers:

| Layer | Protects | On the NAS | Cadence | Owned by |
|---|---|---|---|---|
| Podman volume backup | container state on `solar` and `rogue-trader` | per-host restic repo under `astropath` | weekly, Wed 01:00 | `podman_backup` role — this repo |
| Home directory backup | `/home` on `solar`, `scholam`, and `rogue-trader` | per-host restic repo under `astropath` | weekly, Thu 01:00 / 02:00 / 03:00 | `home_backup` role — this repo |
| Photo library | the Google Photos archive | `/scriptorum/photos` | on demand | [`negative-space`](https://github.com/jedimasterjonny/negative-space) — external |
| Laptop Time Machine | the operator's laptop | `time-machine` SMB share on `scriptorum` (1 TB cap) | hourly, by macOS | macOS + DSM — external |
| Bit-rot scrub | every block on both arrays | `scriptorum` + `astropath` | monthly | DSM — NAS-side |
| Off-site mirror | the podman + home restic repos and the photo library | Hetzner storage box | podman Wed 02:00 · home Thu 04:00 · photos Tue 03:00 | DSM Hyper Backup — NAS-side |

The first two are Ansible-managed — `podman_backup` and `home_backup`, both thin
consumers of the shared `restic_backup` engine. The rest are DSM tasks on the NAS
or an external app — recorded here, not codified. Recovery is in
[`disaster-recovery.md`](disaster-recovery.md).

## Podman volume backup

`podman_backup` snapshots every podman named volume on `solar` and `rogue-trader`
— databases, app config, the Plex library and history, the WordPress site — with
restic to `/nfs/astropath/<hostname>-podman-backup`, weekly (Wed 01:00), keeping a
rolling window of weekly then monthly snapshots. Each run `restic check`s the repo
and re-reads a rotating slice of the data packs — the whole repo over successive
runs — so structural corruption and bit-rot inside the repo page as
`PodmanBackupFailed` instead of surfacing at restore; a missed run raises
`PodmanBackupOverdue`. `scholam`'s only workload (`node_exporter`) is
stateless, so it has no podman repo. Container media on the NFS shares is deliberately
out of the repo — it lives on the NAS and is re-acquirable. Role mechanics:
[`roles/podman_backup/README.md`](../roles/podman_backup/README.md).

## Home directory backup

`home_backup` snapshots `/home` on `solar`, `scholam`, and `rogue-trader` with
restic to `/nfs/astropath/<hostname>-home-backup`, weekly, keeping the same rolling
weekly-then-monthly window as the podman backup — all are thin consumers of a
shared `restic_backup` engine. No quiescing: home directories are backed up live,
so the snapshot is crash-consistent. Each run `restic check`s the repo (the same
rotating data-pack re-read), so corruption pages as `HomeBackupFailed` rather than
surfacing at restore; a missed run raises `HomeBackupOverdue`. The hosts are
staggered (`solar` Thu 01:00, `scholam` Thu 02:00, `rogue-trader` Thu 03:00) so
they don't snapshot to the astropath export at once. Its off-site mirror is a
NAS-side Hyper Backup task at Thu 04:00, after all three runs. Role mechanics:
[`roles/home_backup/README.md`](../roles/home_backup/README.md).

## Photo library — negative-space

A Google Photos Takeout, exported by hand onto the NAS, is turned into a
chronological, deduplicated, metadata-clean library at `/scriptorum/photos` by
[`negative-space`](https://github.com/jedimasterjonny/negative-space), the
operator's Python app. It runs on demand from the laptop; the heavy I/O runs on
the NAS over SSH, since the Takeout is ~800 GB and the wire is the bottleneck. The
app is external to this repo and not deployed by it — what it produces is the
library the scrub and the mirror below protect.

## Laptop Time Machine

The operator's laptop backs itself up to the NAS over Time Machine, into a
1 TB-capped SMB share (`time-machine`) on the `scriptorum` HDD array. macOS drives
it — hourly while the laptop is on the network — and DSM only presents the share.
It rides the monthly btrfs scrub like everything on `scriptorum`, but is not
mirrored off-site: the laptop itself is the second copy.

## Bit-rot scrub

DSM runs a btrfs data scrub monthly across both arrays — `scriptorum` (24 TB SHR1)
and `astropath` (380 GB RAID1 NVMe) — reading every block against its checksum and
recovering any mismatch from the array's redundancy, so silent bit-rot in the
media, the photo library, or the restic repos is corrected in place rather than
mirrored outward. It complements restic's own data-pack re-read, which covers only
the podman repos.

## Off-site mirror

Three Synology Hyper Backup tasks mirror the on-NAS backups to a Hetzner storage
box over rsync — each a plain mirror (latest state only, no version history),
encrypted in transit but stored unencrypted, the box trusted like the NAS share
itself. Each is a true mirror — a file removed on the NAS is removed off-site too,
so a pruned restic snapshot or a deleted photo does not linger. They sit on
separate weekly slots so they don't contend on the uplink, each after the run it
copies so it never captures a mid-write repo:

- **`podman-backup`** — the two `*-podman-backup` restic repos (`solar`,
  `rogue-trader`), Wednesday 02:00, an hour after the restic run.
- **`home-backup`** — the `*-home-backup` restic repos (`solar`, `scholam`,
  `rogue-trader`), Thursday 04:00, after the hosts' Thursday runs.
- **`photos-backup`** — the `/scriptorum/photos` library, Tuesday 03:00.

A failed run alerts by email. This is the only geographic redundancy: the 24 TB
media library is not mirrored (it is re-acquirable), so a total NAS loss keeps the
container state, the home backups, and the photos, not the media or the laptop's
Time Machine history (the laptop itself is unaffected).
