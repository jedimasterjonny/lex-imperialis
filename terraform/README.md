# terraform

OpenTofu (`tofu`) configuration for cloud infrastructure — Cloudflare and Hetzner
in one workspace, so a Hetzner VM's IP can feed a Cloudflare DNS record directly.
Currently manages the `jonnyoc.uk` Cloudflare zone.

State lives in HCP Terraform (Terraform Cloud): remote state and locking, local
CLI-driven execution (org `jonnyoc`, workspace `jonnyoc-master`, both pinned in
the `cloud` block). Both tokens come from the vault — no `tofu login` needed:

    export TF_TOKEN_app_terraform_io="$(bin/vault-var.sh terraform_hcp_token)"
    export TF_VAR_cloudflare_api_token="$(bin/vault-var.sh terraform_cloudflare_api_token)"
    tofu -chdir=terraform init
    tofu -chdir=terraform plan

The Hetzner token defaults empty and is only needed once Terraform manages
Hetzner resources (`TF_VAR_hcloud_token`).

Gates (also enforced in CI and pre-commit):

    tofu fmt -check -recursive terraform
    bin/tofu-validate.sh          # tofu init -backend=false && tofu validate
    tflint --chdir=terraform      # bundled terraform ruleset; see .tflint.hcl

`make tofu-fmt` / `tofu-validate` / `tofu-lint` wrap these (fmt writes); `make
tofu-plan` / `tofu-apply` drive HCP Terraform Cloud, sourcing both tokens from
the vault via `bin/vault-var.sh`.

PRs touching `terraform/` get a `tofu plan` in CI
(`.github/workflows/terraform.yml`), posted as a PR comment; it authenticates to
HCP and Cloudflare from the vault, so `VAULT_PASSWORD` is the only CI secret.
Applies stay manual (`make tofu-apply`).

The gates need `tofu` and `tflint` on PATH — provisioned in CI by
`setup-opentofu`/`setup-tflint`, and on the workstation by the `dev` role
(OpenTofu from zypper, tflint pinned to the CI version). Elsewhere, install by
hand: `zypper install opentofu`, and tflint's pinned release (the version in
`.github/workflows/lint.yml`) via its upstream script. `tofu validate` fetches
the providers into the gitignored `.terraform/` on first run, so the initial
validate needs network.

`.terraform.lock.hcl` is committed; `.terraform/` and any state or `*.tfvars`
are gitignored.
