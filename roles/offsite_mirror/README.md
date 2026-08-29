# offsite_mirror

What the off-site mirror actually covers, and when each task last ran, as
node_exporter textfile metrics — the signal a Hyper Backup task notification
cannot give. A task that stops copying a folder still finishes, still reports
success and still mails nothing: `rogue-trader-home-backup` was out of the
`home-backup` task for five weeks and every run in that window was green.

Daily (`offsite-mirror.timer` → `offsite-mirror.sh`), one SSH connection reads
the manifest DSM caches beside each Hyper Backup task
(`/volume1/@tmp/synobackup_cache/*/synobkpinfo.db`, a world-readable key/value
SQLite table, opened `mode=ro`) and publishes:

- `offsite_mirror_task_expected{task,folder}` — the declared coverage, from
  `offsite_mirror_tasks`. Published whatever the NAS says, so the coverage rule
  has a left-hand side even for a task the NAS knows nothing about.
- `offsite_mirror_task_covered{task,folder}` — one series per `bkpFolder` the
  manifest of the task's most recent run names. The comparison against the family
  above is `OffsiteMirrorCoverageMissing`.
- `offsite_mirror_task_status{task}` — 1 iff `bkpStatus` reads `success`.
  Published for every task the cache names, declared or not: what is failing is a
  property of the NAS, and gating it on the declaration would let a task dropped
  from the play stop being watched. Coverage is the other way round.
- `offsite_mirror_task_last_success_timestamp_seconds{task}` — `lastBkpTime`,
  written only for a successful run, so the gauge cannot advance on a failure.
- `offsite_mirror_task_duration_seconds{task}` — `lastBkpTotalTime`.

An `ExecStopPost` hook writes `offsite_mirror_success` /
`offsite_mirror_last_run_timestamp_seconds` to a separate
`offsite-mirror-run.prom`. A probe that cannot reach the NAS dies before it
writes anything, so the previous payload stands untouched and the outcome file
alone carries the failure — the rules keep evaluating known-old data while
`OffsiteMirrorProbeFailed` says how old it is.

`offsite_mirror_textfile_dir` must match the `node_exporter` role's
`node_exporter_textfile_directory`, or both files fall outside the collector's
glob and every rule matches an empty vector; `ScheduledJobMetricMissing` is what
catches that. `offsite_mirror_oncalendar` sets the cadence the alert windows are
sized against.

## The operator step this role cannot do

The NAS is not in the inventory and nothing in this repo may configure it, so
installing the probe's public key is a manual step. Until it is done every run
fails, and the only signals are `ScheduledJobMetricMissing` (from the first
hour, until a run writes the outcome metric) and then `OffsiteMirrorProbeFailed`.

On `auspex`, after the first apply:

```console
sudo cat /etc/offsite-mirror/id_ed25519.pub
```

In DSM, add that line to the `jonny` account's `~/.ssh/authorized_keys` on the
NAS, with `~/.ssh` at `0700` and `authorized_keys` at `0600` — DSM's sshd
refuses a looser mode silently. The account needs nothing else: the manifest
cache and its directories are world-readable, so the probe needs no sudo, no
share access and no shell beyond running one `sh -s`.

Verify from `auspex`:

```console
sudo systemctl start offsite-mirror.service
sudo grep offsite_mirror_success /var/lib/node_exporter/textfile_collector/offsite-mirror-run.prom
```

`1` means the read worked; the payload beside it then names every task and
folder.

`StrictHostKeyChecking=accept-new` against a role-owned `known_hosts`, so the
first connection pins the NAS's key and a later change is refused rather than
followed. Re-pin by deleting `/etc/offsite-mirror/known_hosts`; the role
recreates it empty and the next run fills it.

## Why the manifest and not the task list

DSM exposes the task's configured folder set only through the Hyper Backup UI and
its authenticated web API, which would put a DSM credential on `auspex`. The
manifest is what the last *run* actually copied, which is the stronger claim
anyway: a folder added to the task but failing to copy shows in the configuration
and not here.

The trap is that DSM keys a cache directory on the backup target, so a changed
target leaves the previous set behind — six directories for three tasks on this
NAS, half of them months stale. Taking any matching directory reads one of those
and reports false freshness. The probe reads every directory and keeps, per task,
the manifest with the greatest `lastBkpTime` — a property of the backup rather
than of the file, so a DSM restart or a restore that touched a stale directory
could not promote it into a current coverage claim. A manifest with no usable
`lastBkpTime` sorts last. The task name comes out of the manifest rather than off
the directory, whose suffix is frozen at task creation and need not match it
(`photos-backup`'s directory still ends `photos-backups`).

Neither the storage box account name nor the endpoint appears in this repo. Both
are in those directory names and in the manifest's `bkpAuthUser`, which is read
into a shell variable and never copied into a metric; the role's molecule
scenario asserts it does not reach the payload.

## Variables

`defaults/main.yml`: `offsite_mirror_nas_user`, `offsite_mirror_nas_host`,
`offsite_mirror_tasks`, `offsite_mirror_ssh_key`,
`offsite_mirror_known_hosts`, `offsite_mirror_textfile_dir`,
`offsite_mirror_oncalendar`, `offsite_mirror_script`,
`offsite_mirror_metric_script`. `vars/main.yml` holds DSM's own paths.

`offsite_mirror_tasks` is empty by default and rejected at converge. It is the
set the coverage alert measures the manifest against, so it belongs in the play
beside the hosts whose repos it names — keep it in step with the DSM tasks and
with `docs/backups.md`.

## Alerts

The `prometheus` role's `backups` group: `OffsiteMirrorCoverageMissing` (a
declared repo absent from a manifest that was read),
`OffsiteMirrorTaskUnverified` (no manifest for a declared task — its `absent()`
companion), `OffsiteMirrorTaskFailed`, `OffsiteMirrorTaskOverdue`, and the
`OffsiteMirrorProbeFailed` / `OffsiteMirrorProbeOverdue` pair for the probe
itself.

Wired onto `auspex` alone: it is where Prometheus and node_exporter already are,
and the NAS runs no exporter of its own, so every series above carries auspex's
instance label and the NAS task's name.
