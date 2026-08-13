# podman

Container runtime for the quadlet roles: podman plus aardvark-dns — only
recommended by zypper, but required for containers on a podman network to
resolve one another — and `/etc/containers/systemd`, where backend roles
drop their units.

Installs through `ansible.builtin.package`, so it serves `auspex` on Raspberry Pi
OS as well as the openSUSE hosts; the three package names are the same under
both. The role creates `/etc/containers/containers.conf.d` rather than assuming
it: libcontainers-common supplies it on openSUSE, while neither Debian's `podman`
nor its `golang-github-containers-common` ships or creates it.
`/etc/containers/systemd`, `netavark-firewalld-reload.service` and quadlet itself
are all present on Debian unchanged.

## Container store on a device

`podman_storage_device` mounts a block device at `/var/lib/containers`, ahead of
the install so the store is created on the device rather than shadowed by it.
Images and every named volume follow from the one fstab entry. Empty by default,
so the role is unchanged on the hosts that keep their store on root; only
`auspex` sets it, to `LABEL=containers` — its NVMe, since podman's store there
holds a continuously-written Prometheus write-ahead log and an SD card is the
wrong medium for that.

`nofail` is deliberate: a monitoring host that will not boot without its data
disk is worse than one that boots degraded. The cost is that the failure is
silent — podman writes to the root filesystem under the empty mount point and
everything appears to work. `findmnt /var/lib/containers` is what says otherwise,
and until something on this host is worth alerting about, it is the only thing
that does.

**Adopting a device on a host that already has a store is not a converge.** The
task mounts before the install so a *fresh* host builds its store on the device,
but a host that has been running podman already has one, and mounting a blank
filesystem over it hides the lot: every image, and every named volume with it.
Nothing breaks loudly — podman simply reports an empty store, re-pulls each
image, and the old one sits orphaned underneath the mount point still consuming
the disk it was moved off.

**Pause `arbites` for the whole procedure** — `touch /var/lib/arbites/pause` on
scholam. The apply below is not really an apply: merging is what schedules it,
and the root timer picks up `main` within 15 minutes whether or not the seeding
has finished. A reconcile landing mid-copy shadows the store it was meant to
move, and one landing during the reclaim — units stopped, device unmounted, `rm`
in flight — remounts the device underneath the delete, which is unrecoverable.

The filesystem and its label are made by hand, not by this role; the play var
only names the result:

```bash
mkfs.ext4 -L containers /dev/<partition>
```

Then seed the device, with podman idle:

```bash
systemctl stop <every quadlet unit on the host>
mount /dev/disk/by-label/containers /mnt
rsync -aHAX /var/lib/containers/ /mnt/
umount /mnt
```

then apply, confirm `findmnt /var/lib/containers` names the new device and
`podman images` is intact, and only then reclaim the shadowed copy: stop the
units again and `umount /var/lib/containers`.

**Check `findmnt /var/lib/containers` returns nothing before deleting anything.**
A unit that did not actually stop holds the store and the umount fails `EBUSY` —
at which point the delete lands on the live NVMe copy rather than the shadowed
one. Once it is confirmed unmounted, delete what is revealed underneath,
`mount -a`, start the units, and remove the `arbites` pause.

The mount arm is unexercised in CI: an incus container cannot be given a block
device. Molecule asserts the guard instead — that the empty default leaves fstab
alone, so nothing here can write a mount onto the three other hosts that run this
role and have no such device.

## OCI runtime

`podman_runtime` is written to `/etc/containers/containers.conf.d/10-runtime.conf`
and installed as the package of the same name. It is crun fleet-wide, since
Tumbleweed and the Tumbleweed-based MicroOS both package it and crun is lighter
than runc on the exec path — the path every container healthcheck takes. runc is
never removed: podman hard-requires it. The `10-` prefix is load-bearing — it has
to outrank libcontainers-common's `00-suse-containers.conf`, which pins runc.
Belt and braces on Debian, whose `podman` `Depends: crun | runc` and so already
reports `runtime=crun` before the drop-in lands.

**On MicroOS the image must ship crun before this role first runs.** A package
installs into a new snapshot, so a host whose image lacks crun stays on the old
root without it while the drop-in already names crun — every container then fails
to start until the next reboot. `packer/stage2-provision.yml` reads
`podman_packages` from this role, so rebuilding the image bakes crun in; rebuild
first, then converge.

A container records its runtime at creation, so writing the file moves nothing
that is already running. Each container adopts it whenever its unit next restarts,
since quadlet's `ExecStart` is `podman run --replace --rm`. The role does not force
that: it would fire on whichever unattended `arbites` tick first saw the
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

A weekly timer (Saturday 06:00, persistent) runs
`/usr/local/sbin/podman-image-prune.sh`, so superseded quadlet image pulls don't
accumulate. The script prunes root's store, then every passwd user holding a
store under `~/.local/share/containers` — an operator's ad-hoc `podman run`
otherwise accumulates images nothing reclaims. Users are enumerated at run time,
so one who takes up rootless podman between converges is covered.

Every prune goes through `systemd-run`, a rootless one adding `--uid` and
`PAMName=login`. The PAM session is not optional: podman pins a store to the
`/run/user/$uid` runroot recorded when it was created and refuses to open it
under any other, and that directory exists only while its user holds a session
or lingers. `--collect` is likewise required rather than tidy — without it a
failed transient unit stays loaded and trips `SystemdUnitFailed` under an opaque
`run-uNNNN` name.

A store its owner has left unusable never stops the others being pruned: the run
logs it, carries on, and exits non-zero at the end. `SystemdUnitFailed` does not
exclude this unit, so that raises a warning without a bespoke metric or rule.

Molecule proves the rootful prune and that enumeration finds a store created
after converge. It asserts nothing about the rootless prune's outcome: whether a
container can run rootless podman at all varies by host, so that is green on one
runner and a reported skip on another. Reclaim from a rootless store is proven
against a real host instead.
