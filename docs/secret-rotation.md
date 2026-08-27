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
2. `ansible-vault edit inventory/group_vars/all/vault.yml --vault-password-file .vault_pass` — replace the variable, then **merge the re-encrypted vault to `main` before applying**. `arbites` hard-resets its clone to `origin/main` every 15 minutes, so a commit sitting on a branch is invisible to it and the next reconcile re-renders the old value fleet-wide. If a rotation must be applied from a branch, hold the reconciler with `sudo touch /var/lib/arbites/pause` and remove it after step 5 — not `systemctl disable --now`, which freezes the timestamp metric and trips `ArbitesStale`.
3. `make apply PLAY=<host>` — re-renders the 0600 `EnvironmentFile`/config and restarts the workload where there is one. The restic rows have no service to restart; their check is in the row.
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
| `caddy_cloudflare_api_token` | Cloudflare token on the `jonnyoc.uk` zone, which holds `caddy_domain` (Zone:Read, DNS:Edit) | `PLAY=solar` | Gates the DNS-01 wildcard; homepage TLS depends on it too. caddy serves persisted certs from the `caddy-data` volume and touches the token only at renewal, so it stays healthy for weeks on a dead one — verify at Cloudflare before revoking, not by a green container |
| `emmasedit_cloudflare_api_token` | Cloudflare token for the emmasedit.com zone | `PLAY=rogue-trader` | caddy DNS-01 for emmasedit.com; same persisted-cert caveat as the row above |
| `alertmanager_discord_webhook_url` | Discord incoming webhook | `PLAY=auspex` | Fire a test alert and see it land — a botched rotation otherwise surfaces via the deadman only days later, off the periodic exercise (cadence with the alertmanager role) |
| `alertmanager_deadman_ping_url` | healthchecks.io check ping URL | `PLAY=auspex` | Confirm the new check goes green; cadence per the alertmanager README — a tighter grace makes Discord blips flap the check |
| `unpoller_api_key` | UniFi Network API key, in the controller's admin settings | `PLAY=auspex` | Passphrase-grade rather than read-only telemetry — see the role README. Verify on `unpoller_prometheus_cache_age_seconds`: the apply restarts the poller, so it starts at `-1` and leaves it only on the first successful poll — a refused key pins it there. The scrape stays green either way. The integration API returns WiFi passphrases in plaintext to any holder that can reach the controller, so an *exposed* key means rotating the WiFi passphrase at the controller too — off-repo, and every client re-joins |
| `grafana_admin_password` | self-chosen | `PLAY=solar` | **First-init only** — an already-provisioned Grafana also needs `podman exec grafana grafana cli admin reset-admin-password <new>` to match (`grafana cli`, a subcommand; there is no `grafana-cli` binary in the image). The same apply re-renders homepage's env, so its Grafana widget 401s until the reset lands — the tile stays green, since its monitor is `/api/health` |
| `arr_api_keys` | self-chosen, 32 hex chars, one per app | `PLAY=solar` | The repo owns the key — `<APP>__AUTH__APIKEY` from the env file wins over `config.xml`, so the UI's "Reset API Key" writes a value the running app ignores. Dict replaced whole: re-supply all keys, then fix prowlarr's stored connections for any rotated app. Rotating **prowlarr's own** key breaks the other way — every prowlarr-synced indexer in radarr/sonarr/lidarr authenticates to prowlarr with it, and the 6-hourly Application Indexer Sync will not repair it (the app returns the key masked and the equality check treats `********` as a match). Force it: prowlarr → Settings → Apps → Sync App Indexers |
| `arr_transmission_username` / `arr_transmission_password` | self-chosen RPC creds | `PLAY=solar` | Container re-applies auth on restart; verify RPC goes 401 → authed, then re-enter the creds on radarr's, sonarr's and lidarr's Transmission client — each stores its own copy, no play touches them, and grabs stop silently if they are missed |
| `arr_wireguard_conf` | commercial VPN provider portal (new WG key/peer) | `PLAY=solar` | Confirm the tunnel handshakes and egress is the VPN IP; the kill-switch holds if it fails |
| `solar_plex_token` | not portal-minted — read `PlexOnlineToken` from the Plex server's `Preferences.xml` | `PLAY=solar` | No per-token revoke: step 5 is a device sign-out, and signing out everywhere signs the *server* out too, so the replacement has to be read back afterwards. Homepage's Plex widget is the only consumer — its `/identity` monitor is unauthenticated and stays green, only the widget body empties |
| `rogue_trader_wordpress_db_password` | self-chosen MariaDB app password | `PLAY=rogue-trader` | **First-init only, and the apply misses the live copy** — the play rewrites `db.env`/`app.env`, which only the nightly dump reads; the migrated `wp-config.php` holds its own literal the image entrypoint never rewrites. Keep the site up with MariaDB multi-auth: `ALTER USER 'wordpress'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('<old>') OR mysql_native_password USING PASSWORD('<new>')`, apply, `sudo wp config set DB_PASSWORD '<new>'` on the host, verify, then re-`ALTER` to the new password alone. A straight cutover takes emmasedit.com down until `wp-config.php` is edited, and step 4 will not catch it |
| `rogue_trader_wordpress_db_root_password` | self-chosen MariaDB root password | `PLAY=rogue-trader` | Same first-init caveat, but root exists **twice** — `ALTER USER 'root'@'localhost', 'root'@'%'`. Nothing authenticates as root at runtime (the healthcheck has its own account), so missing the `'%'` half is silent until `disaster-recovery.md`'s dump-load step, which connects remotely as root |
| `solar_restic_password` / `scholam_restic_password` / `rogue_trader_restic_password` | self-chosen, one per host | `PLAY=<host>` | **Repo-side, and the order is inverted — see below.** One key per host by design: a host must not be able to open another's repos |

