# wireguard_reresolve

Keeps a WireGuard tunnel up across a home WAN-IP change. WireGuard resolves
`Endpoint=` only at startup, so a dynamic-IP gateway reboot strands the tunnel on
the stale address. A `wireguard-reresolve.timer` runs a oneshot every
`wireguard_reresolve_interval` (`1min`): once the peer's latest handshake is
older than `wireguard_reresolve_stale_seconds` (150), it re-resolves the
`Endpoint` hostname — read from `/etc/wireguard/<iface>.conf`, since
`wg showconf` only reports the resolved IP — against
`wireguard_reresolve_resolver` (`1.1.1.1`) and, on a changed address, runs
`wg set … endpoint`. The resolver is queried directly because a downed tunnel
takes its DNS with it. A healthy tunnel rehandshakes within the threshold, so
the timer no-ops.

Variables in `defaults/main.yml`: `wireguard_reresolve_interface`,
`wireguard_reresolve_resolver`, `wireguard_reresolve_stale_seconds`,
`wireguard_reresolve_interval`.
