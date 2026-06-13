# autoupdate

Unattended weekly updates via `zypper dup`. A oneshot service runs
`zypper --non-interactive dup` early Monday (03:00, plus a 0–2 h jitter) and
reboots after every successful dup so a new kernel takes effect. `zypper`'s
102/103 "reboot/restart recommended" codes count as success; a real failure
skips the reboot, leaving the system up for inspection.
