variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token for the jonnyoc account; supply via TF_VAR_cloudflare_api_token (sourced from the vault by bin/vault-var.sh). Never commit it."
}

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token for the emmas-edit project (rogue-trader); supply via TF_VAR_hcloud_token (sourced from the vault by bin/vault-var.sh)."
}

variable "vercel_api_token" {
  type        = string
  sensitive   = true
  description = "Vercel API token for the personal Hobby account (exactis); supply via TF_VAR_vercel_api_token (sourced from the vault by bin/vault-var.sh). Never commit it."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "Fine-grained GitHub token on jedimasterjonny/exactis (Administration: read to plan, read and write to apply); supply via TF_VAR_github_token (sourced from the vault by bin/vault-var.sh)."
}
