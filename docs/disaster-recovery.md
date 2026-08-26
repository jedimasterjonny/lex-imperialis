# Disaster recovery

Bringing a lost host back: re-bootstrap it, run its play, restore its podman
volumes. The play rebuilds everything declarative (packages, quadlets, config);
the restore returns the stateful volume data the backup holds.

## Prerequisites

Recovery is driven from a control host with:

- The repo (public, on GitHub) — clone it.
- `.vault_pass` — gitignored, so restore it from the password manager. It
  unlocks every other secret in the repo.
- The venv: `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`.
- The operator's fleet SSH key (`~jonny/.ssh/id_ed25519`) — the `ansible`
  account is key-only and its `authorized_keys` is exclusive, so nothing
  connects without it and a hand-made replacement is stripped by the next
  converge. Restore it from the password manager, or out of
  `scholam-home-backup` (see scholam step 4).
- SSH reach to the host being recovered — over the LAN, or over WireGuard for a
  rogue-trader that still has its tunnel. A rebuilt rogue-trader has neither
  until step 5, so it is reached at its public address instead.
- The Hetzner Console login for the **storage box project** (password manager;
  a separate project from emmas-edit, and in neither the vault nor terraform).
  Needed to recover the off-site copy: it is the way back to both External
  Reachability and the box's sub-account password.
- The NAS volume encryption key — both `/volume1` and `/volume2` are LUKS2,
  auto-unlocked from a key store on DSM's system partition. A RAID rebuild with
  DSM intact unlocks itself and a from-scratch Hyper Backup restore makes a
  fresh volume, but intact disks under a reinstalled DSM — or moved to a new
  chassis — need the key. It is in no Hyper Backup task and no DSM config
  backup, so keep it in the password manager.
- `hcloud-cli`, for the two optional Hetzner commands in the rogue-trader
  section (`zypper in hcloud-cli`, then
  `export HCLOUD_TOKEN=$(bin/vault-var.sh hcloud_token_emmas_edit)`) — or do
  both from the Console instead.

`scholam` is the usual control host. If `scholam` itself is lost, recover it
first (below), or drive the others from any machine meeting the above.

## What is and isn't backed up

The full backup architecture — all six layers — is in [`backups.md`](backups.md);
this is the recovery-relevant summary.

`podman_backup` runs on `solar` and `rogue-trader` only, writing a per-host
restic repo to `/nfs/astropath/<hostname>-podman-backup` on the NAS. The repo
holds every podman named volume — so all container state (databases, app config,
Plex library and history, the WordPress site) travels in it. Media on the NFS
shares is not in the repo; it lives on the NAS and is the NAS's own concern.

`home_backup` runs on `solar`, `scholam`, and `rogue-trader`, writing a per-host
restic repo to `/nfs/astropath/<hostname>-home-backup` holding that host's `/home`
minus re-acquirable churn and `.vault_pass` (see [`backups.md`](backups.md)).
It shares the `restic_backup` engine with `podman_backup`, and both sets of repos
sit under `astropath`.

`scholam`'s only podman workload is `node_exporter`, which is stateless, so it has
no podman repo; its recoverable state is the git repo, `.vault_pass`, and its
`/home` restic repo. `administratum` (the NAS) is the backup *target*; its DR is
DSM's job (see below).

`auspex` runs no backup role either, and unlike scholam it is not stateless: its
Prometheus TSDB is set to retain a year of the fleet's monitoring history on a
single NVMe with no RAID, no scrub and no repo. That is accepted rather than
overlooked — it is derived data, so losing it costs dashboards and not recovery —
but that NVMe, which carries Alertmanager's state beside the TSDB, is the one part
of the fleet with no copy anywhere.

