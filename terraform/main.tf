terraform {
  required_version = "~> 1.12"

  # Remote state and locking in a GCS bucket in the infra-shared project, local
  # CLI-driven execution. One state for the whole homelab — Cloudflare and Hetzner
  # share it so a Hetzner VM's IP can feed a Cloudflare DNS record directly. The
  # backend authenticates with the same credentials as the google provider (ADC
  # locally, WIF in CI), so no separate state token: the read-only tofu-plan SA
  # reads state on a PR and the write tofu-apply SA writes it on a merge. The
  # bucket is defined in infra-shared.tf; the backend can't interpolate, so its
  # name is repeated here as a literal.
  backend "gcs" {
    bucket = "jonnyoc-infra-shared-tofu-state"
    prefix = "master"
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.21"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.34"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.34"
    }
  }
}
