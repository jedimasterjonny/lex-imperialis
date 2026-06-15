# common

Owner account and base tooling for every host: the account mirrors the
local Tumbleweed install (uid 1000, group `users`, wheel), no password
managed, plus `bash-suse` dotfiles via the stow role.

Wheel sudo authenticates with the member's own password — the drop-in
overrides SUSE's vendor-default `targetpw` — and is `visudo`-validated so
a broken policy never lands.

Also sets the host identity: the hostname from the required `common_hostname`,
and a `localdomain` DNS search domain pinned through netconfig's static
searchlist.
