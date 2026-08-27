# restic_backup

The fleet's restic backup engine. Installs restic, renders a per-host backup
script and its node_exporter outcome metric, and drives them from a systemd timer
(persistent), pruning to `restic_backup_keep_weekly` / `_keep_monthly` and ending
each run in a `restic check` that verifies repository integrity — a failed check
fails the service, so a `*BackupFailed` alert catches silent structural
corruption the snapshot and prune steps leave unverified, instead of it surfacing
only at restore. The check runs last (after the container restart in
podman-volumes mode), so it adds no downtime. By default it also re-hashes the
data packs, catching bit-rot the metadata check cannot: each run reads one
deterministic `1/N` slice (restic's `n/t` subset), rotating by ISO week so the
whole repo is re-read roughly every `restic_backup_check_read_data_weeks` runs
(default 10). The `n/t` slice is stable across the retry below, so a real fault
fails every attempt and pages rather than being dodged by a re-drawn random
subset. Set the var empty (or 0) to revert to a metadata-only check. Each restic
call is retried: the astropath NFS mount intermittently serves a spurious ENOENT
mid-run that would otherwise fail an isolated operation.

Each run clears stale locks before it starts. restic does not skip a lock whose
owning process is dead when it takes its own, so an interrupted ad-hoc `restic` —
a killed `restic ls` is enough — leaves one that refuses the exclusive
`forget --prune` and fails every scheduled run until it is removed by hand, with
the snapshot itself already saved. `restic unlock` drops only stale locks, so a
genuinely concurrent run keeps its own; `--retry-lock` is no use, since it
re-checks the same lock and refuses just the same.

Retention groups snapshots by `host,tags`, not restic's default `host,paths`: in
podman-volumes mode the paths are the volume mountpoints, so adding or removing a
container would otherwise open a fresh retention group and freeze the old one,
its snapshots pinned as that group's newest weeklies and never ageing out.
`restic_backup_tag` is fixed per consumer where the source set is not, so one
repository keeps one retention lineage.

The repo lives at `<restic_backup_root>/<hostname>-<restic_backup_name>-backup`,
unlocked by a password rendered to `restic_backup_password_file` (0600 root) from
a host-scoped vault var. One key per host, not one per fleet: the export carries
every host's repos and is mirrored to a third party, so a host that is
compromised must not be able to open another host's backups. An empty
`restic_backup_password` is rejected at converge. Assumes the `nfs` role has
mounted the target; podman-volumes mode also assumes `podman`.

`restic_backup_root` must be a live mountpoint, asserted immediately before the
repository is created and again before the snapshot is written — not once at the
top, because in podman-volumes mode the quiesce runs in between and stopping the
last podman bridge is itself what fires the NetworkManager event that unmounts
the `_netdev` share (see `roles/podman`). Unmounted, the mountpoint directory
remains on the root filesystem, so an unguarded run would create a shadow repo
there, initialise it, back up into it and exit 0 reporting success while the real
repository silently stopped receiving snapshots.

Consumers `include_role` this engine and set the vars — `podman_backup` and
`home_backup` are the two. The on-NAS repos are mirrored off-site out of band by
three NAS-side Synology Hyper Backup tasks, each covering a named list of repos —
a new repo under `astropath` does not inherit one. See [`docs/backups.md`](../../docs/backups.md)
for the full backup architecture and
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md) for recovery.

## Variables

Every var carries a default except the three a consumer must set. The repo path,
script and unit basenames, and the metric names all derive from
`restic_backup_name`, so a consumer that sets `name: home` gets a
`home-backup.service`/`.timer`, a `home-backup.sh` script, a `<hostname>-home-backup`
repo, and `home_backup_success` / `home_backup_last_run_timestamp_seconds` metrics.

Consumer-set (no default):

- `restic_backup_name` — short identity; everything above derives from it.
- `restic_backup_description` — human phrase for the unit descriptions.
- `restic_backup_oncalendar` — systemd `OnCalendar` for the timer.

Tunable (defaulted): `restic_backup_root`, `restic_backup_tag`,
`restic_backup_paths`, `restic_backup_excludes`, `restic_backup_podman_volumes`,
`restic_backup_script_dir`, `restic_backup_textfile_dir`,
`restic_backup_keep_weekly`, `restic_backup_keep_monthly`,
`restic_backup_check_read_data_weeks`, `restic_backup_timeout_start_sec`,
`restic_backup_package`.

