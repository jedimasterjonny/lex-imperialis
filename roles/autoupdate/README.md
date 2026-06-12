# autoupdate

Unattended weekly updates via transactional-update. A drop-in reschedules the
vendor timer from daily to Monday 03:00 — the stock 0–2 h random delay stays —
and `REBOOT_METHOD=systemd` is pinned so a successful `dup` reboots into the
new snapshot immediately, never deferred to a rebootmgr maintenance window.
