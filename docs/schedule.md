# Schedule

Everything scheduled across the estate, in `Europe/London`. Out of scope:
distro-stock timers (snapper, logrotate, fstrim, `e2scrub_all`,
`dpkg-db-backup`), which arrive with the package and are left at its defaults,
and in-process poll loops (unpoller, cadvisor housekeeping, Prometheus's scrape
and evaluation), which hold no wall-clock slot to collide with anything. The
code is authoritative and nothing checks this page against it, so a changed
timer drifts from it silently: edit the owner first, then this.

One clock. The fleet hosts, the NAS and the UniFi controller all keep
`Europe/London`, so every row moves with BST together and the spacing between
any two of them holds all year. The time below is what an operator types into
DSM, the UniFi console or an `*_oncalendar`. GitHub Actions cron is the
exception — it is UTC, so `terraform drift plan` is the one row that drifts
against the rest, landing 06:41 local in winter and 07:41 in summer.

Both UK transitions land at 01:00 on a Sunday, so 01:00–02:00 is skipped in
spring and runs twice in autumn. The two weekly rows in that hour —
`podman_backup` on rogue-trader (Wed 01:00) and `home_backup` on solar (Thu
01:00) — never meet it. Three interval timers do, daily: `arbites`,
`beets-pipeline` and `inquisition` lose their ticks in that hour each spring and
repeat them each autumn, which for a reconcile, a poll and a health check is
nothing. Keep new daily and Sunday jobs out of that hour.

The **Owner** column names what to edit: a var in the host's play or the role's
defaults, or a static timer file. Rows owned by DSM, UniFi or macOS are set on
the device — no gate, no review, no diff. The DSM backup and mirror tasks are at
least watched from outside by `offsite_mirror` and `r2_mirror`, and the UniFi
update by `UnifiFirmwareUpdatePending`, which reads the outcome rather than the
schedule: any 8-day span contains a window, so an update still pending across
one has sat through it. Nothing watches the two R2 integrity checks, the array
scrub, the controller auto-backup or Time Machine.

`autoupdate` carries `RandomizedDelaySec=2h`, so its rows open a two-hour window
rather than name a fire time.

The UniFi row covers all three of its update components. Do not take the day or
hour from the Network API: `setting/mgmt` still reports the older combined
scheme's `auto_upgrade_hour`, which is vestigial and disagrees with the console.

## Weekly

| Time (Europe/London) | Job | Owner |
| --- | --- | --- |
| Mon 00:00 | `btrfs-balance` — solar, scholam, rogue-trader | `btrfsmaintenance_balance_period` |
| Mon 03:00 | `autoupdate` — solar | `autoupdate_oncalendar`, role default |
| Mon 06:41 winter, 07:41 summer | terraform drift plan | `.github/workflows/terraform.yml` |
| Tue 03:00 | `autoupdate` — auspex | `autoupdate_oncalendar`, `auspex.yml` |
| Tue 03:00 | `photos-backup` → port-wander | DSM task config |
| Wed 00:00 | `podman_backup` — solar | `podman_backup_oncalendar`, `solar.yml` |
| Wed 01:00 | `podman_backup` — rogue-trader | `podman_backup_oncalendar`, role default |
| Wed 02:00 | `podman-backup` → port-wander | DSM task config |
| Wed 06:00 | `podman-backup-r2` → reclusiam | DSM task config |
| Wed 07:00 | `autoupdate` — rogue-trader | `autoupdate_oncalendar`, `rogue-trader.yml` |
| Thu 01:00 | `home_backup` — solar | `home_backup_oncalendar`, role default |
| Thu 02:00 | `home_backup` — scholam | `home_backup_oncalendar`, `scholam.yml` |
| Thu 03:00 | `home_backup` — rogue-trader | `home_backup_oncalendar`, `rogue-trader.yml` |
| Thu 04:00 | `home-backup` → port-wander | DSM task config |
| Thu 06:00 | `home-backup-r2` → reclusiam | DSM task config |
| Fri 03:00 | `autoupdate` — scholam | `autoupdate_oncalendar`, `scholam.yml` |
| Fri 08:00 | `home-backup-r2` integrity check | DSM task config |
| Sat 05:00 | UniFi update — OS, Application and managed devices | UniFi console |
| Sat 06:00 | `podman-image-prune` — auspex, rogue-trader, scholam, solar | `roles/podman/files/podman-image-prune.timer` |
| Sun 03:00 | `incus-image-refresh` — scholam | `incus_image_refresh_oncalendar` |
| Sun 03:30 | `tumbleweed-image-refresh` — scholam | `libvirt_image_refresh_oncalendar` |
| Sun 08:00 | `podman-backup-r2` integrity check | DSM task config |

## Daily and monthly

| Time (Europe/London) | Job | Owner |
| --- | --- | --- |
| 00:30 | `wordpress-db-dump` — rogue-trader | `roles/wordpress/files/wordpress-db-dump.timer` |
| 04:00 | `beets-library` — solar | `arr_beets_library_oncalendar` |
| 06:17 | `smartmon` — auspex, scholam, solar | `smartmon_oncalendar` |
| 11:17 | `offsite_mirror` probe — auspex | `offsite_mirror_oncalendar` |
| 11:47 | `r2_mirror` probe — auspex | `r2_mirror_oncalendar` |
| 1st 00:00 | `btrfs-scrub` — solar, scholam, rogue-trader | `btrfsmaintenance_scrub_period` |
| 1st 00:30 | UniFi controller auto-backup | UniFi console |
| — | monthly btrfs scrub — both NAS arrays | DSM Storage Manager |

## Intervals

No wall-clock time to shift; a fixed anchor is local where one exists.

- 30 s — `arr-wireguard-refresh`, solar (`arr_wireguard_refresh_interval`)
- 1 min — `wireguard-refresh`, rogue-trader (`wireguard_client_interval`)
- 5 min — `wordpress-cron`, rogue-trader (`roles/wordpress/files/wordpress-cron.timer`)
- 10 min — `beets-pipeline`, solar (`arr_beets_pipeline_oncalendar`)
- 15 min, +2 min jitter — `arbites` fleet reconcile, scholam (`arbites_oncalendar`, `arbites_randomized_delay`)
- hourly at :37 — `inquisition`, auspex, rogue-trader, solar (`inquisition_oncalendar`)
- hourly, best-effort while the laptop is on the network — Time Machine (macOS)
- 6 h from 00:00 local — `wordpress-update-check`, rogue-trader (`roles/wordpress/files/wordpress-update-check.timer`)
- 6 h from 00:20 local — `wordpress-boost`, rogue-trader (`roles/wordpress/files/wordpress-boost.timer`)

Renovate fires on its own cadence, not a schedule of ours, but `renovate.json`
sets two `Europe/London` windows it must land inside: plex bumps automerge
between 02:00 and 06:00, and the renovate pin's own PRs are created before 05:00
on Mondays.
