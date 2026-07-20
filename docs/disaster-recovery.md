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
- SSH (or, for rogue-trader, WireGuard) reach to the host being recovered.

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

   ```
   make apply PLAY=solar
   ```

4. Once step 3 has converged clean — `podman volume ls` shows the expected
   volumes — restore them over the fresh ones:

   ```
   sudo /usr/local/sbin/podman-restore.sh
   ```

   It quiesces the quadlet units, empties each volume, restores the latest
   snapshot (ownership and mode preserved), and restarts the units; it aborts
   before touching anything if the repo holds no snapshot to restore. The
   freshly-initialised data from step 3's first start is replaced wholesale, so
   no app-level reconciliation is needed — the volumes return as last backed up.

5. `solar` also carries a `solar-home-backup` repo. If its `/home` is wanted back,
   restore it by hand as in [scholam](#scholam-control-host) step 5 (restic to a
   scratch target — path mode ships no restore script).

## rogue-trader (Hetzner VM)

The VM is provisioned by cloud-init, not a reinstall. SSH is not exposed
publicly, so if the WireGuard tunnel can't be brought up, the Hetzner web console
is the only way in.

1. Re-provision from the repo root (recreates the server and brings up the
   WireGuard tunnel at first boot):

   ```
   ansible-playbook bootstrap/rogue-trader.yml \
     -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass
   ```

   The play waits for it on the VPN.
2. As root on the box (over the VPN): `bootstrap/host.sh` — cloud-init installs
   the tunnel and python but not the `ansible` account, so this still runs.
3. From the control host: `make apply PLAY=rogue-trader`.
4. Once its play has converged, on rogue-trader:
   `sudo /usr/local/sbin/podman-restore.sh` — restores the WordPress and
   database volumes.
5. The database travels as a raw `/var/lib/mysql` copy, which a newer mariadb
   than it was taken on may refuse to start. If it does, recover the database
   from the logical dump instead. Step 4 restored the raw copy into
   `wordpress-db`, so wipe that volume first:

   ```
   sudo systemctl stop wordpress-db
   sudo podman volume rm wordpress-db
   sudo systemctl start wordpress-db
   ```

   Once it is healthy (`podman healthcheck run wordpress-db`), load
   `wordpress-db-dump`'s engine-portable `wordpress.sql` — the wordpress role's
   `wp-db-dump` runs on a daily timer, so this fallback restores the last
   completed dump, not a point-in-time state, and loses up to a day's writes
   (more if the dump had been failing) — into it as root, under the same mariadb the role pins (`wordpress_db_image`), so the load runs on a compatible engine:

   ```
   podman run --rm --network caddy --env-file /etc/wordpress/wordpress.env \
     --volume wordpress-db-dump:/dump:ro docker.io/library/mariadb:12.3.2@sha256:628f228f0fd5913a220438693576b29b6fe4dc1fa0a1298c0e98579fae28635f \
     sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -h wordpress-db -uroot < /dump/wordpress.sql'
   ```

   Finally, restart the WordPress container, which the database stop took down
   with it (`Requires=`):

   ```
   sudo systemctl start wordpress
   ```

6. `rogue-trader` also carries a `rogue-trader-home-backup` repo (its `/home` is
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

   ```
   make apply PLAY=scholam
   ```

5. Step 4 mounted astropath, so the home repo is reachable. There is no restore
   script (that is podman-only); restore `/home` by hand to a scratch target — so
   it does not overwrite the workspace you are recovering from — then copy back
   what step 3 did not already rebuild:

   ```
   restic --insecure-no-password --repo /nfs/astropath/scholam-home-backup \
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

```
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

```
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
