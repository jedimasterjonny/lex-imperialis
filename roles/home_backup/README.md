# home_backup

Weekly restic backup of the host's home directories (`/home` by default) to
`<hostname>-home-backup` on the astropath NFS share (`/nfs/astropath`). A thin
consumer of the [`restic_backup`](../restic_backup/README.md) engine in generic
(path) mode: it sets the engine vars and includes it. The
timer (persistent — a day clear of the podman backup and its off-site mirror;
`solar` Thursday 01:00, `scholam` staggered to 02:00 so the two hosts don't hit
the astropath export at once) snapshots the paths and runs a verifying
`restic check`; the engine README covers the snapshot, prune, integrity-check,
retry, and metric mechanics.

No quiescing: home directories are backed up live, so the snapshot is
crash-consistent (a file mid-write may be captured partial). Runs on `solar` and
`scholam`. Assumes the `nfs` role has mounted the target — on `scholam` that
means adding the astropath share, which the NAS must also export to it.

## Restore

Generic mode installs no restore script (that is podman-volumes only, where the
restore must quiesce quadlets and wipe volumes). Restore a home tree by hand:

```bash
restic --insecure-no-password --repo /nfs/astropath/<hostname>-home-backup \
  restore latest --target /
```

Restore to a scratch `--target` and copy across when the live homes must not be
overwritten wholesale. The full recovery context is in
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).

## Variables

`home_backup_paths` sets what to snapshot, `home_backup_excludes` the
re-acquirable churn to skip (caches, virtualenvs, `node_modules`), and
`home_backup_oncalendar` the timer; retention, the check cadence, the astropath
root, and the textfile dir inherit the engine defaults. The `home_backup_success` /
`home_backup_last_run_timestamp_seconds` metrics feed the `prometheus` role's
`HomeBackupFailed` / `HomeBackupOverdue` rules; see
[`docs/backups.md`](../../docs/backups.md) for the full backup architecture.
