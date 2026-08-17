# common

Owner account and base tooling for every host: the account mirrors the
local Tumbleweed install (uid 1000 by default, group `users`, wheel),
no password managed, plus the distribution's bash dotfiles via the stow role.

The fleet is openSUSE bar `auspex`, which is Raspberry Pi OS, so three defaults
are derived from `ansible_facts['os_family']` rather than branched in `tasks/`:
`common_disabled_repos`, empty on Debian so the four zypper repository tasks loop
over nothing and skip; `common_chrony_conf_dir`; and `common_bash_stow_package`.
They are defaults, so a play still overrides any of them — which `vars/Debian.yml`
would not.

Packages install through `ansible.builtin.package`. On openSUSE it dispatches to
the zypper module, whose `disable_recommends` already defaults true, so that is
behaviour-preserving; on Debian it dispatches to apt, where it cannot refresh the
package lists, so a Debian-gated `apt: update_cache` runs ahead of it. That
refresh serves the whole play rather than this role: `common` runs first
everywhere, and `autoupdate` masks `apt-daily.timer`, so nothing else would.

Wheel sudo authenticates with the member's own password — the drop-in
overrides SUSE's vendor-default `targetpw` — and is `visudo`-validated so
a broken policy never lands.

The `ansible` account's NOPASSWD grant is held the same way, at
`/etc/sudoers.d/<common_ansible_user>`. It is the widest privilege on the fleet
and was written once by whichever bootstrap built the host, then reconciled by
nothing — the same drift the key lists had, on the account those keys open.
Holding it also settles *where* it lives: cloud-init writes the identical rule as
`90-cloud-init-users`, so auspex had it under a different name from every other
host. That file is removed, after the managed one is written — the reverse order
would leave a window with no grant, and an apply failing inside it would strand
the account unable to escalate. A reflash recreates it and the next converge
takes it away again.

`common_authorized_keys` and `common_ansible_authorized_keys` declare who may
reach the owner account and the `ansible` account (`common_ansible_user`, a
constant in `vars/` — bootstrap fixes that name and the inventory connects as
it). Both are empty here and set fleet-wide in
`inventory/group_vars/all/authorized_keys.yml` — public keys, so plaintext. The
split is by principal: human devices reach a host as the owner, where sudo costs
a password, while the `ansible` account holds NOPASSWD sudo and so carries only
the control host and the reconciler. A key that needs only git access belongs on
GitHub and in neither list. That is the posture the lists declare, not yet the
fleet's: while both `exclusive` flags are `false` nothing is revoked, and auspex
in particular still carries its cloud-init seed of five keys on both accounts,
the corporate laptop among them. A play can also narrow a list — `rogue-trader`
replaces the owner one, since play vars beat `group_vars` rather than extending
them.

The role manages these because nothing else reconciles them. `bootstrap/host.sh`
seeds the `ansible` account from the operator's GitHub keys once, at install, and
never again — so each host froze whatever that list held on the day it was built,
and a key removed upstream survives on every host predating the removal. That
seed is still live: until it is trimmed, a rebuilt host is born with the whole
GitHub list on its `ansible` account, which these additive lists will not undo.

`common_authorized_keys_exclusive` and `common_ansible_authorized_keys_exclusive`
make a list authoritative: anything absent from it is removed. They are separate
so the `ansible` account can be made authoritative first, while the owner's stays
additive and cannot lock the operator out of a host whose declared list is wrong.
Each task is skipped when its own list is empty — that is what keeps an unset or
mis-scoped list from meeting `exclusive` and stripping an account of every key,
including the one the play is connected on. The cost of that guard is that an
account cannot be emptied *through* the list: trimming it to `[]` skips the task
rather than revoking everything, so the last key has to go by hand.

Each list passes as one newline-joined `key:` rather than a loop. Under
`exclusive` a loop would leave only the last iteration's key, converging green
having revoked the rest.

Two things it does not hold. The file's **mode**: `authorized_key` chowns and
chmods only on a write, so a converged host whose `authorized_keys` is already
group-writable keeps it — and sshd refuses such a file, locking the account out
without the role reporting anything. And a declared key's **options**: the module
matches on the options too, so a key on disk carrying `from=` or `command=` that
the list declares bare is deleted and re-added without them, converging green
having dropped the restriction. Neither is the fleet's state today — every key on
it is a plain line — but both are gaps in what this manages now that it owns
files it did not write.

Also sets each host's hostname from the required `common_hostname`.

Sets the SELinux mode from `common_selinux_mode` (default `enforcing`) via
`ansible.posix.selinux`, so the fleet's mode is config-as-code rather than the OS
default. Every fleet host already enforces, so it holds the mode rather than
setting it, and converges as a no-op. Gated on `ansible_selinux.status ==
'enabled'`, so the SELinux-less molecule containers skip it.

That module imports `python3-selinux`, which `common_packages` carries — so
`Install base packages` must stay ahead of it. **On MicroOS that ordering is not
enough**: the install lands in a new snapshot, so the image has to ship the
binding already. `packer/stage2-provision.yml` reads `common_packages` for that.

