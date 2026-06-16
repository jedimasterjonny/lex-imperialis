# autoupdate

Unattended weekly updates. A oneshot service runs `zypper --non-interactive`
early Monday (03:00, plus a 0–2 h jitter) and reboots after a successful run so
a new kernel takes effect — `dup` on rolling Tumbleweed, `patch` on Leap
(`autoupdate_zypper_command`). `zypper`'s 102/103 "reboot/restart recommended"
codes count as success; a real failure skips the reboot, leaving the system up
for inspection.
