provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Wired for the cross-provider VM->DNS work to come; stays unconfigured (its
# token unneeded) until a resource uses it.
provider "hcloud" {
  token = var.hcloud_token
}
