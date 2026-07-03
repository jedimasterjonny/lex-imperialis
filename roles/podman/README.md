# podman

Container runtime for the quadlet roles: podman plus aardvark-dns — only
recommended by zypper, but required for containers on a podman network to
resolve one another — and `/etc/containers/systemd`, where backend roles
drop their units.

The netavark firewalld-reload listener is enabled, so a firewalld reload
reapplies netavark's rules instead of dropping published ports and
inter-container networking.

A weekly timer (Saturday 06:00, persistent) prunes unused images, so
superseded quadlet image pulls don't accumulate.
