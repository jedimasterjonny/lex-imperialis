# sshd

Key-only SSH via a hardening drop-in. sshd keeps the first value it reads
for each keyword and the shipped config includes `sshd_config.d` ahead of
its own settings, so the drop-in overrides the defaults without touching
the vendor file.

- Password and keyboard-interactive auth off; root stays
  `prohibit-password` because provisioning and the molecule full-VM tiers
  reach fresh hosts as root with keys.
- No algorithm pinning: every peer's OpenSSH defaults already exclude weak
  crypto.
- `LogLevel VERBOSE` records the key fingerprint used for each login.
- `sshd -t` validates the drop-in before it lands; changes reload the
  daemon rather than restart it.
