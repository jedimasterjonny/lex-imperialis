# autoupdate

Unattended weekly updates. A oneshot service runs `autoupdate_update_command` on
a per-host schedule (`autoupdate_oncalendar`, default `Mon *-*-* 03:00:00` plus a
0–2 h jitter) and reboots after a successful run so a new kernel takes effect —
`zypper dup` on Tumbleweed, `transactional-update dup` on MicroOS, whose root is
read-only, and `apt-get update` then `apt-get dist-upgrade` on Debian. The fleet
sets the schedule per host to different days so one bad update cannot brick every
host in a single night. `zypper`'s 102/103 "reboot/restart recommended" codes
count as success; a real failure skips the reboot, leaving the system up for
inspection.

`autoupdate_update_command` is a list, one `ExecStart=` per element, because
`zypper dup` refreshes its own metadata and `apt-get dist-upgrade` does not.
`Type=oneshot` runs them in order and aborts on the first failure, so the
refresh gates the upgrade. The Debian arm carries `--force-confold` and
`--force-confdef`, and the unit sets `DEBIAN_FRONTEND=noninteractive`
unconditionally — inert under zypper, and without it a changed conffile prompts
and hangs the unit until `TimeoutStartSec` on a host with nobody at the console.

A failed run retries hourly, three times (`Restart=on-failure`, `RestartSec=1h`,
bounded by `StartLimitBurst=4` over a `StartLimitIntervalSec=1d` window that
resets before the next weekly run). This exists for the one failure mode a
retry actually fixes: a mirror serving repo metadata ahead of the RPMs it
indexes, which aborts the whole commit with "Some packages could not be
provided" and would otherwise leave the host unpatched for seven days over a lag
that clears in hours. `AutoupdateFailed`'s `for:` is set longer than the 3 h the
burst spans, so a run still healing itself does not page — change one and change
the other.

`autoupdate_transactional` and `autoupdate_debian`, derived from
`ansible_facts`, select the command. `autoupdate_masked_timers` names the
distribution's own update timers, which are stopped and masked so exactly one
thing updates a host — `transactional-update.timer` on MicroOS,
`apt-daily.timer` and `apt-daily-upgrade.timer` on Debian, nothing on
Tumbleweed. Left armed they would update and reboot daily, writing none of the
metrics below. Both Debian timers are masked rather than only the upgrade one:
the metadata prefetch that costs is what `common`'s `apt: update_cache` already
does on every converge.

**On a Raspberry Pi the weekly `dist-upgrade` can flash the boot EEPROM.**
`rpi-eeprom-update.service` is enabled by the image and runs `-a` at every boot,
so a staged `rpi-eeprom` plus this role's own `ExecStartPost` reboot writes
firmware unattended on a headless board — and a failed flash is not a failed
service, it is a board that does not boot. Accepted rather than held: `auspex` is
stateless by design and its documented recovery is a card reflash, so the
recovery cost is bounded and the alternative is a host whose firmware silently
never moves. `apt-mark hold rpi-eeprom` is the lever if that trade stops looking
right.

An `ExecStopPost` hook writes each run's outcome to
`autoupdate_textfile_dir/autoupdate.prom` — `autoupdate_success` (1/0 from
`$SERVICE_RESULT`) and `autoupdate_last_run_timestamp_seconds`. node_exporter
scrapes that file (its `node_exporter_textfile_directory` must match), and the
`prometheus` role's `AutoupdateFailed` / `AutoupdateOverdue` rules surface a
failed or overdue update.

The first `ExecStartPost` hook, ahead of the reboot, uninstalls what the update
leaves behind and writes `autoupdate-cleanup.prom`:
`autoupdate_uncleaned_packages{class}`, one sample for each of the two classes of
package nothing needs. `unneeded` — auto-installed and now required by nothing —
is the class it removes, with `apt-get --yes --purge autoremove` on Debian and
`zypper remove --clean-deps` over `zypper packages --unneeded` on openSUSE, which
has no autoremove of its own. `orphaned` — installed, and offered by no
repository — is removed only where it is also unneeded, never for being an orphan
alone: a repository that fails to load turns every package it carries into an
orphan, where nothing a mirror does can make an installed package unrequired, so
keying the removal on the other class is what stops a mirror outage stripping a
host. The two overlap, and a package in both goes with the unneeded set — dead
twice over, though only a snapshot can put it back, since no repository offers
it. What the orphaned count publishes is therefore the orphans that are *not*
unneeded — subtracted, so that holds on a host where the removal failed or never
runs as much as on one where it worked: something installed requires them, or
they were asked for by hand — or by a role, in which case the decision belongs in
the role, since removing them only invites the next converge to put them back.
`AutoupdatePackagesUncleaned` alerts on either count above zero.

