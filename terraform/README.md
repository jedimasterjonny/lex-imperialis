# terraform

OpenTofu (`tofu`) configuration for cloud infrastructure — Cloudflare and Hetzner
in one state, so a Hetzner VM's IP can feed a Cloudflare DNS record directly.
Currently manages the `jonnyoc.uk`, `jonnyoc.co.uk`, and `emmasedit.com`
Cloudflare zones — one `dns-<zone>.tf` per zone, plus an `edge-<zone>.tf` per zone
for its non-DNS config (settings and rulesets): canonical-redirect rulesets for all
three zones, and `emmasedit.com`'s WordPress TLS, security, caching, and
request-filtering posture — the last a WAF block on backup-file and dotfile
scans, a WAF challenge on the login/XML-RPC, a per-IP rate limit on the login,
and Authenticated Origin Pulls so the origin can refuse anything that did not
come through this edge. Not
every record or setting is managed: an origin IP with no Terraform-visible source,
or a setting the provider reports read-only (Email Routing, Tiered Cache on Free),
is left out and noted in the file's header.

`r2-reclusiam.tf` is the one account-scoped Cloudflare resource: an R2 bucket,
`reclusiam`, standing as the backups' second off-site copy, a last resort behind
the NAS repos and the Hetzner storage box. It is hinted to `weur` — the storage
box is in Finland, so the two off-site copies do not share a region. Two DSM
Hyper Backup tasks write to it, with a hand-minted S3 credential held in the NAS
task config — not here, where it would land in state, and not in the vault,
which holds only the `r2_mirror` probe's read-only pair. Both provider tokens
need Account | Workers R2 Storage — Edit to apply, Read to plan.

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
billing changes, which stay local operator applies), and a fourth identity in
`jedimasterjonny/exactis` impersonates the CI runner provisioning SA in
`ci-runners.tf`. The pool/provider trust an explicit list of repositories — not
the owner, so a new repo under it federates in only by an edit here — and the
per-SA bindings then pin which single repo may impersonate each SA. `outputs.tf`
exposes the provider resource name and the SA emails for the workflows' `auth`
steps.

`ci-runners.tf` is the permanent side of the ephemeral GitHub Actions runners
for `jedimasterjonny/exactis`: a custom-mode VPC (`ci-runners`) with one subnet
(`ci-runners-europe-west1`) and one ingress rule (`ci-runners-iap-ssh`, tcp:22
from IAP's `35.235.240.0/20` and nothing else — admin access is a
`--tunnel-through-iap` tunnel, never a public port). The VMs themselves are not
managed here; a workflow in that repo creates one per job and deletes it at the
end. Two cost decisions are load-bearing: no Cloud NAT (the runners take an
ephemeral external IP for egress to github.com, nodejs.org, bun.sh and npm,
which bills nothing where a NAT gateway bills per hour and per GB), and no
Private Google Access, which that makes redundant. Inbound is shut by the
absence of any ingress rule but the IAP one.

Runner shape is measured, not chosen: `n4a-standard-8` (Axion, ARM64) on a
`hyperdisk-balanced` boot disk (N4A refuses pd-balanced) from the
`ubuntu-2404-lts-arm64` family, in `europe-west1` zones **b and c only** —
not `-d`, which offers no N4A machine type at all, and not `europe-north1`,
where the state bucket sits, which offers none either. Concurrency caps at
**four** runners: the binding quota is `CPUS_ALL_REGIONS` at 32, not the N4A
per-family quota of 200. A fifth concurrent job queues rather than fails. If
that ceiling starts to bite, the fix is a quota-increase request for
`CPUS_ALL_REGIONS` on
`jonnyoc-infra-shared` in the Cloud console — not a change to this config, which
sets no quota and cannot.

Two service accounts, and the gap between them is the point.
`exactis-ci-runner` is the provisioning identity the workflow federates in as
(`roles/compute.instanceAdmin.v1`, the narrowest predefined role covering an
instance create); `exactis-ci-runner-vm` is attached to the VM and holds two
things only, because a runner executes whatever a workflow in that repo says
and its metadata token is reachable by that code. Those two are
`roles/logging.logWriter`, and a one-permission custom role
(`compute.instances.delete`) that lets the runner delete itself when its work
is done — the difference between a finished VM vanishing in seconds and
waiting up to an hour for the reaper while a 100GB hyperdisk bills.

