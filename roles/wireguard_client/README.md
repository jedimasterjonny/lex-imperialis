# wireguard_client

A WireGuard client tunnel run by NetworkManager's native backend, plus the
endpoint refresh a dynamic-IP peer needs. Replaces `wireguard_reresolve`, which
drove `wg-quick` and needed openresolv and a local SELinux policy module to do it.

The role renders `/etc/NetworkManager/system-connections/<iface>.nmconnection`
(0600) from `wireguard_client_conf`, hands the interface over from `wg-quick` if
it still owns it, then removes what only `wg-quick` needed.

Variables in `defaults/main.yml`: `wireguard_client_packages`,
`wireguard_client_interface`, `wireguard_client_conf`, `wireguard_client_uuid`,
`wireguard_client_mtu`, `wireguard_client_dns_priority`,
`wireguard_client_resolver`, `wireguard_client_stale_seconds`,
`wireguard_client_interval`.

## Input format

`wireguard_client_conf` is a `wg-quick` config, parsed in `vars/main.yml`. Taking
wg-quick's own format is deliberate: the private key keeps one copy in the vault,
and `/etc/wireguard/<iface>.conf` stays valid, so re-enabling `wg-quick@<iface>`
is a working rollback. The role never deletes that file. One `Address` is
supported; `AllowedIPs` and `DNS` may be comma-separated.

A missing `PrivateKey`, `Address`, `PublicKey`, `AllowedIPs` or `Endpoint` fails
the run rather than rendering a profile with a hole in it.

## Refresh

WireGuard resolves the endpoint only when the interface is configured, so a
dynamic-IP gateway reboot strands the tunnel on the stale address.
`wireguard-refresh.timer` runs a oneshot every `wireguard_client_interval`
(`1min`): once the peer's latest handshake is older than
`wireguard_client_stale_seconds` (150) **and** the hostname resolves to an
address other than the one in use, it runs `nmcli connection up <iface>`.

Both halves of that gate matter. `nmcli device reapply` is not a re-resolve — it
pushes the cached sockaddr back to the kernel unchanged, because NetworkManager
short-circuits on the endpoint *string*, not the resolved address; only
activation re-resolves. And activation is not free: it flaps the interface, and
the tunnel carries a hard NFS mount, so it happens only on a moved address rather
than every tick while the peer is unreachable.

A peer that has never handshaked reports `0`, treated as stale — a tunnel brought
up against an address that had already moved never handshakes at all.

The hostname is read from the keyfile (`wg show` reports only the resolved IP)
and resolved against `wireguard_client_resolver` (`1.1.1.1`) rather than the
system resolver, which a downed tunnel may take with it.

## Re-keying

A changed profile reaches the running tunnel only through activation. `nmcli
connection reload` re-reads the keyfile and leaves the live connection as it is,
so the role follows it with an activation when the tunnel is already up —
without which a rotated key sits on disk while the box goes on presenting the
old one, with Ansible reporting changed and nothing detecting the divergence
(the refresh acts only on a stale handshake with a moved endpoint, which a
re-key is neither). Where the tunnel is not up, the reload's autoconnect brings
it up with the new profile already in force, so the activation is skipped.

Activation flaps the interface, so a rotation driven over this tunnel re-keys
the path it is running on, and a key the peer does not yet accept does not come
back. Rotate at the host's public address, in the order `docs/secret-rotation.md`
gives.

## DNS priority

`wireguard_client_dns_priority` (10) beats NetworkManager's default of 100 for
the public interface, so the tunnel's DNS is preferred and the public
interface's stays in `resolv.conf` behind it.

That fallback is load-bearing, not tidiness. Activation is what re-resolves the
peer, and NetworkManager resolves it through the *system* resolver — so a
tunnel-only resolver leaves a dead tunnel unable to name the peer that would
revive it. The refresh script's own `dig` uses a public resolver for the same
reason, but it only decides *whether* to act; NetworkManager still has to resolve
the name itself.

## Handover and rollback

`wg-quick` and NetworkManager cannot both own the interface, so the switch is one
step. If NetworkManager cannot bring the tunnel up, the role re-enables
`wg-quick` immediately: on a public VPS reached only through this tunnel, a
failed handover otherwise strands the host behind a serial console.

The retirement of `wg-quick`'s supporting artefacts — the old re-resolve timer,
the SELinux module, openresolv — is gated on `wg-quick` no longer being active,
so a run whose handover failed leaves the fallback intact.

## MTU

Pinned to 1420 rather than left to NetworkManager's kernel default. `wg-quick`
derives it from the endpoint route (1500 − 80), and the tunnel carries an NFS
mount whose 1 MiB rsize turns a wrong MTU into a stall rather than an error.

## Ordering

Consumers that bind the tunnel address must be ordered after
`NetworkManager-wait-online.service`, which waits for autoconnect profiles to
reach activated state. `wg-quick@<iface>.service` no longer exists, and systemd
treats `After=` on an absent unit as a no-op — so an ordering left pointing at it
fails open, silently.

## What the container tier cannot test

The molecule scenario has no NetworkManager and no `wg0`, so it covers the
rendered profile, the units and the refresh script's guards. Activation, the
handover and the SELinux and openresolv removals are gated on state a container
never reaches; they are exercised on the host. The `libvirt`/`hetzner` tiers the
retired role carried are gone with it: they existed to test `wg-quick` under
enforcing SELinux, and neither the confinement nor the policy module survives.
