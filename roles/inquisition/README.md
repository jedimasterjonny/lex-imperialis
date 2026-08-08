# inquisition

Watches for drift between a host's containers and its quadlet declarations —
`arbites` proves `main` was applied; this proves the host still matches it.
Named for the obvious reason: it hunts deviation from the Lex.

The quadlet files under `inquisition_quadlet_dir` ARE the declaration, so every
check is answerable on-host with no fleet-side list to keep in step. Hourly
(`inquisition.timer` → `inquisition.sh`), four classes:

- **digest** — a running container whose image digest differs from its quadlet's
  `@sha256:` pin: the restart-that-never-fired class, invisible to any render
  gate because it renders no bytes. `podman inspect '{{.ImageDigest}}'` equals
  the renovate pin byte-for-byte (measured on the live fleet, 2026-08-08).
- **unmanaged** — a container, running or stopped, that no quadlet declares.
  Automates the hand-run unmanaged audit. `inquisition_ignore_containers` is
  the escape hatch, empty by design.
- **inactive** — a declared quadlet whose service is not `active`: the
  omission-on-addition class. `SystemdUnitFailed` sees only *failed*;
  never-started is invisible to it.
- **unpinned** — a quadlet whose `Image=` carries no digest, guarding the pin
  discipline itself. An unpinned, stopped quadlet is two findings and both
  fire.

Metrics go through the node_exporter textfile collector:
`inquisition_offender{class,container}` per offender,
`inquisition_offenders{class}` always present (0 is the healthy state, so
"clean" and "not checked" stay distinguishable), and
`inquisition_containers_checked`. An `ExecStopPost` hook writes
`inquisition_success` / `inquisition_last_run_timestamp_seconds` to a separate
`inquisition-run.prom` — a crash mid-check records its failure without zeroing
offenders it never measured.

The `prometheus` role's `drift` group alerts: `ContainerDigestDrift` (6h — a
correct apply clears digest drift within minutes, so anything standing is the
handler class), `UnmanagedContainerRunning` / `QuadletNotRunning` /
`QuadletUnpinned` (2h — two consecutive bad runs on the hourly cadence, so a
transient mid-update wobble never fires), and the `InquisitionFailed` /
`InquisitionOverdue` pair.

Wired onto the podman-quadlet hosts (`solar`, `rogue-trader`) after the
`podman` role (owns the quadlet dir). scholam runs no quadlets and its podman
use is interactive dev work — an unmanaged check there would flag normal
behaviour; administratum has neither systemd nor node_exporter.
