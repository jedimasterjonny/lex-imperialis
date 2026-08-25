# Secret rotation

Rotation-on-exposure is a hard rule: a secret that reaches a commit is
compromised — rotate it, don't just delete it (scrubbing history does not undo
exposure). This is the per-secret runbook. For the vault model see the README's
Secrets section; for recovery see [disaster-recovery.md](disaster-recovery.md).

## The order that never locks you out

**Mint the new value at the provider first, leave the old one live, push it,
verify, and only then revoke the old.** Revoking before a clean apply leaves the
host authenticating with a value you just killed.

Standard rotation for a host-rendered vault secret:

1. Mint the replacement at the issuer; leave the old value active.
2. `ansible-vault edit inventory/group_vars/all/vault.yml --vault-password-file .vault_pass` — replace the variable; commit the re-encrypted vault.
3. `make apply PLAY=<host>` — re-renders the 0600 `EnvironmentFile`/config and restarts the workload.
4. Verify the service is healthy on the new value.
5. Revoke the old value at the provider.

`make check`/`--diff` will not leak the value — every secret-rendering task sets
`no_log`. Don't strip it to "see the diff".

**When a workload moves host, rotation follows the play, not the file.** The
apply column names where the secret is rendered *now*; the old host keeps the
0600 file it was last given, and no play touches it again. So rotating after a
move leaves the superseded value live on the host the role left, indefinitely.
Decommission the old host's copy at the same time the role moves — see the
role-removal note in `CLAUDE.md`.

## Host-rendered vault secrets

Each rotates by the standard procedure above; the table gives the issuer, the
apply target, and any wrinkle.

| Vault variable | Mint a new… | Apply | Wrinkle |
| --- | --- | --- | --- |
| `caddy_cloudflare_api_token` | Cloudflare token for the solar/home zone (`caddy_domain`; Zone:Read, DNS:Edit) | `PLAY=solar` | Gates the DNS-01 wildcard; homepage TLS depends on it too |
| `emmasedit_cloudflare_api_token` | Cloudflare token for the emmasedit.com zone | `PLAY=rogue-trader` | caddy DNS-01 for emmasedit.com |
| `alertmanager_discord_webhook_url` | Discord incoming webhook | `PLAY=auspex` | Fire a test alert and see it land — a botched rotation otherwise surfaces via the deadman only days later, off the periodic exercise (cadence with the alertmanager role) |
| `alertmanager_deadman_ping_url` | healthchecks.io check ping URL | `PLAY=auspex` | Confirm the new check goes green; cadence per the alertmanager README — a tighter grace makes Discord blips flap the check |
| `unpoller_api_key` | UniFi Network API key, in the controller's admin settings | `PLAY=auspex` | Passphrase-grade rather than read-only telemetry — see the role README. Verify on `unpoller_prometheus_cache_age_seconds`: the apply restarts the poller, so it starts at `-1` and leaves it only on the first successful poll — a refused key pins it there. The scrape stays green either way |
| `grafana_admin_password` | self-chosen | `PLAY=solar` | **First-init only** — an already-provisioned Grafana also needs `grafana-cli admin reset-admin-password` in-container to match |
| `arr_api_keys` | each Servarr app UI (Settings → General → API Key) | `PLAY=solar` | Dict replaced whole — re-supply all keys; then fix prowlarr's stored connections for any rotated app |
| `arr_transmission_username` / `arr_transmission_password` | self-chosen RPC creds | `PLAY=solar` | Container re-applies auth on restart; verify RPC goes 401 → authed |
| `arr_wireguard_conf` | commercial VPN provider portal (new WG key/peer) | `PLAY=solar` | Confirm the tunnel handshakes and egress is the VPN IP; the kill-switch holds if it fails |
| `rogue_trader_wordpress_db_password` | self-chosen MariaDB app password | `PLAY=rogue-trader` | **First-init only** — also `ALTER USER` in the `wordpress-db` container to match |
| `rogue_trader_wordpress_db_root_password` | self-chosen MariaDB root password | `PLAY=rogue-trader` | Same first-init `ALTER USER` caveat |
| `solar_restic_password` / `scholam_restic_password` / `rogue_trader_restic_password` | self-chosen, one per host | `PLAY=<host>` | **Repo-side too** — `restic key add` the new one and `restic key remove` the old on that host's repos, or the backup locks itself out. One key per host by design: a host must not be able to open another's repos |

