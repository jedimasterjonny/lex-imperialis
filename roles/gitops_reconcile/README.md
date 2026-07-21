# gitops_reconcile

Closes the apply loop on scholam: a root systemd timer pulls `origin/main` into a
service-owned clone and, when it has advanced, applies the whole fleet — so a
merged change reaches the hosts without a manual `make apply`. The scheduled
counterpart of the `unattended-author` skill, and the one standing exception to
"apply is the operator's call". Scholam-only; it reuses today's push-from-scholam
model, keeping `.vault_pass` on one host.

## The loop

`gitops-reconcile.timer` fires `gitops-reconcile.sh` every 15 min (plus a 2 min
jitter; `Persistent`, so a reboot-missed run catches up). The script:

1. exits early if the pause flag is present (a no-op success — see Kill-switches);
2. `git fetch` + `reset --hard origin/main` in `gitops_reconcile_repo_dir` —
   `origin/main` is the only source of truth, never a local or feature branch;
3. short-circuits if `main` has not advanced since the last applied SHA, so an
   idle cycle is near-free;
4. otherwise runs `ansible-playbook playbooks/site.yml` from the clone root
   (reusing the repo's `ansible.cfg`) out of `gitops_reconcile_venv_dir`, with
   `--diff` to the journal. `site.yml` applies scholam last so the run never
   restarts its own timer mid-apply;
5. records the applied SHA only on a clean full apply; a failure leaves the old
   value, so the next run retries.

An `ExecStopPost` hook writes the outcome to
`gitops_reconcile_textfile_dir/gitops-reconcile.prom`: `gitops_reconcile_success`
(1/0 from `$SERVICE_RESULT`), `gitops_reconcile_last_run_timestamp_seconds`, and
`gitops_reconcile_applied_commit{sha=...}` (the live revision). The `prometheus`
role's `GitopsReconcileFailed` / `GitopsReconcileStale` rules surface a failed run
or a timer that has stopped firing.

## Bootstrap (one-time)

The role manages everything except two secrets and a `known_hosts`, none of which
can come from the vault (the reconciler needs the password to read it) or the
public repo. The role asserts all three exist and fails the apply otherwise, so
place them *before* the apply that first includes the role. On scholam as root —
restore the secrets from the password manager on a rebuild, like `.vault_pass`:

```
install -D -m 0600 -o root -g root ~jonny/.ssh/id_ed25519 /etc/gitops-reconcile/ssh/id_ed25519
install -D -m 0600 -o root -g root ~jonny/lex-imperialis/.vault_pass /etc/gitops-reconcile/vault_pass
```

Seed the `known_hosts` over the trusted LAN with each host's key at the exact
address the reconcile connects to it — the inventory's `ansible_host` where set, the
name otherwise, and scholam's own loopback, since `site.yml` applies it last:

```
ssh-keyscan -H 127.0.0.1 <each other host at its ansible_host or name> >/etc/gitops-reconcile/ssh/known_hosts
```

Host-key checking is on by default (`gitops_reconcile_host_key_checking`), so a
missing, empty, or wrongly-keyed `known_hosts` fails the assert or a later connect —
set the flag false to run without it. The SSH key is the operator's existing key —
the one the fleet already accepts
for each host's connection user (`ansible`, and `jonny` on the NAS), so no fleet
change is needed. Then wire the role into `playbooks/scholam.yml` and run
`make apply PLAY=scholam` once: it installs the clone, venv, scripts, and units
and enables the timer. That is the last manual apply — the timer self-sustains
after, applying even its own future changes (no restart handler, so a self-apply
never drops its own in-flight run).

> `make check PLAY=scholam` fails the timer-enable task with "Could not find the
> requested service" on first introduction — a check-mode artifact (the unit
> isn't written in check mode); the apply succeeds.

## Trust model

Scholam already holds `.vault_pass` and fleet-wide NOPASSWD root (control host and
molecule runner). The new exposure is *temporal*: fleet-apply is now always-armed
via a root timer rather than operator-gated, and a second at-rest copy of the SSH
key and vault password lives under `/etc/gitops-reconcile/` (0600 root). A scholam
compromise was already game-over for the fleet. `gitops_reconcile_host_key_checking`
is on by default: the reconcile pins each host against the seeded `known_hosts`, so
a machine-in-the-middle on the LAN/WireGuard path impersonating a fleet host aborts
the connect rather than receiving that host's rendered secrets. Set it false to run
without a `known_hosts`.

## Kill-switches

- **Soft pause** — `touch /var/lib/gitops-reconcile/pause`. The timer still fires
  but the script exits immediately as a success, so it does not alert. For short,
  attended holds; `rm` the flag to resume.
- **Hard stop** — `systemctl disable --now gitops-reconcile.timer`. The service
  stops firing, so `gitops_reconcile_last_run_timestamp_seconds` freezes and
  `GitopsReconcileStale` warns after the grace window — the safety net for a stop
  left on by accident.
