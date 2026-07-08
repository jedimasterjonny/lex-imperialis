# podman

Container runtime for the quadlet roles: podman plus aardvark-dns — only
recommended by zypper, but required for containers on a podman network to
resolve one another — and `/etc/containers/systemd`, where backend roles
drop their units.

The netavark firewalld-reload listener is enabled, so a firewalld reload
reapplies netavark's rules instead of dropping published ports and
inter-container networking.

NetworkManager is told to leave podman's bridges (`podman*`) unmanaged via
`conf.d/podman.conf`, so tearing down the last container bridge doesn't fire an NM
event that unmounts the `_netdev` NFS shares — which otherwise breaks the
`podman_backup` run and the arr-stack restart. Skipped where NM is absent.

A weekly timer (Saturday 06:00, persistent) prunes unused images, so
superseded quadlet image pulls don't accumulate.
