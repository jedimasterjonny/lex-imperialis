# storagebox_gateway

A socket-activated TCP forward to the Hetzner storage box, run by
`systemd-socket-proxyd` and installing no package. It exists so the box can
refuse every source outside Hetzner: with the forward in place, the NAS's Hyper
Backup tasks reach the box through a host that is already inside Hetzner, and the
box's External Reachability can be turned off.

The gate is at Hetzner's network, not this host — every Hetzner customer is
inside it. It removes internet-wide scanning from the box's threat surface and
nothing else; the box's real protection is still its SSH credentials.

Variables in `defaults/main.yml`: `storagebox_gateway_listen`,
`storagebox_gateway_target`. `vars/main.yml` holds the proxy's path.

## What it does not carry

The proxy is transparent at the TCP layer, so the client's SSH session runs end
to end and this host never holds the box's credentials. That is the property that
makes it safe to co-locate on a host that also serves something public: a
compromise of the gateway yields ciphertext, not a way into the off-site copy.

`storagebox_gateway_target` is a vault var for the same reason it is not a
default here — the endpoint embeds the storage box account name, so committing it
would name the box to be brute-forced.

## Why not a firewalld forward-port

A `forward-port` rich rule with `to-addr=` needs no role, no units and no
scenario, and `firewalld` already runs here. It loses on both counts that matter:
`to-addr=` takes a literal IP, pinning the one thing resolving a name avoids and
putting that address in a public repo, and it moves DNAT and masquerade onto the
firewall of a host that faces the internet. A userspace proxy bound to a single
address does neither.

## Monitoring

`ProbeDown`, via the `tcp_ssh_banner` blackbox module auspex probes this listener
with — see that module's comment for why a bare `tcp_connect` would assert
nothing here.

It covers the path, not authorisation, and the distinction is sharper than it
sounds. Hetzner enforces External Reachability inside sshd rather than at the
packet layer: a source the box refuses still completes the handshake, reads the
banner and retrieves the host key, and is only then offered an empty
authentication method list. So a revoked `rogue-trader` would leave this probe
green while every mirror failed. The signal is a Hyper Backup failure mail, or
the `offsite_mirror` probe on auspex, which reads each task's cached manifest
daily — `OffsiteMirrorTaskFailed` if DSM records the refusal there, and otherwise
`OffsiteMirrorTaskOverdue` once the last success ages past a week.

A box whose address changes behind the same name needs no intervention: the proxy
resolves its upstream per accepted connection, so the next connection follows
within DNS TTL.

## Disaster recovery

With External Reachability off, the box is reachable only from inside Hetzner, so
this host becomes a single point of failure for the off-site copy of every host:
losing it alone stops all three Hyper Backup mirrors, and it is on the restore
path as well as the backup path. The routes back are in
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).

## SELinux

`systemd-socket-proxyd` runs in a confined domain, and systemd labels a socket
unit's listening fd with the domain its `ExecStart` would transition into. That
domain's `name_bind`/`name_connect` rules over `port_type` sit behind
`systemd_socket_proxyd_bind_any` and `systemd_socket_proxyd_connect_any`, both
off by default, and its own `systemd_socket_proxyd_port_t` has no ports assigned
— so untouched it can neither bind 23/tcp (`telnetd_port_t`) nor reach the box.
The role sets both booleans where SELinux is enabled.

It sets them with `setsebool` rather than `ansible.posix.seboolean`, which would
be the idiomatic module: that imports the semanage python binding, and MicroOS
does not ship it. Installing it there would stage into a new snapshot rather than
the running system, so the boolean task would fail against a host that does not
have it yet — the same trap `packer/stage2-provision.yml` bakes its package list
to avoid. `setsebool` comes from `policycoreutils`, already on the host, so the
role still installs nothing.

Relabelling port 23 to `systemd_socket_proxyd_port_t` would be the narrower
grant, but it mutates a well-known port system-wide and needs `semanage`, which
is exactly what is missing; the booleans are scoped to a domain that runs one
service on this host.

## What the container tier cannot test

The scenario reads an SSH banner back through the listener, so the proxy is
exercised end to end — activation, upstream resolution and bidirectional
forwarding. What it cannot cover is the free-bind itself, which needs an address
the host does not hold; the real upstream, which needs the box; and the SELinux
tasks above, which the incus tier skips because it runs unconfined. That denial
would be invisible to the apply and surface only as `ProbeDown`.

The service's `Type=` is a second such gap, and a worse one because the tier does
not merely skip it but disagrees: the Tumbleweed image's
`systemd-socket-proxyd` sends `READY=1` where MicroOS's build does not carry it
at all, so `Type=notify` passes every container assertion and then, on the host,
leaves the unit in `activating` until `TimeoutStartSec` kills the proxy — 90s
into any copy long enough to matter, which a millisecond banner read never is.
