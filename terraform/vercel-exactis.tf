# exactis — a Next.js app (GitHub repo in github-exactis.tf) on a personal Vercel
# Hobby account, Neon Postgres behind it. Two projects on the one repo: Hobby has
# no custom environments, so dev is a second project whose production branch is
# `dev`. Both were built by hand on 2026-10-24 and imported, not created.
#
# NOT managed here:
#   - The environment variables (DATABASE_URL, SESSION_PASSWORD, APP_PASSWORD_HASH;
#     Production, Sensitive) — their values would land in state. The deprecated
#     inline `environment` attribute stays unset: the provider then neither lists
#     nor diffs them, so no plan can propose removing them. Never add it, nor a
#     vercel_project_environment_variable(s) resource.
#   - Neon. Its roles are created in SQL (an API-created role joins
#     neon_superuser); branch resets and migrations are app-repo scripts.
#   - Protection bypass for automation: off, which is the absence of a
#     vercel_project_protection_bypass resource. Password protection and trusted
#     IPs are off by leaving their attributes unset.

locals {
  # Vercel project => production branch.
  exactis_projects = {
    exactis       = "main"
    "exactis-dev" = "dev"
  }
}

# Hobby has no team, so the import id is the bare project id (Settings → General).
import {
  to = vercel_project.exactis["exactis"]
  id = "exactis"
}

import {
  to = vercel_project.exactis["exactis-dev"]
  id = "exactis-dev"
}

resource "vercel_project" "exactis" {
  for_each = local.exactis_projects

  name      = each.key
  framework = "nextjs"

  git_repository = {
    type              = "github"
    repo              = "jedimasterjonny/exactis"
    production_branch = each.value
  }

  # Vercel's bun would otherwise re-resolve a lockfile CI never tested.
  install_command = "bun install --frozen-lockfile"
  node_version    = "24.x"

  # The app repo's script builds only the production branch, and only for a diff
  # that reaches the build; it replaces the "Only build production" preset.
  ignore_command = "bash scripts/vercel-ignore.sh"

  # The Neon project is in eu-central-1.
  resource_config = {
    function_default_regions = ["fra1"]
  }

  # The app has one shared password with no 2FA or rate limit, so Vercel's login
  # is the front door — on every deployment, production included.
  vercel_authentication = {
    deployment_type = "all_deployments"
  }

  lifecycle {
    prevent_destroy = true
  }
}