**First-init caveat.** MariaDB and Grafana bake the password in on first
container init, so a vault edit + apply alone will not change an already-running
store — pair it with the in-service change (`ALTER USER` / `grafana cli`),
or reset the volume (destroys data).

**The restic rows invert the standard order.** `restic key add` authenticates
with the repository's *current* key, and step 3 overwrites `/etc/restic/password`
with the new one — so an add attempted afterwards cannot open the repo, and
`restic key remove` is then unreachable too, because restic refuses to remove the
key it is currently using. On an exposure rotation the compromised key stays valid
permanently. Note also that step 2 is enough on its own to trigger this: arbites
applies `main` within ~15 minutes, so the merge *is* the apply.

Add first, and split the add from the remove across a mirror run:

1. While the old key is still the rendered one, add the new one to every repo that
   host owns — two on solar and rogue-trader (podman and home, one host key opens
   both), one on scholam; paths in [backups.md](backups.md), and `/etc/restic` is
   `0700 root` so these need sudo:
   `sudo restic -r <repo> --password-file /etc/restic/password key add --new-password-file <file>`.
2. Edit the vault and merge it; the reconcile applies it.
3. Wait for `offsite_mirror_task_last_success_timestamp_seconds` to advance. The
   Hyper Backup tasks are plain mirrors of the repo root, `keys/` included, and run
   weekly — until one runs, the off-site copy holds only the old key while the vault
   holds only the new passphrase, so the one protection against losing the NAS opens
   to neither.
4. `restic key list`, then `restic key remove <old ID>`. That it succeeds is the
   check — there is no service to restart, so step 4's health check does not apply.
   Revocation reaches the off-site copy on the mirror run after that.

If the new password is ever lost mid-rotation, the old one is still in git:
`git show <prev>:inventory/group_vars/all/vault.yml | ansible-vault view -`.

`rogue_trader_wireguard_conf` is rendered by `roles/wireguard_client` on every
converge, so it does have an apply path — but it is the one rotation that can
lock the operator out of a public box, because SSH to it rides the tunnel being
re-keyed and applying the new key flaps that tunnel. So it is driven at the
public address, never over the tunnel:

0. Pause the reconciler on scholam for the whole procedure:
   `sudo touch /var/lib/arbites/pause`. It applies `site.yml`, and so this play,
   whenever `main` advances — which Renovate does unattended at any hour. Off a
   stale `main` it re-renders the *old* conf and the tunnel comes back on the old
   peer, so step 4 confirms a handshake that is about to die with the peer
   removal. A paused run still exits a clean success, so nothing alerts.
1. Open a path that does not depend on the tunnel. On the host, over the tunnel
   while it still works (`firewall-cmd` needs root as `ansible`):
   `sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source
   address=<workstation public egress>/32 service name=ssh accept' && sudo
   firewall-cmd --reload`. That address is the home WAN address, which is
   dynamic. Then a temporary inbound-22 rule in
   `terraform/firewall-rogue-trader.tf` — that half is a PR and a merge, since the
   apply is CI's.
