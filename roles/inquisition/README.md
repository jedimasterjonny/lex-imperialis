# inquisition

Watches for drift between a host's containers and its quadlet declarations —
`arbites` proves `main` was applied; this proves the host still matches it.
Named for the Inquisition: it hunts deviation from the Lex.

The quadlet files under `inquisition_quadlet_dir` ARE the declaration, so every
check is answerable on-host with no fleet-side list to keep in step. Hourly
(`inquisition.timer` → `inquisition.sh`), four classes:

- **digest** — a running container whose image digest differs from its quadlet's
  `@sha256:` pin: the restart-that-never-fired class, invisible to any render
  gate because it renders no bytes. The pin is matched against both
  `.ImageDigest` and the digest in `.ImageName`, either of which satisfies it:
  podman resolves a multi-arch pull to the per-arch manifest, so `.ImageDigest`
  is not the manifest-list digest renovate pins — it diverges for 1 of the
  fleet's 21 containers, while `.ImageName` holds the pinned digest for all 21.
- **unmanaged** — a container, running or stopped, that no quadlet declares.
  Automates the hand-run unmanaged audit.
- **inactive** — a declared quadlet whose service is not `active`: the
  omission-on-addition class. `SystemdUnitFailed` sees only *failed*;
  never-started is invisible to it.
- **unpinned** — a quadlet whose `Image=` carries no digest, guarding the pin
  discipline itself. An unpinned, stopped quadlet is two findings and both fire.

Only two properties are compared per declaration: the unit's `ActiveState` and
the running digest. A quadlet whose other fields changed without a restart reads
clean, as do the `.network` units, which mint no container. Units outside the
top-level `*.container` glob are the opposite of a blind spot — quadlet recurses
into subdirectories and honours drop-ins, so a container declared either way is
undeclared here and reads `unmanaged`, and a drop-in overriding `Image=` reads as
digest drift against the base file's pin. The real blind spot is the quadlet
files being ground truth: a `.container` no role templates any more — a role
dropped from a play, or a hand-written unit — reads clean with its container
managed, and catching that needs the fleet-side list this deliberately refuses to
keep.

Metrics go through the node_exporter textfile collector:
`inquisition_offender{class,container}` per offender, absent on a clean host,
and `inquisition_containers_checked` — the denominator that tells clean apart
from a vacuum, which `QuadletsDisappeared` reads. An `ExecStopPost` hook writes
`inquisition_success` / `inquisition_last_run_timestamp_seconds` to a separate
`inquisition-run.prom`, so a crash mid-check records its failure without zeroing
offenders it never measured.

`inquisition_textfile_dir` must match the `node_exporter` role's
`node_exporter_textfile_directory`, or both files fall outside the collector's
glob and every drift rule matches an empty vector — `ScheduledJobMetricMissing`
is what catches that.
`inquisition_oncalendar` sets the cadence every alert window is sized against.

The `prometheus` role's `drift` group alerts: `ContainerDigestDrift` (6h — a
correct apply clears digest drift within minutes, so anything standing is the
handler class), `UnmanagedContainerRunning` / `QuadletNotRunning` /
`QuadletUnpinned` (2h — two consecutive bad runs on the hourly cadence, so a
transient mid-update wobble never fires), `QuadletsDisappeared` (nothing
inspected at all, which absent offender families otherwise render
indistinguishable from clean), and the `InquisitionFailed` (90m) /
`InquisitionOverdue` (2h) pair. The timer omits `Persistent=`, so a host back
from an outage republishes its stale `.prom` before the next `:37` refreshes it —
every window above clears that gap.

Wired onto `solar` and `rogue-trader` after the `podman` role (owns the quadlet
dir). scholam is excluded despite running a quadlet of its own: its podman use is
interactive dev work, which an unmanaged check would flag as drift.
The NAS is not a candidate at all: it is no longer in the inventory, runs no
containers this repo deploys, and carries no node_exporter to publish through.
