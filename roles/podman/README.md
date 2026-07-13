# podman

Container runtime for the quadlet roles: podman plus aardvark-dns — only
recommended by zypper, but required for containers on a podman network to
resolve one another — and `/etc/containers/systemd`, where backend roles
drop their units.

## OCI runtime

`podman_runtime` is written to `/etc/containers/containers.conf.d/10-runtime.conf`
and installed as the package of the same name. It is crun on Tumbleweed — the
lighter of the two on the exec path, which is the path every container healthcheck
takes — and runc anywhere else. Distro-derived rather than set per host, so a role
composing podman need not override it on its Leap scenario. runc is never removed
either way: podman hard-requires it. The `10-` prefix is load-bearing — it has to
outrank libcontainers-common's `00-suse-containers.conf`, which pins runc.

Only the Tumbleweed hosts move: on Leap the drop-in writes the runc podman was
already using, so it is a no-op there.

A container records its runtime at creation, so writing the file moves nothing
that is already running. Each container adopts it whenever its unit next restarts,
since quadlet's `ExecStart` is `podman run --replace --rm`. The role does not force
that: it would fire on whichever unattended `gitops_reconcile` tick first saw the
change, and plex and beets are not safe to kill mid-transcode or mid-import. Left
alone, solar turns over at whichever comes first of the weekly `autoupdate` reboot
and `podman_backup`'s quiesce; scholam runs no backup, so its reboot is the only
one. To land it sooner, restart the units by hand.

Reverting the commit is *not* a rollback: it deletes the task, not the file, so the
drop-in stays and containers keep coming back on crun. To go back, delete
`10-runtime.conf` — which uncovers the SUSE drop-in's runc again — and recreate the
containers.

`podman info` reports the *configured* runtime, so it reads `crun` the moment the
file lands, whatever the running containers are still on. The per-container truth
is `podman inspect --format '{{ .OCIRuntime }}' <name>`.

The netavark firewalld-reload listener is enabled, so a firewalld reload
reapplies netavark's rules instead of dropping published ports and
inter-container networking.

NetworkManager is told to leave podman's bridges (`podman*`) unmanaged via
`conf.d/podman.conf`, so tearing down the last container bridge doesn't fire an NM
event that unmounts the `_netdev` NFS shares — which otherwise breaks the
`podman_backup` run and the arr-stack restart. Skipped where NM is absent.

A weekly timer (Saturday 06:00, persistent) prunes unused images, so
superseded quadlet image pulls don't accumulate.