2. Mint the peer on the home router, which generates the keypair itself rather
   than taking one — so the private key comes from its exported config, not from
   `wg genkey`. Keep the same tunnel address, or the exporter binds, the
   storage-box forward, the NFS export allowlist and the scrape targets all move
   with it.
3. `ansible-vault edit`, then converge at the public address:
   `ansible-playbook playbooks/rogue-trader.yml --vault-password-file .vault_pass
   -e ansible_host=<public IPv4>`.
4. On rogue-trader, confirm the handshake (`sudo wg show`) and that the NFS mount,
   the storage-box forward and both exporter binds recover, then remove the old
   peer on the router. The forward fails silently — its socket sets `FreeBind` —
   so check it rather than waiting to be told.
5. Revoke both openings from step 1 explicitly — `roles/firewalld` only ever
   adds, so re-converging without the rich rule leaves it in place. Read the rule
   back from `--list-rich-rules` rather than retyping it: if the WAN address moved
   mid-procedure, retyping revokes nothing and leaves a stranger's address
   admitted. The terraform half is another PR and merge.
6. Merge the re-encrypted vault, confirm `main` carries it, then
   `sudo rm /var/lib/arbites/pause`.

`rogue_trader_storagebox_endpoint` is vaulted for topology, not secrecy: it names
the storage box account, which is what an attacker would need to aim at the box.
Nothing mints it and it does not rotate — it changes only if the box is replaced,
which means an `ansible-vault edit` and `make apply PLAY=rogue-trader`
(`roles/storagebox_gateway` consumes it as `storagebox_gateway_target`). It is
rendered into `ExecStart=` in a 0644 unit, so the task sets `no_log` to keep it
out of `--diff`; it is not hidden on the host, since the proxy carries it in argv
regardless. Vaulting keeps it out of the public repo, not off the box.

`unpoller_url` and `alertmanager_discord_channel_url` are vaulted on the same
basis — topology, not credentials — and rotate only if the thing they name moves.

## Tooling tokens (vault vars, not rendered to a host)

Resolved from the vault at run time by `bin/vault-var.sh`, so one
`ansible-vault edit` covers every consumer at once — no host holds a copy. Rotate
with the mint → `ansible-vault edit` → verify → revoke order.

`make tofu-plan` proves only that the new value authenticates and can **read**. It
will not catch a Hetzner token minted read-only or a Cloudflare token short a
ruleset permission, and it never touches the CI copies — so land a real terraform
change and watch that apply go green before revoking. Run
`tofu -chdir=terraform init` first: a merged provider bump leaves `.terraform/`
stale, and a `Required plugins`/`invalid_grant` failure there is that or expired
gcloud ADC, not the new token.

CI cannot read the vault, so each of these has a mirrored CI copy that must be set
in the same pass or the next run authenticates with the revoked token.

| Vault variable | Mint a new… | CI copy | Verify |
| --- | --- | --- | --- |
| `terraform_cloudflare_api_token` | Cloudflare token over jonnyoc.uk, jonnyoc.co.uk and emmasedit.com — Zone: DNS Edit, Zone Settings Edit, Single Redirect Edit, Zone WAF Edit, Cache Rules Edit, SSL and Certificates Edit | `gh secret set CLOUDFLARE_APPLY_API_TOKEN --env fleet-apply` | `make tofu-plan`, then a real apply |
| `hcloud_token_emmas_edit` | Hetzner Read&Write token, **emmas-edit** project | `gh secret set HCLOUD_APPLY_TOKEN --env fleet-apply` | `make tofu-plan` |
| `hcloud_token` | Hetzner Read&Write token, **molecule test** project | `gh secret set MOLECULE_HCLOUD_TOKEN` | `make test-hetzner ROLE=motd` |

The read-only `CLOUDFLARE_PLAN_API_TOKEN` and `HCLOUD_PLAN_TOKEN` repo secrets
have no vault copy — mint and `gh secret set` them alone. They serve every
non-push event, not just PR plans: `workflow_dispatch` and the weekly drift check
too. They must mirror the write tokens' scope in *read* form, because a plan
refreshes rulesets, zone settings, DNSSEC and the Hetzner firewall — DNS read
alone is not enough. Verify with `gh workflow run terraform.yml`, not by re-running
an open PR: `discover` skips the plan job for any PR whose non-`.md` diff misses
`terraform/`, and the gate still reports green.

The two `--env fleet-apply` rows need Environments: write on the workstation PAT —
without it `gh secret set --env` 403s on the public-key fetch it must make first.
Grant it, or set those two in Settings → Environments → fleet-apply.