`restic_backup_timeout_start_sec` (default `1h`) caps a run. `Type=oneshot`
disables the start timeout altogether rather than inheriting
`DefaultTimeoutStartSec`, so unset means *infinity*: with `hard` NFS a wedged call
holds the unit in `activating` indefinitely, and in podman-volumes mode it does so
with every container stopped. Nothing else covers that — `SystemdUnitFailed`
excludes these units by regex, and a unit stuck in `activating` never reaches
`failed`. On expiry the script takes SIGTERM, its EXIT trap restarts the
containers, and the failed unit trips the usual `*BackupFailed` alert.

## Modes

- **Path backup** (default) — snapshots the absolute paths in
  `restic_backup_paths`. No quiescing: the snapshot is crash-consistent.
- **Podman-volumes** (`restic_backup_podman_volumes: true`) — the sources are the
  host's podman volume mountpoints, enumerated at run time; the quadlet container
  units are quiesced for a consistent snapshot and always restarted (a trap, so
  they return even if the backup fails). A quadlet glob matching nothing fails the
  run rather than proceeding: this mode exists to avoid snapshotting a live
  database, so nothing to quiesce means a broken assumption, not an idle night.
  The service is additionally ordered `After=multi-user.target` in this mode. The
  timer is `Persistent=true`, so a host that was off over its window fires a
  catch-up run at boot, and unordered that run races the quadlet units' start —
  the quiesce finds none of them active yet, stops nothing, and snapshots a live
  database while reporting success. The zero-match guard does not cover it: the
  `.container` files are all present, they are simply not started. Every quadlet
  unit is `Type=notify` with `Before=multi-user.target`, so the target is reached
  only once each container has signalled ready. Ordering only, so a container that
  fails to start delays nothing, and a no-op for the normal scheduled run. Path
  mode does not take this ordering — it has nothing to quiesce. Deliberately not an
  "the quiesce stopped at least one unit" assertion instead: a fleet stopped for
  maintenance quiesces nothing and is genuinely consistent, so that would fail
  correct runs.
  This mode also installs `<name>-restore.sh`, the inverse of the backup for
  disaster recovery: run it on a host **after its play has converged**. It takes
  an optional snapshot ID (default `latest`), so a recovery can skip past a bad
  snapshot instead of being stuck with whichever is newest. A path backup restores
  by hand with `restic restore`.

  The restore reads the **whole snapshot into a scratch target first** and swaps
  it into the live volumes only once that has succeeded, so a repository that is
  unreachable, truncated or bit-rotted costs nothing: the volumes are untouched
  and the containers never stop. That ordering is the point. A `restic restore
  --dry-run` precheck resolves snapshot *metadata* only — it passes a repository
  whose data packs are missing or corrupt — so anything that wipes before the real
  read can destroy live data on a repo that looked sound. The units are quiesced
  only for the swap, which is a local rename (restic has already restored
  ownership, mode and SELinux label), and are restarted only if the swap
  completed: one that fails part-way deliberately leaves them down and keeps the
  scratch copy rather than serving half-restored data. Peak disk use is roughly
  double the restored set for the duration.

  The volume sets are compared both ways, once the scratch copy is in hand and
  before anything live is touched. A volume the host has and the snapshot does
  not is left alone rather than emptied; one the snapshot has and the host does
  not is the direction that loses data — nothing here creates a volume, so it
  would be restored nowhere — and it is named, in a block above the confirmation,
  and skipped. The confirmation sits at that point rather than before the read,
  so it can report what will actually be swapped, `n` of this host's `m`, plus
  the skip count: from a terminal it wipes nothing without a `y`, and with no
  terminal to name an absent volume to, it stops there instead of swapping the
  rest and exiting 0. A `y` is then never spent on a repository that turns out to
  be unreadable, at the cost of a session dropped at the prompt discarding the
  scratch copy — run it under `tmux`.

## Alerting

An `ExecStopPost` hook writes the run's outcome to
`restic_backup_textfile_dir/<name>-backup.prom` — `<name>_backup_success` (1/0,
from systemd's `$SERVICE_RESULT`) and `<name>_backup_last_run_timestamp_seconds`.
node_exporter scrapes that file (its `node_exporter_textfile_directory` must
match), and the `prometheus` role turns a failed or missed run into an
Alertmanager notification (`PodmanBackupFailed`/`Overdue`,
`HomeBackupFailed`/`Overdue`). A failed `restic check` trips the same metric, so a
`*BackupFailed` that persists while fresh snapshots still land points at
repository corruption rather than a failed run — inspect
`journalctl -u <name>-backup` and recover per
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).
