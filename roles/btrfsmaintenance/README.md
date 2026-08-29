# btrfsmaintenance

Declares the cadence of the btrfsmaintenance scrub and balance timers.
`btrfsmaintenance_scrub_period` and `btrfsmaintenance_balance_period` take
`daily`, `weekly`, `monthly` or `none`; the defaults are the schedule the fleet
already runs, so applying the role changes nothing on scholam or solar.

- The drop-ins under `/etc/systemd/system/btrfs-*.timer.d/` are generated, not
  authored. The role sets the periods in `/etc/sysconfig/btrfsmaintenance` and
  runs the package's own generator, which writes them. Managing the drop-ins
  directly would give them two writers: `btrfsmaintenance-refresh.path` rewrites
  them from the sysconfig whenever it changes.
- The sysconfig is edited line by line rather than templated. It is
  fillup-generated, and a package upgrade adds variables to it that owning the
  whole file would silently delete.
- The generator is invoked explicitly rather than left to that path unit, which
  fires asynchronously and so cannot be ordered against arming the timers. The
  same task re-materialises a schedule on a host whose periods are already
  correct but whose drop-ins were never generated — a sysconfig written where
  the path unit could never see it, leaving the balance timer on the package
  default of monthly rather than the weekly that sysconfig asks for.
- The package's own timer units both default to monthly, so the balance period
  is a real override while the scrub period only restates that default.
