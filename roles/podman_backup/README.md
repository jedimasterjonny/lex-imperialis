# podman_backup

Weekly restic backup of this host's podman volumes to
`<podman_backup_root>/<hostname>-podman-backup` (default root `/nfs/astropath`,
the astropath NFS share). A systemd timer (Wednesday 01:00, persistent — clear of
every other scheduled job) quiesces the quadlet container units, snapshots every
volume with restic, restarts the units (via a trap, so they return even if the
backup fails), then prunes to `podman_backup_keep_weekly` / `_keep_monthly`.

The repo is unencrypted (`--insecure-no-password`): the NAS share is trusted.
Assumes `podman` is installed and the `nfs` role has mounted the target.

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
