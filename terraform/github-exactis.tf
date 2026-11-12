# jedimasterjonny/exactis — the app repo behind the Vercel projects in
# vercel-exactis.tf. Imported as found on 2026-10-24; attributes left unset
# already match the provider default or are computed.
#
# Rebase is the only merge method. No branch protection or ruleset, deliberately:
# do not add one.

import {
  to = github_repository.exactis
  id = "exactis"
}

import {
  to = github_branch_default.exactis
  id = "exactis"
}

resource "github_repository" "exactis" {
  name         = "exactis"
  visibility   = "public"
  homepage_url = "https://exactis-dev.vercel.app"
  has_issues   = true
  has_projects = true

  allow_merge_commit = false
  allow_squash_merge = false
  allow_rebase_merge = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_branch_default" "exactis" {
  repository = github_repository.exactis.name
  branch     = "main"
}
