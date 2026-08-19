# Disaster recovery

Bringing a lost host back: re-bootstrap it, run its play, restore its podman
volumes. The play rebuilds everything declarative (packages, quadlets, config);
the restore returns the stateful volume data the backup holds.

## Prerequisites

Recovery is driven from a control host with:

- The repo (public, on GitHub) — clone it.
- `.vault_pass` — gitignored, so restore it from the password manager. It
  unlocks every other secret in the repo.
- The venv: `python -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`.
- SSH reach to the host being recovered — over the LAN, or over WireGuard for a
  rogue-trader that still has its tunnel. A rebuilt rogue-trader has neither
  until step 3, so it is reached at its public address instead.
- The Hetzner Console login for the **storage box project** (password manager;
  a separate project from emmas-edit, and in neither the vault nor terraform).
  Needed to recover the off-site copy: it is the way back to both External
  Reachability and the box's sub-account password.

`scholam` is the usual control host. If `scholam` itself is lost, recover it
first (below), or drive the others from any machine meeting the above.

## What is and isn't backed up

The full backup architecture — all four layers — is in [`backups.md`](backups.md);
this is the recovery-relevant summary.

`podman_backup` runs on `solar` and `rogue-trader` only, writing a per-host
restic repo to `/nfs/astropath/<hostname>-podman-backup` on the NAS. The repo
holds every podman named volume — so all container state (databases, app config,
Plex library and history, the WordPress site) travels in it. Media on the NFS
shares is not in the repo; it lives on the NAS and is the NAS's own concern.

`home_backup` runs on `solar`, `scholam`, and `rogue-trader`, writing a per-host
restic repo to `/nfs/astropath/<hostname>-home-backup` holding that host's `/home`.
It shares the `restic_backup` engine with `podman_backup`, and both sets of repos
sit under `astropath`.

`scholam`'s only podman workload is `node_exporter`, which is stateless, so it has
no podman repo; its recoverable state is the git repo, `.vault_pass`, and its
`/home` restic repo. `administratum` (the NAS) is the backup *target*; its DR is
DSM's job (see below).

`auspex` runs no backup role either, and unlike scholam it is not stateless: its
Prometheus TSDB is a year of the fleet's monitoring history on a single NVMe with
no RAID, no scrub and no repo. That is accepted rather than overlooked — it is
derived data, so losing it costs dashboards and not recovery — but it is the one
piece of fleet state with no copy anywhere.