That delete is **conditioned, not project-wide**:
`resource.name.extract('/instances/{name}').startsWith('exactis-ci-')`, the
prefix the runner workflow names its VMs with. IAM offers no "this instance
and no other" attribute, so the binding is per-kind rather than per-machine —
one runner could delete another, which is a set the reaper deletes wholesale
regardless. It also offers no `contains()`, only `startsWith`, `endsWith` and
`extract`, which is why the name is extracted rather than matched in place.

The project's default compute SA carries Google's automatic `roles/editor` and
is attached to any VM created without an explicit one — so the provisioning SA
is granted `iam.serviceAccounts.actAs` on the runner VM SA **and no other
account**. A create that omits `--service-account` is then refused for want of
`actAs` on the default, rather than silently handed an editor token. That
binding, not the workflow's good manners, is what keeps editor off the runners.

`ci-runners-reaper.tf` is the orphan sweep. A runner is deleted by the same
workflow that created it, so a cancelled job, a runner that never registers, or
a workflow that dies mid-run leaves an `n4a-standard-8` billing indefinitely
with nothing to notice. A Cloud Scheduler job pokes a Cloud Run job every
fifteen minutes; it deletes any instance labelled `purpose=exactis-ci` created
more than sixty minutes ago, so a leak costs at most about seventy-five
minutes. The container is a pinned public `google-cloud-cli` image running nine
lines of shell — no source archive, no Cloud Build, no Artifact Registry repo
of ours, and the pin is renovate-tracked like every other image here. The
identity is a custom role of seven permissions: it can list and delete
instances and poll the resulting operation, and deliberately **cannot create
one**.

The sweep keys on the label rather than on a self-destruct, because
`max_run_duration` + `instance_termination_action = DELETE` is set at create
time by the very code whose failure the sweep exists to survive. The workflow
should still pass both — belt there, braces here. Known gap: nothing alerts on
a failed reaper execution (auspex's Prometheus watches the fleet, not GCP), so
a sustained failure surfaces as a surprising bill rather than as a page.

State lives in a GCS bucket (`google_storage_bucket.tofu_state` in
`infra-shared.tf` — `EUROPE-NORTH1`, versioned, UBLA + public-access-prevention),
wired by the `backend "gcs"` in `main.tf`: remote state and locking, local
CLI-driven execution. The backend authenticates like the google provider — your
gcloud ADC locally, WIF in CI — so there is no state token, and the read-only
`tofu-plan` SA can read state while only the write `tofu-apply` SA can write it.
Only the Cloudflare and Hetzner provider tokens come from the vault (locally —
in CI the read-only plan tokens are plain repo secrets, and only the write apply
tokens are `Segmentum Obscurus` environment secrets):

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
infra and fails on any drift. State (GCS) and GCP are keyless via WIF; in CI the
plan authenticates with read-only Cloudflare/Hetzner tokens (plain repo secrets —
a PR can't mutate with them), while the apply's write tokens are environment
secrets gated to the main-only `Segmentum Obscurus` environment, so no PR can read one
and CI never touches the vault. `make tofu-apply` still
applies locally for the rare change CI won't: project creation, billing, the
state bucket, or a deliberate delete/replace.

One more belongs on that list, and it is easy to miss: **a change that widens
the `tofu-apply` SA's own roles cannot reliably be applied by CI**. The grant
and the resources it authorises land in the same apply, with no dependency edge
forcing an order and IAM propagation lagging behind the write that made it — so
the create races the grant and 403s. A re-run usually succeeds once the grant
has settled, but the first apply carrying new `tofu_apply` bindings is an
operator's `make tofu-apply`, not CI's. The `ci-runners` files are exactly this
case: they add `compute.networkAdmin`, `compute.securityAdmin`, `run.admin`,
`cloudscheduler.admin` and `iam.roleAdmin` to that SA and then use all five.

The gates need `tofu` and `tflint` on PATH — provisioned in CI by
`setup-opentofu`/`setup-tflint`, and on the workstation by the `dev` role
(OpenTofu from zypper, tflint pinned to the CI version). Elsewhere, install by
hand: `zypper install opentofu`, and tflint's pinned release (the version in
`.github/workflows/lint.yml`) via its upstream script. `tofu validate` fetches
the providers into the gitignored `.terraform/` on first run, so the initial
validate needs network.

`.terraform.lock.hcl` is committed; `.terraform/` and any state or `*.tfvars`
are gitignored.