Both counts are recomputed after the removal rather than assumed, so a healthy
host publishes `unneeded` 0 and the alert reads exactly what the pass could not
clear: a removal that failed, an orphan awaiting a decision, or MicroOS, where
the removal does not run at all. A second `transactional-update` after the dup
bases its snapshot on the running system — silently discarding the very update
the hook was called from — unless given `--continue`, which then fails outright
when the dup changed nothing and deleted its own snapshot. rogue-trader is
minimal by construction, so it reports, and the operator clears it by hand with
`transactional-update run zypper remove --clean-deps <names>` over what
`zypper packages --unneeded` lists — then reboots, because that removal lands in
a new snapshot while the running system's RPM database is unchanged, so re-running
the hook republishes the same count. For the same reason MicroOS counts describe
the snapshot the host is running, not the one the dup just built: the hook runs
before the reboot, so what it publishes is always one update behind. Immaterial
while the count is zero, and worth remembering when it is not.

The hook is `-`-prefixed for more than the metric's sake: a solver problem in the
removal must not cost the host its reboot onto the new kernel. A failed removal
still publishes on openSUSE, where the recount is a separate read; on Debian it
is the same `autoremove` in dry-run, so a dpkg left mid-transaction fails both
and the script dies before the rename — but that state fails `dist-upgrade`
first, which is `AutoupdateFailed`'s case rather than this one's. A failed
*query* likewise leaves the last publication standing, as with the holds hook
below. zypper's exit 106 is not one: a repository it could not refresh is
tolerated, since aborting over a flaky mirror would freeze the counts with
nothing to mark them stale. That can inflate the orphaned count for a run — a
repository that did not load offers nothing — which is a false alert that clears
itself, and it cannot reach the removal. Two interactions worth knowing. A lock
beats the cleanup rather than fighting it: `zypper remove --clean-deps` skips a
locked package, removes the rest and still exits 0, and apt drops a held package
— and anything only it requires — from `autoremove` outright, so neither is
counted afterwards and this alert stays quiet. `AutoupdatePackageHeld` is what
reports that package, as it does for the update itself. And `--clean-deps` takes
the dependencies the listed packages leave unneeded in turn, so the transaction
is routinely larger than the count that triggered it.

The other `ExecStartPost` hook writes `autoupdate-holds.prom` beside it:
`autoupdate_package_hold{package}` per package this host holds back, from
`zypper --xmlout --non-interactive ll` on openSUSE and `apt-mark showhold`
on Debian — both local reads, with no repository load and nothing to fail on a
lagging mirror. A hold is the one deliberate skip the outcome metric cannot see: a
`dup` or `dist-upgrade` that leaves a locked package alone still exits 0, so the
run reads as a success while that package silently stops being patched.
`AutoupdatePackageHeld` alerts on it. Blind spots: a lock stanza `addlock` never
writes — one naming no package, or two names in one entry — is read wrong or not
at all, and apt's resolver can keep a package back with no hold set.

It runs from the update rather than a timer of its own, so it cannot report a skip
before an update has skipped anything — and the gauge then moves only when a run's
hook succeeds, which cuts both ways. A cleared lock keeps the alert firing and a
newly set one goes unreported for up to a week. The hook is `-`-prefixed, so the
reboot never hinges on a metric writer, but strict within: a failed query dies
before the rename, leaving the last publication standing rather than a hold-free
lie until a run whose hook succeeds — and nothing alerts on that freeze. Accepted
rather than fixed: re-running `autoupdate-holds.sh` republishes at once, which is
what the alert tells the operator to do, and watching the hook properly would want
a `*_success` metric, a `ScheduledJobMetricMissing` roster entry and the paired
rules behind it — more machinery than a warning-severity gauge over two local
reads is worth.

rogue-trader is where the transactional arm runs, and the only place that arm's
command is proven: no molecule tier boots MicroOS, so the scenario pins the
selector against shadowed facts and nothing more, and the cleanup's transactional
arm — which only decides not to remove — is never rendered under test at all. The
removal on the other two arms is proven for real: the scenario strands a
dependency on each platform and asserts the hook uninstalls it. The
stop-before-mask ordering is no longer unproven either — the Debian platform
ships both apt timers active, so it exercises the two tasks for real.
