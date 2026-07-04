terraform {
  required_version = ">= 1.12.0"

  # Remote state and locking in HCP Terraform (Terraform Cloud), local CLI-driven
  # execution. One workspace for the whole homelab — Cloudflare and Hetzner share
  # state so a Hetzner VM's IP can feed a Cloudflare DNS record directly.
  cloud {
    # OpenTofu has no default cloud hostname (HashiCorp Terraform does), so it is
    # required here.
    hostname     = "app.terraform.io"
    organization = "jonnyoc"

    workspaces {
      name = "jonnyoc-master"
    }
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
  }
}
