# Disaster recovery

Bringing a lost host back: re-bootstrap it, run its play, restore its podman
volumes. The play rebuilds everything declarative (packages, quadlets, config);
the restore returns the stateful volume data the backup holds.

## Prerequisites

Recovery is driven from a control host with:

- The repo (public, on GitHub) — clone it.
- `.vault_pass` — gitignored, so restore it from the password manager. It is the
  only secret not in git.
- The venv: `python -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`.
- SSH reach to the host being recovered — over the LAN, or over WireGuard for a
  rogue-trader that still has its tunnel. A rebuilt rogue-trader has neither
  until step 3, so it is reached at its public address instead.

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

**Off-site copy:** three Synology Hyper Backup tasks mirror the on-NAS backups
off-site to a Hetzner storage box over rsync, each a plain true mirror (latest
state only, no version history): the `*-podman-backup` repos on Wednesday 02:00,
the `*-home-backup` repos on Thursday 04:00, and the `/scriptorum/photos` library
on Tuesday 03:00 — each an hour or more after the run it copies. A failed run
alerts by email, so a stalled copy surfaces rather than drifting unnoticed. A lost
NAS is recoverable from it — see [administratum](#administratum-nas).

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
plan at all until step 2 has created one.

The host firewall goes the other way. The stock `public` zone ships the `ssh`
service and `roles/firewalld` only ever adds, so the removal that scopes SSH to
the LAN here was made by hand (`02c0de6`) and dies with the disk: the box comes
back accepting SSH from anything that reaches it. That is why the converge
cannot lock itself out at this layer, and why step 5 puts the removal back.

**The rebuild path is unexercised through this play, and it destroys the disk**
— step 6 is mandatory, not optional, and step 7 where the raw copy will not
start.

1. Pause the reconciler on scholam. It applies `site.yml` every 15 minutes, so
   an unpaused one races the converge below and re-applies the play into a
   half-restored box:

   ```bash
   sudo touch /var/lib/gitops-reconcile/pause
   ```

   A paused run still fires and exits as a clean success, so neither
   `GitopsReconcileFailed` nor `GitopsReconcileStale` sounds while the host is
   down. Step 8 resumes it.
2. Re-image the server from the repo root:

   ```bash
   ansible-playbook bootstrap/rogue-trader.yml \
     -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass \
     -e rogue_trader_state=rebuild
   ```

   From zero — no server at all — drop `rogue_trader_state` and pass a
   `rogue_trader_server_type` matching what the box should be; the default is
   the spike's size. Then `make tofu-apply`: it attaches the firewall, and from
   zero it also re-points the A/AAAA records at the new IP.
3. The play does not wait on this path, and a rebuild does not power the box on
   — `hcloud server poweron rogue-trader` if it comes back off. Then drop the
   old host keys, which went with the disk, and confirm it is up in one step:
   `ssh-keygen -R <public IPv4>` then `ssh ansible@<public IPv4> true`, which
   also accepts the new key so the converge does not stall on verification.
   `ssh-keygen -R 192.168.3.3` too, once the tunnel is back.
4. Converge over the public address, since the inventory reaches this host at
   its VPN address and the tunnel does not exist yet:

   ```bash
   ansible-playbook playbooks/rogue-trader.yml --vault-password-file .vault_pass \
     -e ansible_host=<public IPv4>
   ```

   This is what places the WireGuard key and brings the tunnel up;
   `make apply PLAY=rogue-trader` works only afterwards.
5. Close the rebuild's openings. Everything here removes the public path, so
   confirm the tunnel carries you first — `ssh ansible@192.168.3.3 true`. The
   temporary inbound-22 rule goes back out through terraform, merged and applied
   by CI like any other change. Then restore the SSH scoping the disk took with
   it, and re-pin the reconciler on the host keys the rebuild replaced:

   ```bash
   # on rogue-trader
   sudo firewall-cmd --permanent --remove-service=ssh
   sudo firewall-cmd --reload
   sudo firewall-cmd --list-services  # http https — the reload makes runtime match
   # on scholam
   sudo ssh-keygen -f /etc/gitops-reconcile/ssh/known_hosts -R 192.168.3.3
   sudo sh -c 'ssh-keyscan -H 192.168.3.3 >>/etc/gitops-reconcile/ssh/known_hosts'
   ```

   The reconciler pins each host against that file and never re-seeds it, so
   until this runs every reconcile aborts at the connect — permanently, and
   reading like a machine-in-the-middle rather than a missing step.
6. Once its play has converged, on rogue-trader:
   `sudo /usr/local/sbin/podman-restore.sh` — restores the WordPress and
   database volumes. Until it has run, WordPress is a blank install, so
   `wordpress-cron.service` fails and `WordpressCronFailed` fires; that clears
   with the restore and is not a fault to chase.
7. The database travels as a raw `/var/lib/mysql` copy, which a newer mariadb
   than it was taken on may refuse to start. If it does, recover the database
   from the logical dump instead. Step 4 restored the raw copy into
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
     --volume wordpress-db-dump:/dump:ro docker.io/library/mariadb:12.3.2@sha256:628f228f0fd5913a220438693576b29b6fe4dc1fa0a1298c0e98579fae28635f \
     sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -h wordpress-db -uroot < /dump/wordpress.sql'
   ```

   Finally, restart the WordPress container, which the database stop took down
   with it (`Requires=`):

   ```bash
   sudo systemctl start wordpress
   ```

8. Resume the reconciler on scholam: `sudo rm /var/lib/gitops-reconcile/pause`.
   Confirm the next fire applies rather than assuming it did —
   `/var/lib/gitops-reconcile/last-applied-sha` should reach `main`'s HEAD.
9. `rogue-trader` also carries a `rogue-trader-home-backup` repo (its `/home` is
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
   `make hooks`. Replace `gitops_reconcile`'s two secrets too (see its README) —
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

## administratum (NAS)

Out of this repo's recovery flow — it is the backup target, not a managed
openSUSE host, and it has no podman repo. DSM's native SMART and RAID monitoring
emails the operator on any disk or array fault — the array-health signal, since
the NAS runs no `node_exporter` by design — so degradation is caught before it
becomes a recovery event. Recover the appliance with DSM (Hyper Backup / the
RAID), which also returns Prometheus's TSDB (a local bind mount at
`/volume2/astropath/prometheus/data`; blackbox_exporter is stateless). Then
redeploy the compose projects:

```bash
make apply PLAY=administratum
```

The `*-podman-backup` and `*-home-backup` restic repos and the `/scriptorum/photos`
library are also mirrored off-site to a Hetzner storage box by three Synology Hyper
Backup tasks (podman Wednesday 02:00, home Thursday 04:00, photos Tuesday 03:00).
After rebuilding the NAS, restore those tasks' sets to return the repos to
`/volume2/astropath/` and the photo library to its share; solar's, scholam's, and
rogue-trader's backups can then be restored as normal. The laptop's `time-machine`
SMB share on `scriptorum` is not mirrored off-site, so it is not recovered — the
laptop simply resumes Time Machine onto the rebuilt share.

## Branch protection

Protection on `main` is a GitHub ruleset — repository config, not part of the
git tree — so a settings loss does not restore it. Recreate `protect main`
(requires the `pre-commit`, `secret-scan`, `molecule-gate`, `terraform-gate`, and
`site-gate` checks, branches up to date, plus a PR before any merge to `main`;
blocks force-push and deletion) from the repo root:

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
      "parameters": { "strict_required_status_checks_policy": true, "required_status_checks": [
        { "context": "pre-commit" }, { "context": "secret-scan" }, { "context": "molecule-gate" },
        { "context": "terraform-gate" }, { "context": "site-gate" }
      ] } }
  ]
}
JSON
```
