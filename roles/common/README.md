# common

Owner account and base tooling for every host: the account mirrors the
local Tumbleweed install (uid 1000 by default, group `users`, wheel),
no password managed, plus `bash-suse` dotfiles via the stow role.

Wheel sudo authenticates with the member's own password — the drop-in
overrides SUSE's vendor-default `targetpw` — and is `visudo`-validated so
a broken policy never lands.

Also sets each host's hostname from the required `common_hostname`.

`common_blacklisted_modules` bars kernel modules via
`/etc/modprobe.d/common-blacklist.conf` — `blacklist` plus `install
<module> /bin/false` — and unloads any already live rather than leaving
them until the next boot. The drop-in renders unconditionally, so
emptying the list reclaims the modules instead of leaving a stale file
barring them. The list unloads in order: a holder must precede what it
holds, `iwlmvm` before `iwlwifi`.

The unload is the untested, unpreviewed half: it is skipped under
`--check`, no molecule tier can exercise it (a container unloads
nothing), and it does not reach a module baked into the initramfs, which
the role does not regenerate.
