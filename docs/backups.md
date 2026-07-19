# Backups

Two data sets are captured onto the NAS, and each is then guarded twice — against
silent corruption where it sits, and against loss of the NAS itself. Four layers:

| Layer | Protects | On the NAS | Cadence | Owned by |
|---|---|---|---|---|
| Podman volume backup | container state on `solar` and `rogue-trader` | per-host restic repo under `astropath` | weekly, Wed 01:00 | `podman_backup` role — this repo |
| Photo library | the Google Photos archive | `/scriptorum/photos` | on demand | [`negative-space`](https://github.com/jedimasterjonny/negative-space) — external |
| Bit-rot scrub | every block on both arrays | `scriptorum` + `astropath` | monthly | DSM — NAS-side |
| Off-site mirror | the restic repos and the photo library | Hetzner storage box | podman weekly Wed 02:00 · photos daily 03:00 | DSM Hyper Backup — NAS-side |

Only the first is Ansible-managed. The rest are DSM tasks on the NAS or an
external app — recorded here, not codified. Recovery is in
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
stateless, so it has no repo. Container media on the NFS shares is deliberately
out of the repo — it lives on the NAS and is re-acquirable. Role mechanics:
[`roles/podman_backup/README.md`](../roles/podman_backup/README.md).

## Photo library — negative-space

A Google Photos Takeout, exported by hand onto the NAS, is turned into a
chronological, deduplicated, metadata-clean library at `/scriptorum/photos` by
[`negative-space`](https://github.com/jedimasterjonny/negative-space), the
operator's Python app. It runs on demand from the laptop; the heavy I/O runs on
the NAS over SSH, since the Takeout is ~800 GB and the wire is the bottleneck. The
app is external to this repo and not deployed by it — what it produces is the
library the scrub and the mirror below protect.

## Bit-rot scrub

DSM runs a btrfs data scrub monthly across both arrays — `scriptorum` (24 TB SHR1)
and `astropath` (380 GB RAID1 NVMe) — reading every block against its checksum and
recovering any mismatch from the array's redundancy, so silent bit-rot in the
media, the photo library, or the restic repos is corrected in place rather than
mirrored outward. It complements restic's own data-pack re-read, which covers only
the podman repos.

## Off-site mirror

Two Synology Hyper Backup tasks mirror the on-NAS backups to a Hetzner storage box
over rsync — each a plain mirror (latest state only, no version history), encrypted
in transit but stored unencrypted, the box trusted like the NAS share itself:

- **`podman-backup`** — the two `*-podman-backup` restic repos (`solar`,
  `rogue-trader`), weekly on Wednesday at 02:00, an hour after the restic run. A
  true mirror: a snapshot pruned on the NAS is dropped off-site too.
- **`photos-backup`** — the `/scriptorum/photos` library, daily at 03:00. Additive
  — it never deletes at the destination, so the off-site copy of a photo outlives
  its removal from the NAS.

A failed run alerts by email. This is the only geographic redundancy: the 24 TB
media library is not mirrored (it is re-acquirable), so a total NAS loss keeps the
container state and the photos, not the media.