`hcloud_token_emmas_edit` has the widest reach — every OpenTofu run (including the
`hcloud_server` data source behind the emmasedit apex, and rogue-trader's
firewall), `bootstrap/rogue-trader.yml`, `bin/packer.sh`'s MicroOS build and any
ad-hoc `hcloud` CLI read it — but every one resolves the vault at run time, so the
single `ansible-vault edit` covers them all and only the CI copy needs setting
separately. Do not confuse it with `hcloud_token`: two distinct Hetzner tokens for
two different projects, rotated independently. `make test-hetzner` honours an
already-exported `HCLOUD_TOKEN` over the vault, so unset it first or the run proves
nothing about the token you just rotated.

## The vault password (`.vault_pass`)

The master key — it decrypts everything and lives in **three** places that must
stay in lockstep. CI is deliberately not among them: no workflow holds a vault
password, so the vault is operator-only. Keep the old passphrase until every copy
is updated, in one pass:

0. `sudo touch /var/lib/arbites/pause`. Arbites reads `origin/main`, never the
   working tree, so between the rekey and the merge it holds one password and the
   vault another — and a reconcile that cannot decrypt aborts before its first
   task, fleet-wide, raising `ArbitesFailed`.
1. `ansible-vault rekey inventory/group_vars/all/vault.yml` (old → new).
2. Overwrite the local `.vault_pass`, and confirm `make check` decrypts.
3. Commit and merge the re-encrypted vault, so `origin/main` and the new password agree.
4. Re-seed scholam's `/etc/arbites/vault_pass` (0600 root), or the next reconcile cannot decrypt.
5. Update the password manager.
6. `sudo rm /var/lib/arbites/pause`, then confirm the journal shows an *apply* — an
   unchanged HEAD short-circuits to success without ever reading the vault, so
   "the reconcile went green" is not by itself proof it can decrypt.

## Keyless GCP auth — no rotation

GCP auth (the Firebase deploy and the `tofu` plan/apply jobs) is Workload
Identity Federation: GitHub's OIDC token is exchanged for short-lived
credentials each run. There is **no stored key to rotate** — this covers GCP only;
the stored provider tokens above and the repo secrets below are separate.

To revoke access, set `disabled = true` on the service account: an in-place update,
so it lands through the normal PR → merge apply. Removing its `workloadIdentityUser`
binding in `terraform/infra-shared.tf` instead is a *delete*, which CI's
destructive-plan gate refuses and branch protection then blocks — that one needs a
local `make tofu-apply`. Note `tofu_apply_wif` is self-revoking: it strips the
binding CI's own apply identity depends on.

## Out-of-band secrets

Secrets that are not in the vault:

- **Hetzner storage box SSH credential** — held by DSM Hyper Backup on the NAS; nothing in this repo reads it. Rotate in the Hetzner Console and in all three Hyper Backup tasks together — the credential is stored per task, and a missed one fails at its next weekly run (`OffsiteMirrorTaskFailed`, not the 8-day overdue warning). Losing it with the NAS costs a sub-account password reset, not the off-site copy; the `disaster-recovery.md` prerequisite is the Hetzner Console login for the storage box project, which is what buys that back.

- **`/etc/offsite-mirror/id_ed25519`** (auspex) — the off-site coverage probe's own SSH identity, minted by the `offsite_mirror` role and trusted by the NAS account it reads as. It reads Hyper Backup's cached manifests and nothing else, and is not the storage box credential — but the NAS entry carries no prefix that would confine it — `restrict` cuts forwarding, PTYs and `~/.ssh/rc`, not command execution, and a forced `command=` would have to inline the probe's whole payload, which today arrives on stdin as `sh -s` — so it yields a shell as that account, and `synobackup.conf` is world-readable and holds `remote_pass`. Treat it as transitively granting the off-site credential. Rotate by deleting both halves on auspex and re-applying (the `creates:` guard mints a fresh pair), then replacing the old line in the NAS account's `authorized_keys`; DSM is not managed from here, so that half is by hand. Order does not matter much here because the probe fails closed: until the new key is trusted `offsite_mirror_success` reads 0 and `OffsiteMirrorProbeFailed` raises after 25h.

