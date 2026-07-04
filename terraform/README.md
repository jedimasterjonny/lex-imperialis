# terraform

OpenTofu (`tofu`) configuration for cloud infrastructure. Scaffold only — no
resources yet.

State lives in HCP Terraform (Terraform Cloud): remote state and locking, local
CLI-driven execution. The `cloud {}` block reads its target from the
environment, so no account topology is committed:

    export TF_CLOUD_ORGANIZATION=<org>
    export TF_WORKSPACE=<workspace>
    tofu login app.terraform.io   # one-time; or set TF_TOKEN_app_terraform_io
    tofu init

Create the workspace in HCP Terraform first. Supply the Hetzner token as
`TF_VAR_hcloud_token` for local execution (or a sensitive workspace variable if
you switch to remote runs) — never commit it; this repo is public.

Gates (also enforced in CI and pre-commit):

    tofu fmt -check -recursive terraform
    bin/tofu-validate.sh          # tofu init -backend=false && tofu validate
    tflint --chdir=terraform      # bundled terraform ruleset; see .tflint.hcl

`make tofu-fmt` / `tofu-validate` / `tofu-lint` wrap these (fmt writes); `make
tofu-plan` / `tofu-apply` drive HCP Terraform Cloud after `tofu init`.

The gates need `tofu` and `tflint` on PATH — provisioned in CI by
`setup-opentofu`/`setup-tflint`. Locally, `tofu` comes from zypper
(`zypper install opentofu`); `tflint` has no zypper package, so install the
pinned release binary (the version in `.github/workflows/lint.yml`), which
renovate keeps current. `tofu validate` fetches the hcloud provider into the
gitignored `.terraform/` on first run, so the initial validate needs network.

`.terraform.lock.hcl` is committed; `.terraform/` and any state or `*.tfvars`
are gitignored.
