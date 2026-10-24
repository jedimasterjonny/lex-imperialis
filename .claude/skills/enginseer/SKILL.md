---
name: enginseer
description: >-
  Take the NAS (administratum) offline for planned maintenance — a DSM update,
  a reboot, a disk swap — with nothing on the fleet breaking or paging, then
  bring it back. Discovers every consumer live on each run: the hosts that
  mount it, the services, containers and timers that depend on each mount, the
  clients the inventory does not know about, and the alerts the window will
  trip. It records that state to disk, quiesces it, silences only what the
  window trips, and restores exactly what it recorded once the operator says
  the NAS is back. Asks the operator to approve the plan before changing
  anything. Triggers include "enginseer", "take the NAS offline", "NAS
  maintenance", "DSM update", "reboot the NAS", "unmount the NAS across the
  fleet" and "bring the NAS back". Not for an unplanned outage, where the
  mounts are already hung: diagnose that directly.
---

# Enginseer

Quiesce every consumer of the NAS, hand the operator a dark NAS, then put back
exactly what was running.

The fleet grows, shrinks and changes. Nothing here names a host, unit, timer,
container or probe target as fact, and neither should memory. Every run
discovers them live, and the restore puts back what the survey recorded.

## Authorisation

CLAUDE.md requires the operator's explicit authorisation for every live change,
and invoking this skill is not one of its standing authorisations. §1 and §2
are read-only. §2 ends in an approval that names both halves of the change,
plus the rule silences follow. §3 runs on that approval, and §5 runs when the
operator says the NAS is back. If anything turns up mid-run that the approved
plan did not name, stop and ask. Never run a play: `make apply` would also
apply whatever `main` holds.

## 0. Ground rules

- **Ad-hoc commands:** run from the repo root with `.venv` sourced, as
  `ansible <pattern> --vault-password-file .vault_pass -b -m shell -a '…' < /dev/null`.
  The inventory loads vault vars, so without the password file every command
  aborts. Use inventory names, so the control host is `this_host`. Put anything
  longer than one line in a scratchpad script and run it with `-m script`.
  That sidesteps quoting and Ansible's templating of `{{`.
- **The NAS:** `ssh -o BatchMode=yes -o ConnectTimeout=10 administratum '<read>'`
  as the operator's own login. Reads only, and no sudo, because it prompts.
- **The record:** keep it in `~/.local/state/enginseer/record.md` on the control
  host, outside the repo. Write it at the end of §1 and update it at every §3
  step. §5 works from this file alone, so a fresh or compacted session can
  restore. It holds no secrets.
- **Public repo:** keep addresses and ports out of commits, memory and this
  file. The chat report and the record may show them.
- **Unmounting:** never `umount -l` or `-f`. A lazy unmount of a `hard` mount
  hides it from `findmnt` while every holder still blocks on the server that is
  about to vanish.

## 1. Survey (read-only)

Run every check on every inventory host, not only the hosts you expect to mount
the NAS.

1. **The NAS's addresses.** Read them from the NAS itself with
   `/sbin/ip -o addr`, keeping global scope. DNS returns only the name the plays
   use, and a host can mount through any of the NAS's interfaces.
2. **Units.** Snapshot each host's unit states with
   `systemctl list-units --all --plain --no-legend --state=active,activating,deactivating,failed`.
   This is the baseline for the whole restore. It catches collateral the
   dependency properties do not show: stopping an fstab mount also stops
   `remote-fs.target`.
3. **Mounts.** Run `systemctl list-units --all -t mount,automount` and take
   `What`, `Where`, `Type` and `FragmentPath` for each NFS unit. Inactive and
   failed units count too, because a trigger can still pull one up. Resolve each
   `What` server on its own host with `getent ahosts`, and keep the units that
   land on a NAS address. That covers a host which mounts by a literal address
   or by another name. A unit with no `FragmentPath` was synthesised from
   mountinfo, such as a hand mount or a podman NFS volume. `systemctl start`
   cannot bring it back, so it goes to the operator as a question.
4. **Declared dependents.** For each mount unit, run
   `systemctl show <unit> -p RequiredBy,WantedBy,BoundBy,UpheldBy` and drop the
   targets. Use these properties, not `list-dependencies --reverse`, which
   recurses through `remote-fs.target` and turns up NetworkManager and dracut.