- **`/etc/arbites/ssh/id_arbites`** — the reconcile timer's own SSH identity, distinct from the operator's key so either rotates alone (it cannot be vaulted: the reconciler needs it to reach the fleet). Rotation is fleet-wide, and the public half is declared, not placed by hand: add the new key to `common_ansible_authorized_keys` in `inventory/group_vars/all/authorized_keys.yml` and apply, re-seed the private half via the arbites bootstrap, then confirm a reconcile. Order matters — authorise before switching, or the first host the timer reaches refuses it. **Removing the old key is the same edit:** both declared lists are exclusive, so dropping the entry and applying strips the key from every host, with nothing to delete by hand. That cuts both ways — the old key stops working the moment the converge lands, so do not drop it until the replacement is seeded and a reconcile has been confirmed on the new one. Three first-boot seeds carry it too — `bootstrap/host.sh`, `bootstrap/rogue-trader.bu` and `bootstrap/auspex-user-data.yaml` (where it is unlabelled, so grepping for the comment misses it) — and each needs the same commit; `host.sh` is read from `main`, so the rotation has to be merged before the next rebuild. Skip them and a rebuilt host comes back trusting the retired key and unknown to the timer until a converge strips it. See the role's README.

- **The operator's fleet SSH key** (`~jonny/.ssh/id_ed25519` on scholam) — restore it from the password manager or `scholam-home-backup` on a rebuild, since nothing connects without it (`disaster-recovery.md` scholam step 4). What an operator-run play connects as, and registered with Hetzner Cloud as `rogue-trader-key`. Since arbites took its own identity no timer holds it — but it is still not interactive-only: `claude-remote-control.service` runs as this user with no `SSH_AUTH_SOCK`, and the `unattended-author` pipeline applies through the same path, so **a passphrase breaks both** and an agent loaded in a terminal does not reach a lingering user unit. Leave it bare unless you are prepared to wire an agent into that unit and unlock it at each boot. Rotating it reaches further than the arbites key: it sits in **both** lists in `inventory/group_vars/all/authorized_keys.yml`, and all three of `bootstrap/host.sh`, `bootstrap/rogue-trader.bu` and `bootstrap/auspex-user-data.yaml` seed it at first boot — skip those and a rebuilt host comes back trusting the retired key until a converge strips it, which for auspex is the documented recovery path rather than a remote case.
- **dev workstation claude.ai OAuth token** (`~/.claude/.credentials.json`, under `claudeAiOauth`; the same file holds the MCP server tokens) — rotate by re-running `claude` and `/login` as the dev user; it is a session token, not a vault secret. `~/.claude.json` beside it holds only account metadata and per-project trust — that is the file the `dev` role rewrites under `no_log`, and it carries no token.
- **`CLAUDE_OAUTH_TOKEN`** (repo secret) — the subscription token the `claude review` workflow authenticates with. A distinct credential from the one above, and expiring: when it lapses the `review` job goes red on the next labelled major. Rotate with `claude setup-token`, then `gh secret set CLAUDE_OAUTH_TOKEN`.

- **`AUTOFIX_APP_KEY`** (repo secret) — the GitHub App private key the go.sum autofix mints a short-lived `contents: write` token from, so its amend re-triggers `site-gate`. `AUTOFIX_APP_ID` beside it is public App metadata, not a credential. An App holds up to 25 private keys at once, so the standard order applies: generate the new key in the App's settings, `gh secret set AUTOFIX_APP_KEY`, let one PR prove it, then delete the old key — generating does not revoke. On exposure, suspend or uninstall the App: the workflow's `contents: write` pin binds only tokens it mints, not a holder of the raw key.

- **The two laptop SSH keys** — `jonny@Jonnys-MacBook-Pro.local` and `jonnyoc@corp-mb`, both in `common_authorized_keys` and so both able to open the owner account on scholam, solar and auspex; `bootstrap/auspex-user-data.yaml` seeds both, and the MacBook key is registered at Hetzner Cloud as `jonny-mbp`. A lost or stolen laptop is the likeliest fleet-credential exposure there is. Nothing is minted, so the order is revoke-first: delete the line from the list and apply — the list is exclusive, so that is the revocation. The residues are the auspex seed, since recovery there is a reflash, and the Hetzner registration, which nothing in this repo passes but which is selectable when a server is built by hand in the Console.

- **The workstation's gcloud ADC** (`~/.config/gcloud/application_default_credentials.json`) — an org-owner refresh token the GCS state backend and the google providers authenticate as for any *local* `tofu` run. Keyless CI covers CI, not this. Rotate with `gcloud auth application-default login`, revoke with `... revoke`. A plan erroring `invalid_grant` on `google_project.*` while the Cloudflare and Hetzner diff prints above it is a stale login, not a rotation failure.