**Off-site copy:** three Synology Hyper Backup tasks mirror the on-NAS backups
off-site to a Hetzner storage box over rsync, each a plain true mirror (latest
state only, no version history): the `*-podman-backup` repos on Wednesday 02:00,
the `*-home-backup` repos on Thursday 04:00, and the `/scriptorum/photos` library
on Tuesday 03:00 — each an hour or more after the run it copies. A failed run
alerts by email, but a task that silently stops copying a folder does not fail:
it finishes, reports success and mails nothing. The watch on that is the
`offsite_mirror` probe on `auspex` — `OffsiteMirrorCoverageMissing` fires on a
declared folder absent from a task's manifest, alongside `OffsiteMirrorTaskFailed`,
`TaskOverdue`, `TaskUnverified` and the `OffsiteMirrorProbe*` pair. Check those
before trusting the off-site copy in a recovery, and judge coverage against a run
that postdates any change to a task: the manifest only refreshes when it next runs.
A lost NAS is recoverable from it — see [administratum](#administratum-nas).

The tasks reach the box through the `storagebox_gateway` forward on
`rogue-trader`, so it is on the restore path as well as the backup path — see
[administratum](#administratum-nas).

## solar (and any openSUSE podman host)

1. Reinstall openSUSE Tumbleweed. Keep the hostname so the
   `<hostname>-podman-backup` repo path still resolves, and keep the DHCP lease
   because the NAS exports are per-client-IP — a rebuilt solar on a new address
   is refused the mount, failing the `nfs` role and blocking steps 3-5.
2. As root on the box: `bootstrap/host.sh` (creates the `ansible` account and
   sshd). Either pipe it from GitHub (see the script header) or run a local copy.
3. The reinstall gave solar new host keys, and two files pin the old ones. Drop
   both before converging — the second matters more than the first, because
   `site.yml` imports `solar.yml` first, so a stale pin there aborts every fleet
   reconcile at the connect until it is re-seeded:

   ```bash
   ssh-keygen -R solar                      # your own known_hosts
   # on scholam, as root
   sudo ssh-keygen -f /etc/arbites/ssh/known_hosts -R solar
   sudo sh -c 'ssh-keyscan -H solar >>/etc/arbites/ssh/known_hosts'
   ```

   Then, from the control host, confirm the inventory entry and run the play —
   installs podman, mounts astropath, deploys the quadlets (volumes are
   auto-created and registered on first container start) and installs the restore
   script:

   ```bash
   make apply PLAY=solar
   ```

4. Once step 3 has converged clean — `sudo podman volume ls` shows the expected
   volumes — pause the reconciler and hold the backup timer, then restore over
   the fresh ones. An unpaused reconciler re-applies `site.yml` and restarts
   these units mid-swap; an unmasked timer can snapshot the freshly-initialised
   state as `latest`, which is what a later restore would then read back:

   ```bash
   sudo touch /var/lib/arbites/pause
   sudo systemctl mask --now podman-backup.timer
   sudo /usr/local/sbin/podman-restore.sh
   ```

   It restores the latest snapshot to a scratch target first, then stops and
   asks: run from a terminal it prints how many of this host's volumes it is
   about to swap and waits for a `y`, and does nothing without one. Only then
   does it quiesce the quadlet units, swap the restored data into each volume
   (ownership, mode and SELinux label preserved) and restart them. A repository
   that is unreachable or unreadable therefore costs nothing: the volumes are
   untouched and the containers never stop. The freshly-initialised data from
   step 3's first start is replaced wholesale, so no app-level reconciliation is
   needed — the volumes return as last backed up.

   Run it under `tmux`. The prompt comes after a read that can take a while, and
   a session dropped at it takes the scratch copy with it — the whole read again
   for nothing.

   The swap goes onto volumes the host already has, so one the snapshot holds and
   this host does not — a decommissioned workload's, and solar's snapshots still
   carry `alertmanager-data` — is named above the prompt and **skipped**: nothing
   in the script creates a volume. To take one back, `sudo podman volume create
   <name>` and run the restore again, which re-reads the snapshot in full. With
   stdin not a terminal there is no prompt and nobody to read that warning, so
   the run stops there instead — after the read, before the swap — rather than
   swapping the rest and exiting 0 having dropped it.

   Pass a snapshot ID to restore something other than the newest —
   `sudo /usr/local/sbin/podman-restore.sh <id>`, with IDs from
   `sudo restic -r /nfs/astropath/<host>-podman-backup --password-file
   /etc/restic/password snapshots`. Use it when the latest snapshot is itself
   suspect. If the swap fails part-way the script leaves the containers **down**
   on purpose and keeps the restored copy under `/var/tmp/podman-restore.*`;
   that is a half-restored volume set, so recover it by hand rather than starting
   the units. That hold is indefinite and the reconciler does not respect it, so
   keep the pause from step 4 in place while investigating — otherwise the next
   merge to `main` starts these units on the half-restored volumes.

5. Once the restore is verified, lift the holds:

   ```bash
   sudo systemctl unmask podman-backup.timer
   sudo systemctl start podman-backup.timer
   sudo rm /var/lib/arbites/pause
   ```

6. `solar` also carries a `solar-home-backup` repo. If its `/home` is wanted back,
   restore it by hand as in [scholam](#scholam-control-host) step 6 (restic to a
   scratch target — path mode ships no restore script).

## rogue-trader (Hetzner VM)

The VM is re-imaged from the MicroOS snapshot `packer/` builds, not reinstalled.
Ignition supplies the first-boot identity, so there is no `bootstrap/host.sh`
step. The image carries no console password for `root` or `ansible`, so there is no
console *login* — Hetzner **rescue mode** is the way in.

On the rebuild path the server survives, and so does its firewall — which
carries no inbound 22, while the tunnel dies with the disk. So first merge a
temporary inbound-22 rule into `terraform/firewall-rogue-trader.tf`, scoped to
the workstation's **public egress** address, and let CI apply it; adding it in
the Hetzner console instead is a trap, since the next merge to `main`
auto-applies terraform over the top of it. From zero there is nothing to open
and no server for `data.hcloud_server.rogue_trader` to read, so terraform cannot
plan the rule until step 3 has created one — merge it then, before the apply,
not never. The rule is deferred on that path, not unneeded.

The host firewall goes the other way. The stock `public` zone ships the `ssh`
service and `roles/firewalld` only ever adds, so the removal that scopes SSH to
the LAN here was made by hand (`02c0de6`) and dies with the disk: the box comes
back accepting SSH from anything that reaches it. That is why the converge
cannot lock itself out at this layer, and why step 6 puts the removal back.

**The rebuild path destroys the disk, and it has been exercised once — on a
throwaway, never on this server.** So step 7 is mandatory, not optional, and step
8 where the raw copy will not start.

1. Pause the reconciler on scholam. It fires every 15 minutes and applies
   `site.yml` whenever `main` has advanced — which Renovate does unattended at
   any hour — so an unpaused one races the converge below and re-applies the
   play into a half-restored box:

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
   the spike's size.

   Then merge the temporary inbound-22 rule the preamble deferred — it is
   plannable now that a server exists — and let CI apply it *before* you run
   `make tofu-apply`. Without it the firewall attaches with no inbound 22 and
   steps 4 and 5 cannot reach the box: the tunnel does not exist until step 5,
   and rescue mode is on the same closed port. Then `make tofu-apply`: it
   attaches the firewall, and from zero it also re-points the A/AAAA records at
   the new IP. That runs locally, so it needs `tofu`, `gcloud`, a current
   `gcloud auth application-default login` and a prior `tofu -chdir=terraform
   init`; see [`terraform/README.md`](../terraform/README.md).
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
   sudo firewall-cmd --list-services  # dhcpv6-client http https — the reload makes runtime match
   # on scholam
   sudo ssh-keygen -f /etc/arbites/ssh/known_hosts -R 192.168.3.4
   sudo sh -c 'ssh-keyscan -H 192.168.3.4 >>/etc/arbites/ssh/known_hosts'
   ```

   The reconciler pins each host against that file and never re-seeds it, so
   until this runs every reconcile aborts at the connect — permanently, and
   reading like a machine-in-the-middle rather than a missing step.
7. Once its play has converged, restore on rogue-trader. A rebuild has no
   `wordpress-db-dump` volume — nothing creates it but the first dump run, and
   its timer will not have fired — so create it first, or the restore names it
   absent and skips it and step 8's fallback has nothing to load. Hold the
   backup timer for the same reason as solar step 4:

   ```bash
   sudo systemctl mask --now podman-backup.timer
   sudo podman volume create wordpress-db-dump
   sudo /usr/local/sbin/podman-restore.sh
   ```

   That restores the WordPress and database volumes. Until it has run, WordPress
   is a blank install, so `wordpress-cron.service` fails and
   `WordpressCronFailed` fires; that clears with the restore and is not a fault
   to chase.
8. The database travels as a raw `/var/lib/mysql` copy, which a newer mariadb
   than it was taken on may refuse to start. If it does, recover the database
   from the logical dump instead. Quiesce the timers first —
   `wordpress-cron.service` carries `Requires=wordpress.service`, which requires
   the database, so a fire during the swap or the load brings WordPress up on
   the empty database and caches that "not installed" state in valkey:

   ```bash
   sudo systemctl disable --now wordpress-cron.timer wordpress-db-dump.timer
   ```

   Step 7 restored the raw copy into `wordpress-db`, so wipe that volume first:

   ```bash
   sudo systemctl stop wordpress-db
   sudo podman volume rm wordpress-db
   sudo systemctl start wordpress-db
   ```

   Once it is healthy (`sudo podman healthcheck run wordpress-db`), load
   `wordpress-db-dump`'s engine-portable `wordpress.sql` — the wordpress role's
   `wp-db-dump` runs on a daily timer, so this fallback restores the last
   completed dump, not a point-in-time state, and loses up to a day's writes
   (more if the dump had been failing) — into it as root, under the same mariadb the role pins (`wordpress_db_image`), so the load runs on a compatible engine:

   ```bash
   sudo podman run --rm --network caddy --env-file /etc/wordpress/db.env \
     --volume wordpress-db-dump:/dump:ro docker.io/library/mariadb:12.3.3@sha256:dd9b303aed4f4890ed09f766d8ca9ddfd176c0c6f6267feff53b3192ec65a979 \
     sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -h wordpress-db -uroot < /dump/wordpress.sql'
   ```

   Finally, restart the WordPress stack — the database stop took it down with it
   (`Requires=`) — flush the cache that may hold the empty-database state, and
   put the timers back:

   ```bash
   sudo systemctl restart wordpress wordpress-valkey
   sudo systemctl enable --now wordpress-cron.timer wordpress-db-dump.timer
   sudo systemctl unmask podman-backup.timer
   sudo systemctl start podman-backup.timer
   ```

9. Resume the reconciler on scholam: `sudo rm /var/lib/arbites/pause`. Confirm
   the next fire *applied* — `journalctl -u arbites.service` should show an
   `applying <sha>` line, not `origin/main unchanged`. `last-applied-sha`
   reaching HEAD is necessary, not sufficient: on a static `main` the
   short-circuit satisfies it without connecting to anything, so a botched
   step 6 re-pin would still read as healthy.
10. `rogue-trader` also carries a `rogue-trader-home-backup` repo (its `/home` is
   minimal — service-account skeletons only); restore it by hand as in
   [scholam](#scholam-control-host) step 6 if wanted.

## scholam (control host)

`scholam` is `this_host`: it manages itself, and its only podman workload
(`node_exporter`) is stateless, so no podman volumes need restoring — but its
`/home` does, from the `scholam-home-backup` repo. Recovery is bootstrap plus its
play, run locally, then the home restore.

1. Reinstall openSUSE Tumbleweed. Keep the hostname, and create the owner
   account as uid 1026 with primary group `users` — the fleet pins
   `common_user_uid: 1026`, and `usermod -u` on a logged-in account is refused,
   so an installer default of 1000 halts step 5 in its first role and needs an
   offline root console to fix.
2. As root: `bootstrap/host.sh`.
3. Restore the control-host workspace: clone the repo, drop `.vault_pass` back in
   from the password manager, build the venv (see Prerequisites), then
   `make hooks`. Replace `arbites`'s two secrets and re-seed
   `/etc/arbites/ssh/known_hosts` over the trusted LAN, including scholam's own
   loopback (see its README) — its guard fails the apply below without all
   three. If you generate a fresh arbites key rather than restoring the old one,
   add its public half to `inventory/group_vars/all/authorized_keys.yml` and
   apply it to the other hosts *before* step 5: that step arms the timer, and
   the declared list is exclusive, so an unadvertised key fails at every connect.
4. Restore the operator's SSH key, which step 5 cannot connect without: the
   `ansible` account is key-only, and a hand-made replacement is stripped by the
   converge unless its public half is committed first. Step 5 is what installs
   restic, mounts astropath and renders `/etc/restic/password`, so none of them
   exist yet — do all three by hand, taking the repo key from the vault that
   step 3 restored:

   ```bash
   sudo zypper in -y restic
   sudo mkdir -p /mnt/astropath
   sudo mount -t nfs -o vers=4.1 administratum:/volume2/astropath /mnt/astropath
   sudo env RESTIC_PASSWORD="$(bin/vault-var.sh scholam_restic_password)" \
     restic --repo /mnt/astropath/scholam-home-backup \
     restore latest --include /home/jonny/.ssh --target /var/tmp/key-restore
   sudo install -D -m 0600 -o jonny -g users \
     /var/tmp/key-restore/home/jonny/.ssh/id_ed25519 /home/jonny/.ssh/id_ed25519
   sudo install -D -m 0644 -o jonny -g users \
     /var/tmp/key-restore/home/jonny/.ssh/id_ed25519.pub \
     /home/jonny/.ssh/id_ed25519.pub
   sudo umount /mnt/astropath
   ```

5. Apply its play locally (it targets `this_host` at loopback):

   ```bash
   make apply PLAY=scholam
   ```

6. Step 5 mounted astropath, so the home repo is reachable. There is no restore
   script (that is podman-only); restore `/home` by hand to a scratch target — so
   it does not overwrite the workspace you are recovering from — then copy back
   what step 3 did not already rebuild:

   ```bash
   sudo restic --password-file /etc/restic/password \
     --repo /nfs/astropath/scholam-home-backup \
     restore latest --sparse --target /var/tmp/home-restore
   sudo rsync -aHAXS --numeric-ids --exclude=/repos/lex-imperialis \
     /var/tmp/home-restore/home/jonny/ /home/jonny/
   ```

   `sudo` on both: the password file is `0600 root` in a `0700 root` directory,
   and the restored tree carries the snapshot's numeric ownership. `--sparse` is
   not optional either — without it restic writes every hole out in full, and the
   2026-08-25 drill restored 67.6 GiB from a 45 G `/home` because a 9.6 M
   `libvirt/images/*.qcow2` landed as 61 G. Size the scratch target for the live
   tree plus headroom, and check `df` before starting.

   The restore preserves numeric ownership, modes, symlinks and SELinux labels,
   and the flags carry them back: `-a` the first three, `-X` the labels, `-H`
   hardlinks and `-A` ACLs, with `--numeric-ids` keeping the ownership numeric
   (`-a` maps it by name otherwise) and `-S` stopping the copy writing out in
   full every hole `--sparse` just preserved — that one would put the 61 G into
   `/home` on top of the scratch copy. No `--delete`: this merges onto what step
   3 rebuilt rather than replacing it. The exclusion is the trap: the
   snapshot carries its own stale clone of `repos/lex-imperialis`, which would
   overwrite the fresh clone step 3 made. Salvage anything unpushed out of
   `/var/tmp/home-restore/home/jonny/repos/lex-imperialis` by hand, then delete
   the scratch tree. `.vault_pass` and `.venv` are excluded from the backup, so
   they are step 3's to restore whatever this copies.

## auspex (Raspberry Pi 5)

No NFS mount and no backup role, so nothing here is restored from a repo. What it
does hold is the fleet's entire monitoring history: Prometheus's TSDB, retained
for up to a year, on the NVMe mounted at `/var/lib/containers`. There is no copy of that
anywhere — accepted, because it is derived data whose loss costs dashboards
rather than recovery, but it means the card and the drive fail differently.

**A card rebuild does not touch the NVMe.** Reflashing the SD card and re-applying
the play remounts the existing store, so the TSDB, Alertmanager's silences and
every other named volume survive the procedure below. Losing the NVMe itself is
what loses the history, and nothing restores it — fit a replacement, then give it
an **ext4** filesystem labelled `containers` (`sudo mkfs.ext4 -L containers
/dev/<partition>`), and the fleet starts recording again from empty. `LABEL=` is
the filesystem label, not the partition name: a partition merely *named*
`containers` never resolves, and because the mount carries `nofail` the play then
reports green while the whole container store lands on the SD card. Confirm with
`findmnt /var/lib/containers` before trusting the apply.

1. Write Raspberry Pi OS Lite arm64 to a fresh card, then put
   `bootstrap/auspex-user-data.yaml` on the card's FAT partition as `user-data`,
   with a fresh `instance-id` in the `meta-data` beside it — `bootstrap/README.md`
   has the procedure and the trap, which is that letting Raspberry Pi Imager apply
   its own customisation silently overwrites the seed.
2. Boot it. The reflash gave it new host keys, so `ssh-keygen -R auspex` before
   connecting or both this step and step 3 abort on the stale pin.
   `ssh ansible@auspex` answering, with `id jonny` reporting uid 1026 and
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

5. Re-authorise the off-site coverage probe. Its key lives on the SD card, not
   the NVMe, so the reflash destroyed it and the play minted a fresh pair while
   the NAS still authorises the old public half. Until the new one is installed
   the only watch on off-site coverage stays down (`OffsiteMirrorProbeFailed`):

   ```bash
   sudo cat /etc/offsite-mirror/id_ed25519.pub
   ```

   Paste that into the `jonny` account's `authorized_keys` on the NAS — nothing
   in this repo may configure DSM. See
   [`roles/offsite_mirror/README.md`](../roles/offsite_mirror/README.md).

Anything deliberately silenced before a loss that took the NVMe with it starts
firing again after step 3. The outage itself is a hole in the history rather than
a fault to repair: nothing buffers samples on the fleet's behalf, so what was not
scraped is simply gone.

While auspex is down the fleet is unmonitored rather than noisily broken — every
rule matches an empty vector instead of firing, because the process that would
evaluate them is the one that stopped. Nothing on the fleet can say so, and
nothing needs to: no evaluation means no `Watchdog`, no heartbeat, and
healthchecks.io pages on the silence. A missed beat has one other deliberate
cause: sustained Discord delivery failure inhibits the `Watchdog` (alertmanager
role). So first check whether auspex answers and whether that alert was firing
recently — `max_over_time(ALERTS{alertname="AlertmanagerNotificationsFailing",alertstate="firing"}[1h])`
in Prometheus, history rather than the live alert, because a healed outage
resolves it before a human looks. A hit means the inhibition was engaged: the
host is healthy and the fault is the webhook, not this runbook's path.
Otherwise treat a missed beat as this host.

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

Recover the appliance with DSM (Hyper Backup / the RAID) — intact disks under a
reinstalled DSM need the volume encryption key from Prerequisites — then re-export
the shares the fleet mounts, **with the same options**, which are part of what has
to be recreated and are in no backup. `astropath` maps root to the `admin` account
(DSM's "Map root to admin"): both share roots are ACL-gated to `jonny` and
`administrators`, so any other squash identity is refused and restic silently
cannot write its repos. `scriptorum` keeps "No mapping", which is what lets rootful
podman traverse it at container start. `solar`, `scholam` and `rogue-trader` all
mount `astropath`; `solar` and `scholam` also mount `scriptorum`. Those mounts are
what the arr stack and the backups run on.

The off-site coverage probe on `auspex` breaks too: re-add its public key
(`/etc/offsite-mirror/id_ed25519.pub`) to the `jonny` account's `authorized_keys`
on the rebuilt NAS, and `rm /etc/offsite-mirror/known_hosts` on auspex — the role
creates that pin once with `force: false` and will not re-pin the new host key on
its own.

The `*-podman-backup` and `*-home-backup` restic repos and the `/scriptorum/photos`
library are also mirrored off-site to a Hetzner storage box by three Synology Hyper
Backup tasks (podman Wednesday 02:00, home Thursday 04:00, photos Tuesday 03:00).

**Restore the path before the data.** The box refuses every source outside
Hetzner, and a rebuilt NAS is outside it, so a restored Hyper Backup task pointed
straight at the box will fail. First get one of the two routes back:

- `rogue-trader` up with `storagebox_gateway` running, and the tasks' destination
  set to `192.168.3.4` port 23. DSM's Hyper Backup config is the only place that
  setting lives, so a NAS rebuilt without it needs it set by hand; or
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
from the repo root. This needs a GitHub credential with **Administration: write**
on the repo; the restored `gh` token does not have it, so grant it to the PAT
first or recreate the ruleset in the web UI:

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
      "parameters": { "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
        "require_last_push_approval": false, "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge"] } },
    { "type": "required_status_checks",
      "parameters": { "strict_required_status_checks_policy": false, "required_status_checks": [
        { "context": "pre-commit" }, { "context": "secret-scan" }, { "context": "molecule-gate" },
        { "context": "terraform-gate", "integration_id": 15368 },
        { "context": "site-gate", "integration_id": 15368 }
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
