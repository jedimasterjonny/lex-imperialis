# Backups

Backups land on the NAS from two directions. Three fleet and photo data sets —
container volumes, home directories, and the photo library — are each guarded
twice: against silent corruption where they sit (a btrfs scrub) and against loss
of the NAS itself (an off-site mirror) — and the restic repos a third time, in a
second off-site copy that shares neither provider nor route with the first. The
operator's laptop separately backs itself up to the NAS over Time Machine —
scrubbed like the rest, but not mirrored off-site, since the laptop is its own
second copy. Seven layers:

| Layer | Protects | On the NAS | Cadence | Owned by |
| --- | --- | --- | --- | --- |
| Podman volume backup | container state on `solar` and `rogue-trader` | per-host restic repo under `astropath`, `xenos` for `rogue-trader` | weekly | `podman_backup` role — this repo |
| Home directory backup | `/home` on `solar`, `scholam`, and `rogue-trader` | per-host restic repo under `astropath`, `xenos` for `rogue-trader` | weekly | `home_backup` role — this repo |
| Photo library | the Google Photos archive | `/scriptorum/photos` | on demand | [`negative-space`](https://github.com/jedimasterjonny/negative-space) — external |
| Laptop Time Machine | the operator's laptop | `time-machine` SMB share, a sibling of `scriptorum` on the same array (1 TB cap) | hourly when the laptop is on the network | macOS + DSM — external |
| Bit-rot scrub | every block on both arrays | `scriptorum` + `astropath` | monthly | DSM — NAS-side |
| Off-site mirror | the podman + home restic repos and the photo library | Hetzner storage box in Finland, via rogue-trader | weekly, staggered | DSM Hyper Backup — NAS-side |
| Second off-site copy | the podman + home restic repos | Cloudflare R2 `reclusiam`, Western Europe | weekly, staggered | DSM Hyper Backup — NAS-side |

One clock end to end. Every fleet host keeps `Europe/London`, held by the
`common` role rather than left to the image; the NAS keeps it too, though it is
out of the inventory, so its clock is DSM's to hold. That is what the stagger is
built on: the gap between a run and the mirror that copies it is the same all
year. The whole week, alongside every other scheduled job on the estate, is in
[`schedule.md`](schedule.md).

Run durations are in `offsite_mirror_task_duration_seconds` rather than either
document — last-run values, not budgets. The R2 tasks have none: DSM's manifest
for a cloud target records no duration, which is the same gap `r2_mirror` exists
for.

The first two are Ansible-managed — `podman_backup` and `home_backup`, both thin
consumers of the shared `restic_backup` engine. Their repos share one export,
`astropath`, except `rogue-trader`'s: the public box writes to `xenos`, exported
to it alone, so a compromise there reaches its own two repos and no others. The
rest are DSM tasks on the
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
— `solar` Wednesday 00:00 and `rogue-trader` Wednesday 01:00 — so neither is
writing to the backup array while the other is. Both finish well inside the Wednesday
02:00 off-site mirror window below, an hour of clearance year-round. That
clearance is the reason the stagger runs earlier rather than later: the mirror
must find both repos complete. `scholam` carries no podman repo: its only
podman workload, `node_exporter`, defines no named volume, so `podman_backup`
is left off its play. Container media on the NFS shares is deliberately out of
the repo — it lives on the NAS and is re-acquirable. Role mechanics:
[`roles/podman_backup/README.md`](../roles/podman_backup/README.md).

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
so they don't snapshot to the backup array at once. Its off-site mirror is
a NAS-side Hyper Backup task at Thu 04:00, an hour clear of the last run
year-round. Role mechanics:
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
off-site copy at all, the scrub is the only protection there is. Nothing in this
repo watches it: reading a scrub's result needs root on the NAS, which this repo
does not have, so its failure signal is DSM's mail alone.

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
mirror fails. The Hyper Backup task notification catches that, and so does the
probe below — as `OffsiteMirrorTaskFailed` if DSM records the refusal in each
task's cached manifest, and otherwise as `OffsiteMirrorTaskOverdue` once the last
success ages past a week. Its `autoupdate` reboot sits at Wed 07:00 so a
transactional reboot cannot cut the Wed 02:00 mirror: with the timer's two-hour
randomised delay it lands 07:00–09:00, so the mirror is guaranteed five hours —
see `playbooks/rogue-trader.yml` for the four-hour assumption that sets the
slot.

A failed run alerts by email, as does a failed scrub: DSM's notification profile
routes storage and backup events to the Synology-Account mail, and task
notification is on for all three tasks. This is the only geographic redundancy:
the media library is not mirrored (it is re-acquirable), so a total NAS loss
keeps the container state, the home backups, and the photos, not the media,
`pathfinder-books`, the DSM `homes` share, or the laptop's Time Machine history
(the laptop itself is unaffected). `restic check` proves the repos are
structurally sound and their packs re-hash clean; it does not prove a restore
works end to end. The first drill that did — 2026-08-25, non-destructive, into
scratch dirs — found both repos clean and the recovery path defective; the
findings and their fixes are in [`disaster-recovery.md`](disaster-recovery.md).
No next drill is scheduled.

### What a task notification cannot see

A Hyper Backup task that stops copying a folder does not fail. It finishes,
reports success and mails nothing, so a repo can fall out of the off-site copy
with every run green and every notification clean —
`rogue-trader-home-backup` was absent from the `home-backup` task for five weeks
that way, and nothing on either side noticed. The covered set is observable only
in the manifest DSM caches beside each task, which the `offsite_mirror` role on
`auspex` reads daily over SSH as an unprivileged account and republishes as
node_exporter textfile metrics: what each task last copied, when it last
succeeded, and how long it took.

`playbooks/auspex.yml` declares what each task must cover, so
`OffsiteMirrorCoverageMissing` fires on a repo that is declared and absent from
the manifest — the alert that would have caught those five weeks.
`OffsiteMirrorTaskFailed` and `OffsiteMirrorTaskOverdue` read the same manifest
for the failure and freshness DSM's mail also reports, on the fleet's own alerting
path rather than an inbox. `OffsiteMirrorTaskUnverified` covers a task the cache
says nothing about, and the `OffsiteMirrorProbeFailed` / `OffsiteMirrorProbeOverdue`
pair the probe itself losing the NAS: a probe that cannot read the cache leaves the
last payload standing, so the other four rules go stale rather than wrong, and that
pair is the only thing that says so. Nothing here touches the NAS — the probe's
public key is installed on it by hand, and until that is done no metric flows.
Role mechanics: [`roles/offsite_mirror/README.md`](../roles/offsite_mirror/README.md).

## Second off-site copy — R2

A seventh layer answers the one thing port-wander cannot: both the NAS and the
storage box failing together, or the mirror faithfully copying damage onto the
only other copy. Two DSM Hyper Backup tasks write the restic repos to the
Cloudflare R2 bucket `reclusiam`, provisioned in
[`terraform/r2-reclusiam.tf`](../terraform/r2-reclusiam.tf) and hinted to
Western Europe — port-wander is in Finland, so a regional loss cannot take both.
`podman-backup-r2` copies the two `*-podman-backup` repos on Wednesday 06:00 and
`home-backup-r2` the three `*-home-backup` repos on Thursday 06:00 — four hours
behind the port-wander mirror of the same repos for podman, two for home, so the
two copies never read the backup array or the uplink at once. They share the
bucket but not a Hyper Backup container: the target directory puts them in
`podman.hbk` and `home.hbk`, which is what lets one bucket hold both without
their version chains touching. The photo library is not copied here — it stays
port-wander's alone.

port-wander is reached through the `storagebox_gateway` forward on
`rogue-trader`; the NAS reaches R2 directly over HTTPS, so `rogue-trader` being
down or rebuilt cannot stop the second copy.

Unlike the port-wander tasks this is not a plain file mirror — Hyper Backup's S3
target writes its own versioned container, so restoring goes through Hyper Backup
rather than being a file copy. A pruned snapshot or a damaged repo on the NAS
propagates to port-wander at its next window, and does not immediately overwrite
what R2 already holds. Smart Recycle caps both tasks at 52 versions — a year of
weekly runs, and nearer eighteen months of reachable history once the six months
of snapshots each retained container holds inside it are counted. The cap is what
governs, not the recycle tiers: a weekly job produces one version per run, so
nothing is ever thinned. Measured pack churn puts a year at roughly 30 GB for the
home repos and 25 GB for the podman ones.

Compression is off on both. The repos are restic packs encrypted with per-host
keys, and a sampled pack gzips to 100.02% of its size — it would cost NAS CPU to
make the data marginally larger. Hyper Backup's own encryption is off for the same
reason, the payload already being ciphertext; the consequence is that the
container's control objects are readable by anything holding the S3 key, and they
name the NAS, its model, and the source paths. Nothing secret, but not nothing.
Uploads use 64 MB parts: large enough that the per-part write charges are noise,
small enough that a failed part is a cheap retry and the buffer is not half a
gigabyte of NAS memory.

A weekly integrity check reads each container back out of R2 — `home-backup-r2`
on Friday 08:00, `podman-backup-r2` on Sunday 08:00, on separate days so neither
grows into the other. 08:00 because it is clear on every day of the week — past
the overnight block the backups and mirrors run in, and past the Saturday UniFi
window — so the slot needs no per-day arithmetic and stays right if a job moves.
This is the only thing that verifies these copies are readable at all: restic's
own `check` covers the source repos and the btrfs scrub covers the NAS, but
neither sees what R2 actually holds. R2 charges no egress, so the read costs
nothing but time.

Neither task is watched by the `offsite_mirror` probe, and neither can be: DSM's
manifest for a cloud target carries no task name, status, last-run time or folder
list, so every `OffsiteMirror*` task rule is structurally inert here, and
declaring the tasks in `playbooks/auspex.yml` would raise
`OffsiteMirrorTaskUnverified` forever.

The `r2_mirror` role covers it instead, from the other end: a daily probe on
`auspex` that lists the bucket and publishes what each container actually holds —
objects, bytes, the newest write as a freshness proxy, and uploads started but
never completed. `R2MirrorContainerMissing` measures the bucket against the
containers the play declares, `R2MirrorContainerStale` gives the weekly upload the
same 8-day grace its port-wander counterpart gets, `R2MirrorStrandedParts` catches
interrupted uploads that bill as storage while appearing in no listing, and
`R2MirrorProbeFailed` covers the probe's own silence. Role mechanics:
[`roles/r2_mirror/README.md`](../roles/r2_mirror/README.md).

The probe holds a read-only key, separate from the tasks': a compromised
`auspex` must not be able to delete the copy it watches. Both are in
[`secret-rotation.md`](secret-rotation.md).
