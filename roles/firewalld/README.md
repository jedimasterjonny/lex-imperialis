# firewalld

Enables firewalld and opens the ports each host serves. The default zone keeps
its system default (`public`); the role only adds to it.

`firewalld_services` and `firewalld_ports` are the openings; a host needing more
than the `ssh` baseline sets its own list in the play (`playbooks/solar.yml` opens caddy's
80/443 plus QUIC and the Plex port set). Rules are written `permanent` and
`immediate`, so they apply at once and survive a reload or reboot.

incus needs firewalld up for its bridge-trust task, so the plays apply this role
before incus.