**First-init caveat.** MariaDB and Grafana bake the password in on first
container init, so a vault edit + apply alone will not change an already-running
store — pair it with the in-service change (`ALTER USER` / `grafana-cli reset`),
or reset the volume (destroys data).

`rogue_trader_wireguard_conf` is rendered by `roles/wireguard_client` on every
converge, so it does have an apply path — but it is the one rotation that can
lock the operator out of a public box, because SSH to it rides the tunnel being
re-keyed and applying the new key flaps that tunnel. So it is driven at the
public address, never over the tunnel:

1. Open a path that does not depend on the tunnel: a rich rule for the
   workstation's public egress address on the host (`firewall-cmd --permanent
   --add-rich-rule=… && firewall-cmd --reload`, over the tunnel while it still
   works), and a temporary inbound-22 rule merged into
   `terraform/firewall-rogue-trader.tf`.
2. Mint the peer on the home router, which generates the keypair itself rather
   than taking one — so the private key comes from its exported config, not from
   `wg genkey`. Keep the same tunnel address, or the exporter binds, the NFS
   export allowlist and the scrape targets all move with it.
3. `ansible-vault edit`, then converge at the public address:
   `ansible-playbook playbooks/rogue-trader.yml --vault-password-file .vault_pass
   -e ansible_host=<public IPv4>`.
4. Confirm the handshake (`sudo wg show`) and that the NFS mount and both
   exporter binds recover, then remove the old peer on the router.
5. Revoke both openings from step 1 explicitly — `roles/firewalld` only ever
   adds, so re-converging without the rich rule leaves it in place.

`rogue_trader_storagebox_endpoint` is vaulted for topology, not secrecy: it names
the storage box account, which is what an attacker would need to aim at the box.
Nothing mints it and it does not rotate — it changes only if the box is replaced,
which means an `ansible-vault edit` and `make apply PLAY=rogue-trader`
(`roles/storagebox_gateway` consumes it as `storagebox_gateway_target`). It is
rendered into `ExecStart=` in a 0644 unit, so the task sets `no_log` to keep it
out of `--diff`; it is not hidden on the host, since the proxy carries it in argv
regardless. Vaulting keeps it out of the public repo, not off the box.

## Tooling tokens (vault vars, not rendered to a host)

Sourced into OpenTofu (and molecule) by `bin/vault-var.sh` at run time. Rotate
with the mint → `ansible-vault edit` → verify → revoke order, verifying with
`make tofu-plan` (or a test run). CI cannot read the vault, so each of these has
a mirrored CI copy that must be set in the same pass or the next run authenticates
with the revoked token.

| Vault variable | Mint a new… | CI copy | Verify |
| --- | --- | --- | --- |
| `terraform_cloudflare_api_token` | Cloudflare token, DNS + zone edit over the managed zones | `gh secret set CLOUDFLARE_APPLY_API_TOKEN --env fleet-apply` | `make tofu-plan` |
| `hcloud_token_emmas_edit` | Hetzner Read&Write token, **emmas-edit** project | `gh secret set HCLOUD_APPLY_TOKEN --env fleet-apply` | `make tofu-plan` |
| `hcloud_token` | Hetzner Read&Write token, **molecule test** project | `gh secret set MOLECULE_HCLOUD_TOKEN` | `make test-hetzner ROLE=motd` |

The read-only `CLOUDFLARE_PLAN_API_TOKEN` and `HCLOUD_PLAN_TOKEN` repo secrets,
which a PR plan uses, have no vault copy — mint and `gh secret set` them alone.

`hcloud_token_emmas_edit` has the widest reach — Terraform, `bootstrap/rogue-trader.yml`,
and the emmasedit apex data source all read it — but it is still one vault var.
Do not confuse it with `hcloud_token`: two distinct Hetzner tokens for two
different projects, rotated independently.

## The vault password (`.vault_pass`)

The master key — it decrypts everything and lives in **three** places that must
stay in lockstep. CI is deliberately not among them: no workflow holds a vault
password, so the vault is operator-only. Keep the old passphrase until every copy
is updated, in one pass:

1. `ansible-vault rekey inventory/group_vars/all/vault.yml` (old → new); commit the re-encrypted vault.
2. Overwrite the local `.vault_pass`.
3. Re-seed scholam's `/etc/arbites/vault_pass` (0600 root), or the next reconcile cannot decrypt.
4. Update the password manager.
5. Confirm a `make check` and an arbites reconcile both still decrypt.

## Keyless CI — no rotation

GCP auth (the Firebase deploy and the `tofu` plan/apply jobs) is Workload
Identity Federation: GitHub's OIDC token is exchanged for short-lived
credentials each run. There is **no stored key to rotate**. To revoke access,
remove the service account's `workloadIdentityUser` binding (or disable the SA)
in `terraform/infra-shared.tf` and apply.

## Out-of-band secrets

Six secrets are not in the vault:

- **Hetzner storage box SSH credential** — held by DSM Hyper Backup on the NAS; nothing in this repo reads it. Rotate in the Hetzner Console and DSM together. Losing it with the NAS blocks an off-site restore, so it is also a `disaster-recovery.md` prerequisite.

- **`/etc/offsite-mirror/id_ed25519`** (auspex) — the off-site coverage probe's own SSH identity, minted by the `offsite_mirror` role and trusted by the NAS account it reads as. It reads Hyper Backup's cached manifests and nothing else — it is not the storage box credential, and grants no access to the off-site copy. Rotate by deleting both halves on auspex and re-applying (the `creates:` guard mints a fresh pair), then replacing the old line in the NAS account's `authorized_keys`; DSM is not managed from here, so that half is by hand. Order does not matter much here because the probe fails closed: until the new key is trusted `offsite_mirror_success` reads 0 and `OffsiteMirrorProbeFailed` raises after 25h.

- **`/etc/arbites/ssh/id_arbites`** — the reconcile timer's own SSH identity, distinct from the operator's key so either rotates alone (it cannot be vaulted: the reconciler needs it to reach the fleet). Rotation is fleet-wide, and the public half is declared, not placed by hand: add the new key to `common_ansible_authorized_keys` in `inventory/group_vars/all/authorized_keys.yml` and apply, re-seed the private half via the arbites bootstrap, then confirm a reconcile. Order matters — authorise before switching, or the first host the timer reaches refuses it. **Removing the old key is not yet automated:** while `common_ansible_authorized_keys_exclusive` is `false` the role only adds, so dropping the entry revokes nothing and the apply still goes green — delete the line from each host's `authorized_keys` by hand until the flag is on. No first-boot seed carries this key, so the declared list and that manual removal are the whole of it. See the role's README.

- **The operator's fleet SSH key** (`~jonny/.ssh/id_ed25519` on scholam) — what an operator-run play connects as, and registered with Hetzner Cloud as `rogue-trader-key`. Since arbites took its own identity this is a human credential only, so it can carry a passphrase. Rotating it reaches further than the arbites key: it sits in **both** lists in `inventory/group_vars/all/authorized_keys.yml`, and `bootstrap/rogue-trader.bu` and `bootstrap/auspex-user-data.yaml` seed it at first boot — skip those and a reflashed host comes back trusting the retired key, which for auspex is the documented recovery path rather than a remote case.
- **dev workstation claude.ai OAuth token** (`~/.claude.json`) — the `dev` role reads and rewrites it under `no_log` for `claude-remote-control`. Rotate by re-running `claude` and `/login` as the dev user; it is a session token, not a vault secret.
- **`CLAUDE_OAUTH_TOKEN`** (repo secret) — the subscription token the `claude review` workflow authenticates with. A distinct credential from the one above, and expiring: when it lapses the `review` job goes red on the next labelled major. Rotate with `claude setup-token`, then `gh secret set CLAUDE_OAUTH_TOKEN`.