5. **Undeclared users.** Anything that uses a share without declaring the mount
   either keeps the unmount busy or writes to the bare mount point once the
   share is gone.
   - **Holders:** run `fuser -vm <where>`. Any process listed beyond the
     kernel's own entry is a holder.
   - **Namespaces:** scan `/proc/[0-9]*/mountinfo` for NAS mounts in mount
     namespaces other than PID 1's.
     - A line without `master:` in its optional fields is a private copy. It
       keeps the server pinned after the host unmounts, which is how the arr
       containers bind their media.
     - A `master:` copy follows the host's unmount, so it needs no action.
     - Find the owning unit with `ps -o unit=,uunit= -p <pid>`. That also
       catches rootless containers under lingering users.
   - **Config:** `grep -rlI` for each `Where` across the system and user unit
     and quadlet directories, the cron tables and `/usr/local/{bin,sbin}`. A hit
     that is not a declared dependent is an undeclared one.

   Record each undeclared user against its owning unit. A user with no unit,
   such as an operator's shell, goes to the operator as a question.
6. **Triggers.** For every dependent, declared or not, run
   `systemctl show <unit> -p TriggeredBy` to find its timers, paths and sockets.
   A trigger that fires during the window starts its service, and the service's
   `Requires=` pulls the mount back up mid-update. If an `autoupdate.timer`
   window overlaps the outage, offer it as a trigger to stop too. A reboot
   re-arms every trigger §3 stopped.
7. **Clients outside the inventory.** On the NAS, run
   `netstat -t --numeric-hosts` and list every `ESTABLISHED` inbound session to
   a listening port, minus your own SSH. Then match each against the fleet's
   mounts: each fleet mount reports its own end of the connection as
   `clientaddr=`. Anything left over is something this skill will not quiesce.
   That is a single snapshot, so also read `docs/schedule.md` for clients that
   connect intermittently.
8. **Monitoring.** Find the hosts whose plays carry the `prometheus` and
   `alertmanager` roles. Find Prometheus by its live listener there
   (`ss -Hltnp`), not by a play var. Record:
   - every **firing** alert, as the baseline (pending ones are not, because the
     window keeps their `for:` clocks running);
   - `probe_success` for every target;
   - each scrape job's `scrape_interval` and `scrape_timeout`, and the global
     `evaluation_interval`, from `/api/v1/status/config`.

   Alertmanager is reached through `amtool` inside its container, at the URL the
   container's own `HealthCmd` uses.
   - If Prometheus or Alertmanager is itself a dependent, alerting goes dark
     with the share. Say so.
   - If Uptime Kuma has any notification configured, its monitors page outside
     Alertmanager. They go in the plan for the operator to pause in its UI.
9. **Writers to the fleet.** Find every host running `arbites.timer`. Take the
   pause flag path from the live script that `systemctl cat arbites.service`
   names. Record whether the flag already exists: an operator's pause predates
   this run and has to survive it. Then run `pgrep -af ansible-playbook` on the
   control host. A concurrent play remounts the shares and restarts their
   dependents, because every role's tasks start their units.
10. **Schedule.** Run `systemctl list-timers` on each host. In the plan, name:
    - every timer that falls in the window;
    - which of those are not `Persistent=`, since they skip their slot instead
      of catching up;
    - the DSM jobs in `docs/schedule.md` that fire in the window;
    - jobs that read the NAS later, such as `offsite_mirror`. A DSM reboot can
      clear what they read, so they may alert hours after the silences are gone.
11. **The NAS itself.** Record its `uptime` and, from `/etc.defaults/VERSION`,
    `productversion`, `buildnumber` and `smallfixnumber`, for the before-and-after
    line.

Write the record.

## 2. Plan and approval

Give the plan as one table per host:

| Mount | Dependents to stop (✱ = undeclared) | Triggers to stop |
| --- | --- | --- |

Under the table, list:

- the clients this skill cannot quiesce;
- the dependents that serve people, whose sessions will drop;
- schedule collisions;
- the §3 and §5 steps as they will run, with exact unit names;
- **the silence rule**, which the approval covers. Silences go on every pending
  or firing alert whose labels name a quiesced host's mount, unit or container,
  on a NAS probe, or on a probe that was up at the survey and is down since. Each
  silence uses the alert's full label set minus `alertstate`, and silences are
  extended until the restore.

Then ask one `AskUserQuestion` with three options: go with silences
(recommended), go without, or not yet. Go without skips §3 step 3 and the
silencing in §4.

## 3. Quiesce

The order matters: each step removes something that could undo a later one.
Update the record after every step.