Seven of the fleet's package names resolve through a `Provides` of a versioned
rpm — `python3-selinux` here, `python3-firewall` in firewalld,
`python3-libvirt-python` and `python3-lxml` in libvirt, `python3`, `python3-pip`
and `npm` in dev — and the zypper module `package` dispatches to prefilters
`name:` on package name, so none short-circuits: every converge runs a real
`zypper install`, reporting `ok`.

**On MicroOS each becomes a `transactional-update` snapshot, created then
dropped, and it is the *drop* that arms
`sdbootutil-update-predictions.service`** — snapper's `delete-snapshot-pre` hook
calls `set_update_predictions_timer`, where `create-snapshot-post` returns before
reaching it on a transactional system.

`zypper install` also upgrades, so those seven are eligible for upgrade on every
merge-triggered apply, outside `autoupdate`'s weekly `zypper dup` — a correctness
concern rather than a performance one. Unrealised so far, per `rpm -qa --last`.

Unfixed upstream; left alone here, an `rpm --whatprovides` guard costing about
what it saves.

Creates `/var/lib/pcrlock.d`. `sdbootutil-update-predictions.service` runs after
every snapper snapshot and its `ExecStartPre` fails without that directory, which
only a TPM2 LUKS enrolment would otherwise create — so an unenrolled TPM2 host
raises `SystemdUnitFailed` on its next zypper transaction.

`common_disabled_repos` holds zypper repositories disabled — the NON-OSS and
Cisco openh264 repos, which every openSUSE host enables and none installs from.
No role otherwise adds or edits a stock repository, so what was an observation is
now held: every listed alias a host carries is disabled on each converge, and one
it does not carry is a no-op rather than a new repository. Disabled, not removed —
the definition stays on disk. Dropping an alias stops holding it disabled but does
not re-enable it, the opposite of `common_blacklisted_modules` below, which
reclaims a module when emptied.

The NON-OSS alias tracks how a host was installed rather than its distro —
`download.opensuse.org-non-oss` on the fleet's Tumbleweed installs,
`repo-non-oss` on images shipping the stock `repo-*` set, as the MicroOS and
molecule images both do — so both spellings are listed.
`community.general.zypper_repository` cannot locate a definition by its `[alias]`
section: it requires the URL, creates the repository when the alias is absent, and
matches on alias *or* URL — and each repo's baseurl is identical fleet-wide, so it
would find rogue-trader's `repo-non-oss` by URL and rename it. So the role locates
the file itself and edits it in place with `community.general.ini_file`.

The role refuses to disable a repository whose current contents match an installed
package — see the assert's message. rpm records no provenance, and the match is
version-exact, so a package installed from a repo that has since bumped it is not
caught; `zypper packages --installed-only --repo <alias>` matches by name and is
the check to run by hand. That guard is what makes the hand re-enable safe: a repo
re-enabled by hand is re-disabled by the next apply that reaches it, and since the
reconciler skips a run when `main` has not advanced, that is the next commit
rather than the next timer tick. Unless something has been installed from it —
then the assert halts `common`, the first role of each openSUSE play, so that host
converges no further, `site.yml` stops there, and `ArbitesFailed` goes
critical.

`common_ntp_sources` adds NTP sources through
`{{ common_chrony_conf_dir }}/common-ntp.conf`, one `pool` line each, alongside
whatever the install left in the packaged `pool.conf` — `time.cloudflare.com` by
default.

It buys availability, not an independent second opinion: chrony votes each
address behind that name separately, but they are one operator's anycast and can
be wrong together. A second, unrelated operator in the list is what would add
one.

The drop-in must not take the packaged file's name: under an `include
/etc/chrony.d/*.conf` Ansible would overwrite the vendor file, and under a
`confdir /etc/chrony.d /usr/etc/chrony.d` it would shadow it — either way the
distro's own source vanishes silently, so molecule asserts it survives. Which
layout a host has follows its chrony package rather than its distro, and the
fleet currently spans all three: those two, and Debian's
`confdir /etc/chrony/conf.d` beside its own `pool 2.debian.pool.ntp.org`. The
render is unconditional, so emptying the list falls back to that source rather
than leaving a stale file.

`common_packages` carries `chrony`: its package owns the drop-in directory, and
the handler restarts `chronyd` — an alias of `chrony.service` on Debian — which
reads its sources only at start.

That restart is the half no container can exercise, so the handler restarts only
a `chronyd` already running and molecule proves the drop-in through `chronyd -p`
instead — see the comments on each. The gap that leaves is a host whose `chronyd`
is stopped: it takes the file but not the source, until the next start.
`ClockNotSynchronised` catches that host, in hours rather than minutes.

`common_blacklisted_modules` bars kernel modules via
`/etc/modprobe.d/common-blacklist.conf` — `blacklist` plus `install
<module> /bin/false` — and unloads any already live rather than leaving
them until the next boot. The drop-in renders unconditionally, so
emptying the list reclaims the modules instead of leaving a stale file
barring them. The list unloads in order: a holder must precede what it
holds, `iwlmvm` before `iwlwifi`. The role creates `/etc/modprobe.d` first:
kmod owns it and every fleet host has it, but a minimal Debian image can ship
without kmod, and `template` does not create a parent.

The unload is the untested, unpreviewed half: it is skipped under
`--check`, no molecule tier can exercise it (a container unloads
nothing), and it does not reach a module baked into the initramfs, which
the role does not regenerate.
