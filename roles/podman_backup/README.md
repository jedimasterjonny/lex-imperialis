# podman_backup

Weekly restic backup of this host's podman named volumes to
`<hostname>-podman-backup` on the astropath NFS share (`/nfs/astropath`). A thin
consumer of the [`restic_backup`](../restic_backup/README.md) engine in
podman-volumes mode: it sets the engine vars and includes it. The
timer (Wednesday 01:00, persistent — clear of every other scheduled job)
quiesces the quadlet container units, snapshots every volume, restarts the
units, then runs a verifying `restic check`; the engine README covers the
snapshot, prune, integrity-check, retry, and metric mechanics.

Assumes `podman` is installed and the `nfs` role has mounted the target. Runs on
`solar` and `rogue-trader`; `scholam`'s only podman workload (`node_exporter`) is
stateless, so it carries no podman repo.

## Restore

Podman-volumes mode installs `/usr/local/sbin/podman-restore.sh`, the inverse of
the backup, for disaster recovery. Run it on a host **after its play has
converged** — mechanics are in the engine README. The full per-host
recovery sequence is in
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).

## Variables

`podman_backup_oncalendar` sets the timer; retention, the check cadence, the
astropath root, and the textfile dir inherit the engine defaults. The
`podman_backup_success` / `podman_backup_last_run_timestamp_seconds` metrics feed
the `prometheus` role's `PodmanBackupFailed` / `PodmanBackupOverdue` rules; see
[`docs/backups.md`](../../docs/backups.md) for the full backup architecture.
