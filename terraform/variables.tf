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
