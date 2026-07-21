# terraform

OpenTofu (`tofu`) configuration for cloud infrastructure — Cloudflare and Hetzner
in one state, so a Hetzner VM's IP can feed a Cloudflare DNS record directly.
Currently manages the `jonnyoc.uk`, `jonnyoc.co.uk`, and `emmasedit.com`
Cloudflare zones — one `dns-<zone>.tf` per zone, plus an `edge-<zone>.tf` per zone
for its non-DNS config (settings and rulesets): canonical-redirect rulesets for the
two jonnyoc zones, and `emmasedit.com`'s WordPress TLS, security, caching, and
login-protection posture — the last a WAF challenge on the login/XML-RPC plus a
per-IP rate limit. Not
every record or setting is managed: an origin IP with no Terraform-visible source,
or a setting the provider reports read-only (Email Routing, Tiered Cache on Free),
is left out and noted in the file's header.

`firewall-rogue-trader.tf` and an `hcloud_server` data source (in
`dns-emmasedit-com.tf`) are the Hetzner side: the data source reads rogue-trader's
live IP to set the `emmasedit.com` apex A/AAAA — fetching at plan time the origin
IP Cloudflare's proxy hides, so it is never committed — and its server id attaches
rogue-trader's `vpc-firewall`, moved here from the Ansible bootstrap.

`firebase-jonnyoc-website.tf` adds the Google side: the `jonnyoc-website` GCP
project that serves the `jonnyoc.uk` apex from Firebase Hosting — the project
itself, its prerequisite APIs, the Firebase enablement, the Hosting site, and the
GitHub Actions deploy service account with its IAM. Only *infrastructure* is
managed; Remote Config, deployed Hosting content, and Auth data have no Terraform
resource and stay in the Firebase CLI / the site's repo (the file header lists
the commands). `google_project` carries `prevent_destroy` + `deletion_policy =
"PREVENT"` so the retained project can't be torn down by accident.

`infra-shared.tf` is the keyless-CI plumbing: a dedicated `jonnyoc-infra-shared`
project holding a Workload Identity Federation pool that lets GitHub Actions
authenticate to GCP with no service-account keys. Three CI identities in
`jedimasterjonny/lex-imperialis` federate in — the Firebase Hosting deploy
impersonates the deploy SA in `jonnyoc-website`, a PR's `tofu plan` impersonates
a read-only `tofu-plan` SA, and a merge's `tofu apply` impersonates a write
`tofu-apply` SA (scoped to the two managed projects — no project create/delete or
billing changes, which stay local operator applies). The pool/provider trust the
whole owner; per-SA bindings pin the exact repo. `outputs.tf` exposes the
provider resource name and the SA emails for the workflows' `auth` steps.

State lives in a GCS bucket (`google_storage_bucket.tofu_state` in
`infra-shared.tf` — `EUROPE-NORTH1`, versioned, UBLA + public-access-prevention),
wired by the `backend "gcs"` in `main.tf`: remote state and locking, local
CLI-driven execution. The backend authenticates like the google provider — your
gcloud ADC locally, WIF in CI — so there is no state token, and the read-only
`tofu-plan` SA can read state while only the write `tofu-apply` SA can write it.
Only the Cloudflare and Hetzner provider tokens come from the vault:

    export TF_VAR_cloudflare_api_token="$(bin/vault-var.sh terraform_cloudflare_api_token)"
    export TF_VAR_hcloud_token="$(bin/vault-var.sh hcloud_token_emmas_edit)"
    tofu -chdir=terraform init
    tofu -chdir=terraform plan

`TF_VAR_hcloud_token` is the emmas-edit project's Hetzner token — it backs the
`hcloud_server` data source and `vpc-firewall` above.

The Google provider reads credentials by execution context: locally it uses your
own Application Default Credentials — run `gcloud auth application-default login`
once with an org-owner account; in CI it reads
short-lived credentials from WIF — the read-only `tofu-plan` SA on a PR, the
write `tofu-apply` SA on a merge (see `infra-shared.tf`) — so no key ever leaves
GCP. A from-zero rebuild has a bootstrap wrinkle: `user_project_override` +
`billing_project = "jonnyoc-website"` bills quota to that project on every call,
including `google_project.website`'s own create — which fails because the quota
project does not exist yet. So create it with the override temporarily off, then
apply the rest normally:

    # comment out user_project_override + billing_project in providers.tf, then:
    tofu -chdir=terraform apply -target=google_project.website
    # restore providers.tf, then:
    tofu -chdir=terraform apply

The WIF pool, provider, and SAs (`infra-shared.tf`) are part of that full apply,
and both GitHub Actions workflows' `auth` steps fail until they exist live — so a
from-zero rebuild must run the local apply before CI can authenticate.

The state bucket has its own chicken-and-egg: `backend "gcs"` can't create the
bucket that holds its own state, and that bucket lives in the infra-shared project
this config also creates. From zero, init with the backend block commented out
(local state), apply enough to create the project and
`google_storage_bucket.tofu_state`, then restore the backend block and
`tofu -chdir=terraform init -migrate-state` to move the local state into the
bucket. Thereafter the bucket itself is, like the WIF pool, local-apply-only (the
apply SA writes state objects but can't create or reconfigure the bucket).

Gates (also enforced in CI and pre-commit):

    tofu fmt -check -recursive terraform
    bin/tofu-validate.sh          # tofu init -backend=false && tofu validate
    tflint --chdir=terraform      # bundled terraform ruleset; see .tflint.hcl

`make tofu-fmt` / `tofu-validate` / `tofu-lint` wrap these (fmt writes); `make
tofu-plan` / `tofu-apply` reach GCS state through your ADC, sourcing the two
provider tokens from the vault via `bin/vault-var.sh`.

PRs touching `terraform/` (or this workflow) get a `tofu plan` in CI
(`.github/workflows/terraform.yml`), posted as a PR comment; a merge to main
plans, then applies that saved plan file rather than re-planning at apply. The
plan is scanned for a delete or replace: finding one fails the required
`terraform-gate` check on a PR (blocking an automerge) and halts before the apply
on a merge — so a destructive plan never applies unattended, while a routine
in-place bump flows through. A weekly scheduled run plans `main` against live
infra and fails on any drift. State (GCS) and GCP are reached keylessly via WIF,
while the Cloudflare and Hetzner provider tokens come from the vault, so
`VAULT_PASSWORD` stays these workflows' only secret. `make tofu-apply` still
applies locally for the rare change CI won't: project creation, billing, the
state bucket, or a deliberate delete/replace.

The gates need `tofu` and `tflint` on PATH — provisioned in CI by
`setup-opentofu`/`setup-tflint`, and on the workstation by the `dev` role
(OpenTofu from zypper, tflint pinned to the CI version). Elsewhere, install by
hand: `zypper install opentofu`, and tflint's pinned release (the version in
`.github/workflows/lint.yml`) via its upstream script. `tofu validate` fetches
the providers into the gitignored `.terraform/` on first run, so the initial
validate needs network.

`.terraform.lock.hcl` is committed; `.terraform/` and any state or `*.tfvars`
are gitignored.
