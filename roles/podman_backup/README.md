# podman_backup

Weekly restic backup of this host's podman volumes to
`<podman_backup_root>/<hostname>-podman-backup` (default root `/nfs/astropath`,
the astropath NFS share). A systemd timer (Wednesday 01:00, persistent — clear of
every other scheduled job) quiesces the quadlet container units, snapshots every
volume with restic, prunes to `podman_backup_keep_weekly` / `_keep_monthly`,
restarts the units (via a trap, so they return even if the backup fails), then
runs `restic check` to verify repository integrity — a failed check fails the
service, so the `PodmanBackupFailed` alert catches silent structural corruption
that the snapshot and prune steps leave unverified, instead of it surfacing only
at restore. The check runs after the restart, so it adds no container downtime.
By default it also re-hashes the data packs, catching bit-rot the metadata check
cannot: each run reads one deterministic `1/N` slice (restic's `n/t` subset),
rotating by ISO week so the whole repo is re-read roughly every
`podman_backup_check_read_data_weeks` runs (default 10). The `n/t` slice is stable
across the retry below, so a real fault fails every attempt and pages rather than
being dodged by a re-drawn random subset. Set the var empty (or 0) to revert to a
metadata-only check that spares the flaky NFS mount any data re-read. Each restic
call is retried: the NFS mount intermittently serves a spurious ENOENT mid-run
that would otherwise fail an isolated operation.

The repo is unencrypted (`--insecure-no-password`): the NAS share is trusted.
Assumes `podman` is installed and the `nfs` role has mounted the target.

The on-NAS repos are replicated off-site out of band by a Synology Hyper Backup
task that copies the `*-podman-backup` folders to a storage box weekly (Wednesday
02:00), encrypted in transit but stored unencrypted — the box, like the NAS
share, is trusted with the repo contents. That job is NAS-side, not managed by
this role — see [`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).

## Restore

The role also installs `podman-restore.sh` (`podman_backup_restore_script`), the
inverse of the backup, for disaster recovery. Run it on a host **after its play
has converged** (so the volumes exist and are registered): it quiesces the
quadlet units, empties each volume, restores the latest snapshot over them
(restic preserves ownership and mode, so no chowns), and restarts the units. It
aborts before touching anything if the repo holds no snapshot, and confirms
before wiping when run from a terminal. The full per-host recovery sequence is in
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).

## Alerting

An `ExecStopPost` hook writes the run's outcome to
`podman_backup_textfile_dir/podman-backup.prom` — `podman_backup_success` (1/0,
from systemd's `$SERVICE_RESULT`) and `podman_backup_last_run_timestamp_seconds`.
node_exporter scrapes that file (its `node_exporter_textfile_directory` must
match), and the `prometheus` role's `PodmanBackupFailed` / `PodmanBackupOverdue`
rules turn a failed or missed run into an Alertmanager notification.

A failed `restic check` trips the same metric, so a `PodmanBackupFailed` that
persists while fresh snapshots still land points at repository corruption rather
than a failed run — inspect `journalctl -u podman-backup` and recover per
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).
