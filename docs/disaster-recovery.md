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

`podman_backup` runs on `solar` and `rogue-trader` only, writing a per-host
restic repo to `/nfs/astropath/<hostname>-podman-backup` on the NAS. The repo
holds every podman named volume — so all container state (databases, app config,
Plex library and history, the WordPress site) travels in it. Media on the NFS
shares is not in the repo; it lives on the NAS and is the NAS's own concern.

`scholam`'s only podman workload is `node_exporter`, which is stateless, so it
has no repo — its state is the repo plus `.vault_pass`. `administratum` (the NAS)
is the backup *target*; its DR is DSM's job (see below).

**Single point of failure:** every restic repo lives on `administratum`. Lose the
NAS and you lose all podman backups with it.

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
   `wordpress-db-dump`'s engine-portable `wordpress.sql` (written daily by the
   wordpress role's `wp-db-dump`) into it as root:

   ```
   podman run --rm --network caddy --env-file /etc/wordpress/wordpress.env \
     --volume wordpress-db-dump:/dump:ro docker.io/library/mariadb \
     sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -h wordpress-db -uroot < /dump/wordpress.sql'
   ```

   Finally, restart the WordPress container, which the database stop took down
   with it (`Requires=`):

   ```
   sudo systemctl start wordpress
   ```

## scholam (control host)

`scholam` is `this_host`: it manages itself, and its only podman workload
(`node_exporter`) is stateless, so there is nothing in a restic repo to restore.
Recovery is bootstrap plus its play, run locally.

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

5. To make it the molecule runner again, locally on scholam:
   `ansible-playbook bootstrap/incus.yml --ask-become-pass`.

## administratum (NAS)

Out of this repo's recovery flow — it is the backup target, not a managed
openSUSE host, and it has no podman repo. Recover the appliance with DSM (Hyper
Backup / the RAID), which also returns Prometheus's TSDB (a local bind mount at
`/volume2/astropath/prometheus/data`). Then redeploy the compose project:

```
make apply PLAY=administratum
```

Losing the NAS also loses every host's restic repo, so a NAS rebuild is the one
case where solar's and rogue-trader's podman volumes cannot be restored.