1. **Re-check.** Re-read the unit states and `ALERTS`, and rerun
   `pgrep -af ansible-playbook`.
   - If a dependent is `activating` or `deactivating`, wait for it to finish.
     A backup mid-run has stopped its own containers and restarts them on exit,
     so never stop one.
   - If anything else moved since §1, update the plan and ask.
2. **Pause arbites.** Touch the flag on each arbites host, unless it already
   exists, then wait for `arbites.service` to go inactive. A run already under
   way never re-reads the flag, and it may be partway through the `nfs` role.
3. **Silence what is certain to trip,** before anything stops:
   - `NfsShareUnmounted` for each recorded mount unit;
   - `ProbeDown` for each probe of a NAS address or name.

   Create this run's own silences even where an existing one already covers an
   alert, because that one can lapse mid-window. Use
   `amtool silence add -d 2h -a <operator> -c '<reason>' <matchers>` and record
   every ID and end time.
4. **Stop** the triggers recorded active.
5. **Stop** the dependents recorded active, declared and undeclared. Use one
   `systemctl stop` per host, so systemd orders the stops.
6. **Stop** the automounts, then the mount units. If a mount will not stop, it
   is busy: rerun the §1.5 checks, report the holder and ask.
7. **Verify** on every host:
   - the §1.5 namespace scan finds no private copy;
   - `/proc/fs/nfsfs/servers` has no entry whose HOSTNAME is a recorded `What`
     server;
   - every `Where` is empty: `find <where> -mindepth 1 -print -quit` prints
     nothing.
8. **Start the §4 poll,** and leave it running.
9. **Hand over.** Tell the operator the NAS is dark. Give the silence IDs and
   when they end, and say the next step waits for their word that the NAS is
   back.

## 4. The window

Keep one background poll running from §3 step 8 until the restore: Bash
`run_in_background` with an `until` loop that exits. It exits when any of these
is true:

- a pending or firing alert falls under the silence rule and none of this run's
  silences covers it;
- this run's earliest silence is 10 minutes from ending;
- `ansible-playbook` is running on the control host;
- a `Where` is no longer empty.

When it exits, act on the cause. Silence the alert, extend the silence, or
report the play or the write to the operator. Then re-arm the poll.

Alerts fed by a periodic writer, such as `inquisition`'s `QuadletNotRunning`,
only appear when that writer next runs, so a single check is not enough.

## 5. Restore

Run this when the operator says the NAS is back, working from the record.

1. **Check the mount points again.** Anything written under a `Where` during the
   window is hidden the moment the share remounts over it. Report it before you
   mount anything.
2. **Start** the recorded mount units, then the automounts, on every host. If a
   start fails, the NAS is not serving yet. Wait a minute and try once more. If
   it fails again, stop the restore and report.
3. **Start** the dependents recorded active, then the triggers recorded active.
   A `Persistent=` timer whose slot passed during the window catches up as soon
   as it starts. That is expected, but name it.
4. **Diff against the §1.2 snapshot.**
   - Start every unit that was active then and is not now, such as
     `remote-fs.target`.
   - Report any unit that is failed now and was not then.
5. **Wait for the alerts under the silence rule to resolve,** with a background
   `until` loop on `ALERTS`. Expiring a silence while its alert still fires in
   Prometheus sends that alert straight to Discord.

   An alert fed by a periodic writer stays pending until the writer next runs.
   Do not hold the restore for it, and do not expire its silence. Move the
   silence's end to after the writer's next run, plus one scrape interval and
   one evaluation interval, and let it lapse.
6. **Clean up only what this run created.**
   - Expire this run's other silences by ID.
   - Remove the arbites flag only if this run touched it, and say when arbites
     next fires.
   - Stop the §4 poll.
   - Delete the record.
7. **Report:**
   - the window's length;
   - the NAS version before and after, and whether it rebooted;
   - what stopped and restarted on each host;
   - the silences created, expired and left to lapse;
   - any alert that fired;
   - the next run of each job from §1.10 that reads the NAS.

## Failure paths

- **The NAS is unreachable before §3:** the outage is unplanned. Holders on a
  `hard` mount are already blocked, and stopping them can hang. This skill does
  not apply, so stop and report.
- **The NAS does not come back:** leave everything quiesced, keep arbites paused
  and keep extending the silences. Then report and wait for the operator. Never
  apply a play to recover.
- **§5 is asked for with no record:** stop. Do not rebuild the record from
  memory. Survey the current state, and ask before starting anything.
