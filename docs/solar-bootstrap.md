# solar — manual bring-up record

Steps that got `solar` to the point Ansible takes over but are **not** codified
in this repo. Captured for later automation; update as bootstrap proceeds.

`solar` is the ynarri replacement (see the arr stack migration). Same hardware
as the old ynarri box, wiped and reinstalled.

## Done by the operator (pre-Ansible)

- Fresh **openSUSE Tumbleweed** install on the ex-ynarri hardware.
  - Hostname `solar`; btrfs root, mounted `rw` (regular Tumbleweed, **not**
    transactional/MicroOS); SELinux enabled (unconfined).
  - Installer created owner `jonny` (uid 1000) with a **user-private group**
    `jonny` (gid 1000), no `wheel`. The `common` role reconciles this to
    primary group `users` + `wheel`.
  - Stock repos: OSS, non-OSS, Tumbleweed, openh264, plus the snapshot update
    repo.
- Same NIC as old ynarri, so the DHCP lease/IP carried over. The router
  resolves the name `solar` to it; the inventory relies on that.
- Ran `bootstrap/host.sh` (in this repo) as root: created the `ansible` system
  account (uid 469, key-only, NOPASSWD sudo), installed its `authorized_keys`
  from the operator's GitHub keys, and enabled `sshd`.

## Still manual / to decide

- **Hostname**: set manually (installer / `hostnamectl`), not yet codified.
  Automate — set it from the play (e.g. `ansible.builtin.hostname`) so a rebuild
  reproduces it without a manual step.
- **Update model**: solar is non-transactional and has no `transactional-update`
  installed. The `autoupdate` role would install it and commit the box to weekly
  `dup`+reboot. Deferred pending an explicit decision — not part of base bring-up.
- **DHCP reservation**: confirm solar's lease is a static reservation, not one
  that could move. Router-side, so it cannot be Ansible-managed from here.
