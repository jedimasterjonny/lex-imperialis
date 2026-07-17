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

## Host-rendered vault secrets

Each rotates by the standard procedure above; the table gives the issuer, the
apply target, and any wrinkle.

| Vault variable | Mint a new… | Apply | Wrinkle |
|---|---|---|---|
| `caddy_cloudflare_api_token` | Cloudflare token for the solar/home zone (`caddy_domain`; Zone:Read, DNS:Edit) | `PLAY=solar` | Gates the DNS-01 wildcard; homepage TLS depends on it too |
| `emmasedit_cloudflare_api_token` | Cloudflare token for the emmasedit.com zone | `PLAY=rogue-trader` | caddy DNS-01 for emmasedit.com |
| `alertmanager_discord_webhook_url` | Discord incoming webhook | `PLAY=solar` | Fire a test alert to confirm delivery |
| `alertmanager_deadman_ping_url` | healthchecks.io check ping URL (5m period) | `PLAY=solar` | Confirm the new check goes green; keep period/grace at the Watchdog 5m |
| `grafana_admin_password` | self-chosen | `PLAY=solar` | **First-init only** — an already-provisioned Grafana also needs `grafana-cli admin reset-admin-password` in-container to match |
| `arr_api_keys` | each Servarr app UI (Settings → General → API Key) | `PLAY=solar` | Dict replaced whole — re-supply all keys; then fix prowlarr's stored connections for any rotated app |
| `arr_transmission_username` / `arr_transmission_password` | self-chosen RPC creds | `PLAY=solar` | Container re-applies auth on restart; verify RPC goes 401 → authed |
| `arr_wireguard_conf` | commercial VPN provider portal (new WG key/peer) | `PLAY=solar` | Confirm the tunnel handshakes and egress is the VPN IP; the kill-switch holds if it fails |
| `rogue_trader_wordpress_db_password` | self-chosen MariaDB app password | `PLAY=rogue-trader` | **First-init only** — also `ALTER USER` in the `wordpress-db` container to match |
| `rogue_trader_wordpress_db_root_password` | self-chosen MariaDB root password | `PLAY=rogue-trader` | Same first-init `ALTER USER` caveat |

**First-init caveat.** MariaDB and Grafana bake the password in on first
container init, so a vault edit + apply alone will not change an already-running
store — pair it with the in-service change (`ALTER USER` / `grafana-cli reset`),
or reset the volume (destroys data).

`rogue_trader_wireguard_conf` is the one host secret with **no** `make apply`
path — bootstrap writes it once and never re-renders an existing server. To
rotate: `wg genkey` a new keypair, add the new public key as a peer on the home
router, `ansible-vault edit` the value, then on the live box replace
`/etc/wireguard/wg0.conf` (0600) and `systemctl restart wg-quick@wg0`; confirm
the handshake and that the NFS + scrape binds recover, then remove the old peer.

## Tooling tokens (vault vars, not rendered to a host)

Sourced into OpenTofu by `bin/vault-var.sh` at run time — no second copy. Rotate
with the mint → `ansible-vault edit` → verify → revoke order, verifying with
`make tofu-plan` (or a test run). CI reads the same vault, so there is **no
separate CI update**.

| Vault variable | Mint a new… | Verify |
|---|---|---|
| `terraform_hcp_token` | HCP Terraform token (app.terraform.io, org jonnyoc → User Settings → Tokens) | `make tofu-plan` |
| `terraform_cloudflare_api_token` | Cloudflare token, DNS + zone edit over the managed zones | `make tofu-plan` |
| `hcloud_token_emmas_edit` | Hetzner Read&Write token, **emmas-edit** project | `make tofu-plan` |
| `hcloud_token` | Hetzner Read&Write token, **molecule test** project | `make test-hetzner ROLE=motd` |

`hcloud_token_emmas_edit` has the widest reach — Terraform, `bootstrap/rogue-trader.yml`,
and the emmasedit apex data source all read it — but it is still one vault var.
Do not confuse it with `hcloud_token`: two distinct Hetzner tokens for two
different projects, rotated independently.

## The vault password (`.vault_pass`)

The master key — it decrypts everything and lives in **four** places that must
stay in lockstep. Keep the old passphrase until every copy is updated, in one
pass:

1. `ansible-vault rekey inventory/group_vars/all/vault.yml` (old → new); commit the re-encrypted vault.
2. Overwrite the local `.vault_pass`.
3. `gh secret set VAULT_PASSWORD` — the sole CI secret.
4. Re-seed scholam's `/etc/gitops-reconcile/vault_pass` (0600 root), or the next reconcile cannot decrypt.
5. Update the password manager.
6. Confirm a CI run, a `make check`, and a gitops reconcile all still decrypt.

## Keyless CI — no rotation

GCP auth (the Firebase deploy and the `tofu` plan/apply jobs) is Workload
Identity Federation: GitHub's OIDC token is exchanged for short-lived
credentials each run. There is **no stored key to rotate**. To revoke access,
remove the service account's `workloadIdentityUser` binding (or disable the SA)
in `terraform/infra-shared.tf` and apply.

## Out-of-band secrets

Two secrets are not in the vault:

- **`/etc/gitops-reconcile/ssh/id_ed25519`** — a copy of the operator's fleet SSH key the reconcile timer connects with (it cannot be vaulted: the reconciler needs it to reach the fleet). Rotation is fleet-wide — add the new public key to every host's connection-user `authorized_keys`, re-seed the file via the gitops_reconcile bootstrap, confirm a reconcile, then remove the old key. See the role's README.
- **dev workstation claude.ai OAuth token** (`~/.claude.json`) — the `dev` role reads and rewrites it under `no_log` for `claude-remote-control`. Rotate by re-running `claude` and `/login` as the dev user; it is a session token, not a vault secret.
