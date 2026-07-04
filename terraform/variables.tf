variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Supply via TF_VAR_hcloud_token (local execution) or an HCP Terraform sensitive workspace variable; never commit it."
}
