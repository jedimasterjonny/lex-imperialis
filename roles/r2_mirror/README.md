# r2_mirror

Publishes what the Cloudflare R2 off-site copy actually holds, as node_exporter
textfile metrics on `auspex`.

`offsite_mirror` cannot cover this destination. DSM caches a manifest for an S3
Hyper Backup target as it does for an rsync one, but a different and much thinner
record: `dataUnique`, `bkpAuthUser`, `bkpVersion`, `bkpType`, `formatType`,
`dataEnc`, `dataComp`, `enableXattr` — and none of `bkpTaskName`, `bkpStatus`,
`lastBkpTime` or `bkpFolder`. Every `OffsiteMirror*` task rule reads one of those
four, so all of them are structurally inert for the R2 tasks, and declaring the
tasks there would only raise `OffsiteMirrorTaskUnverified` forever. This role
reads the bucket instead — the destination itself rather than the NAS's account
of it, which also covers what DSM never could: the bucket gone, the credential
revoked, or an interrupted upload leaving billable parts behind.

## What it deploys

A `r2-mirror.timer` firing `r2-mirror.service` daily, running
`/usr/local/sbin/r2-mirror.py`, which lists the bucket and writes
`r2-mirror.prom` into the textfile collector directory. The unit's
`ExecStopPost` is node_exporter's shared run-metric script, which records the
run's own outcome as `r2_mirror_success` and
`r2_mirror_last_run_timestamp_seconds`.

The probe fails closed: any error and it writes nothing, exits non-zero, and
leaves the previous payload standing. `R2MirrorProbeFailed` is what says so — a
half-written payload would instead look like a bucket that had lost objects.

## Python, not bash

The repo's other scripts are bash; this one is not. The probe signs AWS SigV4
requests, whose HMAC chain in bash means marshalling binary keys through
`openssl dgst -macopt hexkey:` at every step, and whose canonical query string
must be sorted and percent-encoded — an unsorted one signs a different string
from the one R2 reconstructs and returns `403 AccessDenied`, indistinguishable
from a permissions fault. The stdlib does all of it in a dozen readable lines.
The cost is that `bin/shellcheck-jinja.sh` does not lint this template.

## Variables

- `r2_mirror_bucket` — defaults to `reclusiam`.
- `r2_mirror_endpoint` — the account endpoint. The account id in that URL is no
  more secret than the zone ids in terraform.
- `r2_mirror_containers` — the declared set, `{name, prefix}` per Hyper Backup
  task, and what `R2MirrorContainerMissing` measures the bucket against, so it
  belongs in the play. Empty is rejected by an assert; an entry missing either
  key fails when the probe template renders, which is the same apply. `name`
  becomes the `container` label on every metric.
- `r2_mirror_access_key_id` / `r2_mirror_secret_access_key` — rendered to a 0600
  `EnvironmentFile` under `no_log`.
- `r2_mirror_textfile_dir` — must match the `node_exporter` role's
  `node_exporter_textfile_directory`, or both files fall outside the collector's
  glob and every rule matches an empty vector.
- `r2_mirror_oncalendar` — daily at 11:47, half an hour off `offsite_mirror`'s
  slot and hours clear of the 06:00 UTC uploads.
- `r2_mirror_env_file`, `r2_mirror_script`, `r2_mirror_metric_script` — install
  paths for the credential file and the two scripts.

## The credential is deliberately not the backup one

The Hyper Backup tasks authenticate with an Admin Read & Write R2 token, because
Hyper Backup's target wizard needs `ListBuckets` to populate its dropdown. That
token can delete every object it can see. This probe only lists, so it takes a
separate read-only token, and the write one never lands on a host — a compromised
`auspex` must not be able to destroy the last-resort copy it is watching.
Rotation is in [`docs/secret-rotation.md`](../../docs/secret-rotation.md).

That split forecloses the obvious remediation for `R2MirrorStrandedParts`: this
token cannot `AbortMultipartUpload`, and the write pair lives in the Hyper Backup
task configuration alone. Clear a stranded upload by minting a temporary Object
Read & Write token on the bucket, listing with `aws s3api list-multipart-uploads`
and clearing each with `abort-multipart-upload` against the R2 `--endpoint-url`,
then deleting the token. A bucket lifecycle rule aborting incomplete uploads
would make this self-healing and is the better fix; none is configured, and one
belongs in terraform.

## Metrics

Per container, labelled `container`:

- `r2_mirror_container_expected` — declared in the play, published whatever the
  bucket holds, so a declaration with nothing behind it is visible as such.
- `r2_mirror_container_bytes`, `r2_mirror_container_objects`. An empty declared
  container is `bytes 0`, which is what `R2MirrorContainerMissing` reads — bytes
  rather than objects, because a zero-byte folder marker is an object.
- `r2_mirror_container_last_write_timestamp_seconds` — the newest object, the
  freshness proxy `R2MirrorContainerStale` reads. Written only for a container
  that holds something: an empty one has no last write, and publishing 0 would
  age instantly into an alert saying the wrong thing.
- `r2_mirror_multipart_pending` — uploads started and never completed.

A container the bucket holds but the play does not declare is reported too, the
way `offsite_mirror` publishes a status for every task the manifest names:
storage nobody declared is exactly what a declaration cannot tell you about.

## Verify after the first apply

The scenario's stub does not check signatures — making it do so would only test
the signer against a verifier written alongside it — so one real request is the
only proof the SigV4 path and the token's scope are right. From `auspex`:

```console
sudo systemctl start r2-mirror.service
sudo grep r2_mirror_success /var/lib/node_exporter/textfile_collector/r2-mirror-run.prom
```

`1` means the listing worked; the payload beside it then names every container.
Without this check a mis-scoped token or a signing fault surfaces 25h later as
`R2MirrorProbeFailed`.

## What it cannot see

Three gaps, none of them cheaply closed from the bucket:

- **Which repos are inside a container.** `home-backup-r2` holds three, and the
  bucket cannot say which — so the regression `offsite_mirror` exists for, a repo
  silently dropped from a task, is unwatched here. The task's own DSM
  notification is what would report it.
- **`last_write` means an object arrived, not that the run succeeded.** Hyper
  Backup rewrites its control objects, so a partial run still moves the
  timestamp. The weekly integrity check is what proves the copy is readable.
- **Whether those integrity checks run or pass.** They are the only thing that
  reads the copy back, and nothing watches them: DSM's notification mail is the
  sole signal, with the limits [`docs/backups.md`](../../docs/backups.md) sets
  out under "What a task notification cannot see".

## Scenario

`default` (incus, Debian — `auspex` is the only host this runs on). No bucket is
reachable from a container, so the scenario serves canned S3 XML from a local
stub and points `r2_mirror_endpoint` at it. The fixture covers a listing that
spans a continuation-token page, a container with a stranded upload, a declared
container the bucket does not hold, and a prefix nobody declared; a second run
with the stub down asserts the probe fails closed and leaves the payload alone.