**Off-site copy:** three Synology Hyper Backup tasks mirror the on-NAS backups
off-site to a Hetzner storage box over rsync, each a plain true mirror (latest
state only, no version history): the `*-podman-backup` repos on Wednesday 02:00,
the `*-home-backup` repos on Thursday 04:00, and the `/scriptorum/photos` library
on Tuesday 03:00 — each an hour or more after the run it copies. A failed run
alerts by email, so a stalled copy surfaces rather than drifting unnoticed. A lost
NAS is recoverable from it — see [administratum](#administratum-nas).

The tasks reach the box through the `storagebox_gateway` forward on
`rogue-trader`, so it is on the restore path as well as the backup path — see
[administratum](#administratum-nas).

## solar (and any openSUSE podman host)

1. Reinstall openSUSE Tumbleweed. Keep the hostname and the DHCP lease so the
   name and the NFS numeric identity (`common_user_uid: 1026`) still match.
2. As root on the box: `bootstrap/host.sh` (creates the `ansible` account and
   sshd). Either pipe it from GitHub (see the script header) or run a local copy.
3. From the control host, confirm the inventory entry, then run the play —
   installs podman, mounts astropath, deploys the quadlets (volumes are
   auto-created and registered on first container start) and installs the restore
   script:

   ```bash
   make apply PLAY=solar
   ```

4. Once step 3 has converged clean — `podman volume ls` shows the expected
   volumes — restore them over the fresh ones:

   ```bash
   sudo /usr/local/sbin/podman-restore.sh
   ```

   It restores the latest snapshot to a scratch target first, and only once that
   has fully succeeded does it quiesce the quadlet units, swap the restored data
   into each volume (ownership, mode and SELinux label preserved) and restart
   them. A repository that is unreachable or unreadable therefore costs nothing:
   the volumes are untouched and the containers never stop. The
   freshly-initialised data from step 3's first start is replaced wholesale, so
   no app-level reconciliation is needed — the volumes return as last backed up.

   Pass a snapshot ID to restore something other than the newest —
   `sudo /usr/local/sbin/podman-restore.sh <id>`, with IDs from
   `sudo restic -r /nfs/astropath/<host>-podman-backup --password-file
   /etc/restic/password snapshots`. Use it when the latest snapshot is itself
   suspect. If the swap fails part-way the script leaves the containers **down**
   on purpose and keeps the restored copy under `/var/tmp/podman-restore.*`;
   that is a half-restored volume set, so recover it by hand rather than starting
   the units.

5. `solar` also carries a `solar-home-backup` repo. If its `/home` is wanted back,
   restore it by hand as in [scholam](#scholam-control-host) step 5 (restic to a
   scratch target — path mode ships no restore script).

## rogue-trader (Hetzner VM)

The VM is re-imaged from the MicroOS snapshot `packer/` builds, not reinstalled.
Ignition supplies the first-boot identity, so there is no `bootstrap/host.sh`
step. The image carries no console password for `root` or `ansible`, so the
console is not a way in — Hetzner **rescue mode** is.

On the rebuild path the server survives, and so does its firewall — which
carries no inbound 22, while the tunnel dies with the disk. So first merge a
temporary inbound-22 rule into `terraform/firewall-rogue-trader.tf`, scoped to
the workstation's **public egress** address, and let CI apply it; adding it in
the Hetzner console instead is a trap, since the next merge to `main`
auto-applies terraform over the top of it. From zero there is nothing to open
and no server for `data.hcloud_server.rogue_trader` to read, so terraform cannot
plan at all until step 3 has created one.

The host firewall goes the other way. The stock `public` zone ships the `ssh`
service and `roles/firewalld` only ever adds, so the removal that scopes SSH to
the LAN here was made by hand (`02c0de6`) and dies with the disk: the box comes
back accepting SSH from anything that reaches it. That is why the converge
cannot lock itself out at this layer, and why step 6 puts the removal back.

**The rebuild path destroys the disk, and it has been exercised once — on a
throwaway, never on this server.** So step 7 is mandatory, not optional, and step
8 where the raw copy will not start.

1. Pause the reconciler on scholam. It applies `site.yml` every 15 minutes, so
   an unpaused one races the converge below and re-applies the play into a
   half-restored box:

   ```bash
   sudo touch /var/lib/arbites/pause
   ```

   A paused run still fires and exits as a clean success, so neither
   `ArbitesFailed` nor `ArbitesStale` sounds while the host is
   down. Step 9 resumes it.
2. On a **planned** rebuild — the OS move, not recovery from a loss — take the
   state with you first. `podman_backup` runs weekly (Wed 01:00), so step 7
   would otherwise restore a site up to a week stale, and the dump step 8 falls
   back to is only as fresh as the last daily run. On rogue-trader:

   ```bash
   sudo systemctl start wordpress-db-dump.service   # so the fresh dump is in the backup
   sudo systemctl start podman-backup.service
   sudo restic -r /nfs/astropath/rogue-trader-podman-backup \
     --password-file /etc/restic/password snapshots --latest 1
   ```

   Then take a disk snapshot, which makes the rollback one command:
   `hcloud server create-image --type snapshot --description pre-microos
   rogue-trader`. Delete it once the rebuilt box is serving.
3. Re-image the server from the repo root:

   ```bash
   ansible-playbook bootstrap/rogue-trader.yml \
     -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass \
     -e rogue_trader_state=rebuild
   ```

   From zero — no server at all — drop `rogue_trader_state` and pass a
   `rogue_trader_server_type` matching what the box should be; the default is
   the spike's size. Then `make tofu-apply`: it attaches the firewall, and from
   zero it also re-points the A/AAAA records at the new IP.
4. The play does not wait on this path. The rehearsal came back up on its own —
   `hcloud server poweron rogue-trader` if this one does not. Then drop the
   old host keys, which went with the disk, and confirm it is up in one step:
   `ssh-keygen -R <public IPv4>` then `ssh ansible@<public IPv4> true`, which
   also accepts the new key so the converge does not stall on verification.
   `ssh-keygen -R 192.168.3.4` too, once the tunnel is back.
5. Converge over the public address, since the inventory reaches this host at
   its VPN address and the tunnel does not exist yet:

   ```bash
   ansible-playbook playbooks/rogue-trader.yml --vault-password-file .vault_pass \
     -e ansible_host=<public IPv4>
   ```

   This is what places the WireGuard key and brings the tunnel up;
   `make apply PLAY=rogue-trader` works only afterwards.
6. Close the rebuild's openings. Everything here removes the public path, so
   confirm the tunnel carries you first — `ssh ansible@192.168.3.4 true`. The
   temporary inbound-22 rule goes back out through terraform, merged and applied
   by CI like any other change. Then restore the SSH scoping the disk took with
   it, and re-pin the reconciler on the host keys the rebuild replaced:

   ```bash
   # on rogue-trader
   sudo firewall-cmd --permanent --remove-service=ssh
   sudo firewall-cmd --reload
   sudo firewall-cmd --list-services  # http https — the reload makes runtime match
   # on scholam
   sudo ssh-keygen -f /etc/arbites/ssh/known_hosts -R 192.168.3.4
   sudo sh -c 'ssh-keyscan -H 192.168.3.4 >>/etc/arbites/ssh/known_hosts'
   ```

   The reconciler pins each host against that file and never re-seeds it, so
   until this runs every reconcile aborts at the connect — permanently, and
   reading like a machine-in-the-middle rather than a missing step.
7. Once its play has converged, on rogue-trader:
   `sudo /usr/local/sbin/podman-restore.sh` — restores the WordPress and
   database volumes. Until it has run, WordPress is a blank install, so
   `wordpress-cron.service` fails and `WordpressCronFailed` fires; that clears
   with the restore and is not a fault to chase.
8. The database travels as a raw `/var/lib/mysql` copy, which a newer mariadb
   than it was taken on may refuse to start. If it does, recover the database
   from the logical dump instead. Step 7 restored the raw copy into
   `wordpress-db`, so wipe that volume first:

   ```bash
   sudo systemctl stop wordpress-db
   sudo podman volume rm wordpress-db
   sudo systemctl start wordpress-db
   ```

   Once it is healthy (`podman healthcheck run wordpress-db`), load
   `wordpress-db-dump`'s engine-portable `wordpress.sql` — the wordpress role's
   `wp-db-dump` runs on a daily timer, so this fallback restores the last
   completed dump, not a point-in-time state, and loses up to a day's writes
   (more if the dump had been failing) — into it as root, under the same mariadb the role pins (`wordpress_db_image`), so the load runs on a compatible engine:

   ```bash
   podman run --rm --network caddy --env-file /etc/wordpress/db.env \
     --volume wordpress-db-dump:/dump:ro docker.io/library/mariadb:12.3.2@sha256:c237fd50cc48d6f2b87c4ca66d52f3b5eef7271b3bea7aee586c0be19d5b460d \
     sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -h wordpress-db -uroot < /dump/wordpress.sql'
   ```

   Finally, restart the WordPress container, which the database stop took down
   with it (`Requires=`):

   ```bash
   sudo systemctl start wordpress
   ```

9. Resume the reconciler on scholam: `sudo rm /var/lib/arbites/pause`.
   Confirm the next fire applies rather than assuming it did —
   `/var/lib/arbites/last-applied-sha` should reach `main`'s HEAD.
10. `rogue-trader` also carries a `rogue-trader-home-backup` repo (its `/home` is
   minimal — service-account skeletons only); restore it by hand as in
   [scholam](#scholam-control-host) step 5 if wanted.

## scholam (control host)

`scholam` is `this_host`: it manages itself, and its only podman workload
(`node_exporter`) is stateless, so no podman volumes need restoring — but its
`/home` does, from the `scholam-home-backup` repo. Recovery is bootstrap plus its
play, run locally, then the home restore.

1. Reinstall openSUSE Tumbleweed (keep the hostname).
2. As root: `bootstrap/host.sh`.
3. Restore the control-host workspace: clone the repo, drop `.vault_pass` back in
   from the password manager, build the venv (see Prerequisites), then
   `make hooks`. Replace `arbites`'s two secrets too (see its README) —
   its guard fails the apply below without them.
4. Apply its play locally (it targets `this_host` at loopback):

   ```bash
   make apply PLAY=scholam
   ```

5. Step 4 mounted astropath, so the home repo is reachable. There is no restore
   script (that is podman-only); restore `/home` by hand to a scratch target — so
   it does not overwrite the workspace you are recovering from — then copy back
   what step 3 did not already rebuild:

   ```bash
   restic --password-file /etc/restic/password \
     --repo /nfs/astropath/scholam-home-backup \
     restore latest --target /var/tmp/home-restore
   ```

6. To make it the molecule runner again, locally on scholam:
   `ansible-playbook bootstrap/incus.yml --ask-become-pass`.

## auspex (Raspberry Pi 5)

No NFS mount and no backup role, so nothing here is restored from a repo. What it
does hold is the fleet's entire monitoring history: Prometheus's TSDB, a year of
it, on the NVMe mounted at `/var/lib/containers`. There is no copy of that
anywhere — accepted, because it is derived data whose loss costs dashboards
rather than recovery, but it means the card and the drive fail differently.

**A card rebuild does not touch the NVMe.** Reflashing the SD card and re-applying
the play remounts the existing store, so the TSDB, Alertmanager's silences and
every other named volume survive the procedure below. Losing the NVMe itself is
what loses the history, and nothing restores it — fit a replacement, partition it
`LABEL=containers`, and the fleet starts recording again from empty.

1. Write Raspberry Pi OS Lite arm64 to a fresh card, then put
   `bootstrap/auspex-user-data.yaml` on the card's FAT partition as `user-data`,
   with a fresh `instance-id` in the `meta-data` beside it — `bootstrap/README.md`
   has the procedure and the trap, which is that letting Raspberry Pi Imager apply
   its own customisation silently overwrites the seed.
2. Boot it. `ssh ansible@auspex` answering, with `id jonny` reporting uid 1026 and
   gid 100, is the signal cloud-init consumed the seed rather than its own default.
3. Apply its play:

   ```bash
   make apply PLAY=auspex
   ```

4. Re-seed the host key, or the reconcile stops fleet-wide. A re-image generates a
   new one, and the entry in `arbites`'s `known_hosts` then MISMATCHES rather than
   merely missing — which `arbites` treats as the machine-in-the-middle it exists to
   refuse. On scholam as root:

   ```bash
   ssh-keygen -f /etc/arbites/ssh/known_hosts -R auspex
   ssh-keyscan -H auspex >>/etc/arbites/ssh/known_hosts
   ```

Anything deliberately silenced before a loss that took the NVMe with it starts
firing again after step 3. The outage itself is a hole in the history rather than
a fault to repair: nothing buffers samples on the fleet's behalf, so what was not
scraped is simply gone.

While auspex is down the fleet is unmonitored rather than noisily broken — every
rule matches an empty vector instead of firing, because the process that would
evaluate them is the one that stopped. Nothing on the fleet can say so, and
nothing needs to: no evaluation means no `Watchdog`, no heartbeat, and
healthchecks.io pages on the silence. That deadman is the whole signal, so treat
a missed beat as this host until proven otherwise.

## administratum (NAS)

**Not in this repo at all any more.** It left the inventory when its last Docker
workload did, so there is no play to reapply and no `make apply` step here — the
NFS server, the exports and the shares are DSM's own configuration, restored with
DSM. It is still the fleet's backup *target*, and still the thing every other
host's recovery depends on.

DSM's native SMART and RAID monitoring emails the operator on any disk or array
fault — the array-health signal, since the NAS runs no `node_exporter` by design
— so degradation is caught before it becomes a recovery event. The fleet's own
signal that the NAS is gone is the blackbox `tcp_connect` probe of its NFS port,
raising `ProbeDown`; it holds no monitoring data, so losing it is no longer a
monitoring outage.

Recover the appliance with DSM (Hyper Backup / the RAID), then re-export the
shares the fleet mounts — `solar` and `scholam` name it as their NFS server, and
those mounts are what the arr stack and the backups run on.

**Temporary, delete after 2026-08-21:** `/volume2/astropath/prometheus` still
holds the pre-cutover TSDB, kept as the rollback for the move to auspex. Its
containers are stopped and Docker is uninstalled, so it is inert data — but this
is the only place left that records it exists, the NAS having left the inventory.
Rolling back would mean reinstalling Container Manager and `docker compose up -d`
there. Once the migrated history is trusted, `rm -rf /volume2/astropath/prometheus`
and delete this paragraph.

The `*-podman-backup` and `*-home-backup` restic repos and the `/scriptorum/photos`
library are also mirrored off-site to a Hetzner storage box by three Synology Hyper
Backup tasks (podman Wednesday 02:00, home Thursday 04:00, photos Tuesday 03:00).

**Restore the path before the data.** The box refuses every source outside
Hetzner, and a rebuilt NAS is outside it, so a restored Hyper Backup task pointed
straight at the box will fail. First get one of the two routes back:

- `rogue-trader` up with `storagebox_gateway` running, and the tasks' destination
  set to `192.168.3.4` port 23. This repo does not hold that destination — it
  exists only in DSM's Hyper Backup config, so a NAS rebuilt without that config
  needs it set by hand; or
- a throwaway Hetzner VM running the same forward, if rogue-trader is gone; or
- External Reachability re-enabled in the Hetzner Console (Prerequisites), the
  escape hatch when there is no Hetzner host at all. Turn it back off afterwards.

Either way the box's SSH credential is needed too, and it lives only in DSM's
Hyper Backup config (see [`secret-rotation.md`](secret-rotation.md)) — if that
went with the NAS, reset the sub-account password in the Console.

Then restore those tasks' sets to return the repos to
`/volume2/astropath/` and the photo library to its share; solar's, scholam's, and
rogue-trader's backups can then be restored as normal. The laptop's `time-machine`
SMB share on `scriptorum` is not mirrored off-site, so it is not recovered — the
laptop simply resumes Time Machine onto the rebuilt share.

## Branch protection and merge methods

Protection on `main` is a GitHub ruleset — repository config, not part of the
git tree — so a settings loss does not restore it. The checks are deliberately
loose: a branch need not be up to date to merge, for the reasons in
`.github/workflows/README.md`. Recreate `protect main` (requires the
`pre-commit`, `secret-scan`, `molecule-gate`, `terraform-gate`, and `site-gate`
checks, plus a PR before any merge to `main`; blocks force-push and deletion)
from the repo root:

```bash
gh api --method POST \
  "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/rulesets" \
  --input - <<'JSON'
{
  "name": "protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": { "required_approving_review_count": 0, "allowed_merge_methods": ["merge"] } },
    { "type": "required_status_checks",
      "parameters": { "strict_required_status_checks_policy": false, "required_status_checks": [
        { "context": "pre-commit" }, { "context": "secret-scan" }, { "context": "molecule-gate" },
        { "context": "terraform-gate" }, { "context": "site-gate" }
      ] } }
  ]
}
JSON
```

Restore the repository merge settings too — the ruleset does not carry them, and
a fresh repository enables all three merge methods with auto-merge off:

```bash
gh api --method PATCH \
  "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
  -F allow_squash_merge=false -F allow_rebase_merge=false \
  -F allow_auto_merge=true
```

Squash on, or auto-merge off, each silently degrades Renovate's automerge to one
PR per run rather than breaking it; `renovate.json`'s `description` has the
mechanism.
