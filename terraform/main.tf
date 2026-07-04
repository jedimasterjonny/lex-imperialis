terraform {
  required_version = ">= 1.12.0"

  # Remote state and locking in HCP Terraform (Terraform Cloud) with local,
  # CLI-driven execution. Organization and workspace come from the environment
  # (TF_CLOUD_ORGANIZATION, TF_WORKSPACE), so no account topology is committed to
  # this public repo; export them before `tofu init`.
  cloud {}

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.66"
    }
  }
}
