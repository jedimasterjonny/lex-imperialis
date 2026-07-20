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

The repo lives at `<restic_backup_root>/<hostname>-<restic_backup_name>-backup`,
unencrypted (`--insecure-no-password`): the NAS share is trusted. Assumes the
`nfs` role has mounted the target; podman-volumes mode also assumes `podman`.

Consumers `include_role` this engine and set the vars — `podman_backup` and
`home_backup` are the two. The on-NAS repos are mirrored off-site out of band by
a NAS-side Synology Hyper Backup task. See [`docs/backups.md`](../../docs/backups.md)
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
`restic_backup_check_read_data_weeks`, `restic_backup_package`.

## Modes

- **Path backup** (default) — snapshots the absolute paths in
  `restic_backup_paths`. No quiescing: the snapshot is crash-consistent.
- **Podman-volumes** (`restic_backup_podman_volumes: true`) — the sources are the
  host's podman volume mountpoints, enumerated at run time; the quadlet container
  units are quiesced for a consistent snapshot and always restarted (a trap, so
  they return even if the backup fails). This mode also installs `<name>-restore.sh`,
  the inverse of the backup for disaster recovery: run it on a host **after its
  play has converged** — it quiesces the units, empties each volume, restores the
  latest snapshot over them (restic preserves ownership and mode), and restarts
  the units. It aborts before touching anything if the repo holds no snapshot, and
  confirms before wiping when run from a terminal. A path backup restores by hand
  with `restic restore`.

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
