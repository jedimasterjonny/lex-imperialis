# podman

Container runtime for the quadlet roles: podman plus aardvark-dns — only
recommended by zypper, but required for containers on a podman network to
resolve one another — and `/etc/containers/systemd`, where backend roles
drop their units.

A weekly timer (Saturday 06:00, persistent) prunes dangling images, so
superseded quadlet image pulls don't accumulate.
