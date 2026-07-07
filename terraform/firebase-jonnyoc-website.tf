# Firebase project jonnyoc-website — the apex jonnyoc.uk is served from its
# Firebase Hosting site (the apex A record in dns-jonnyoc-uk.tf points at
# Firebase Hosting, DNS-only). This file captures the *infrastructure* so the
# project is fully rebuildable from zero: the GCP project itself, the Firebase
# enablement, the Hosting site, and the GitHub Actions deploy service account
# with its IAM.
#
# NOT captured here — no Terraform resource exists, so manage these with the
# Firebase CLI or from the site's own repo:
#   - Remote Config parameters  ->  firebase remoteconfig:get   (export as JSON)
#   - Deployed Hosting content   ->  firebase deploy             (from the repo)
#   - Auth users / FCM tokens    ->  runtime data
#
# Firebase Auth / Identity Platform sign-in config is also not managed: the
# project has no registered app and no configured providers today. If that
# changes, add a google_identity_platform_config resource here.

locals {
  firebase_project_id = "jonnyoc-website"

  # Curated prerequisite APIs — the products this project actually uses, enabled
  # explicitly so a from-zero apply turns them on before the resources that need
  # them (securetoken and firebaseinstallations auto-enable as dependencies).
  # Deliberately NOT a snapshot of every API currently on the project.
  firebase_services = [
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "identitytoolkit.googleapis.com",
    "fcm.googleapis.com",
    "firebaseremoteconfig.googleapis.com",
    "firebaserules.googleapis.com",
    # The provider routes all quota here (user_project_override + billing_project),
    # so refreshing any google_project needs Resource Manager enabled here.
    "cloudresourcemanager.googleapis.com",
    # Required to manage the deploy service account and its IAM below.
    "iam.googleapis.com",
    # Required so the GitHub Actions deploy can impersonate the deploy SA via WIF
    # — iamcredentials.generateAccessToken runs against the SA's own project.
    "iamcredentials.googleapis.com",
    # Required for this config to manage the project's billing_account.
    "cloudbilling.googleapis.com",
  ]

  # Roles held by the CI deploy service account (GitHub Actions in
  # jedimasterjonny/lex-imperialis). Trimmed to what a static Hosting deploy
  # needs: the Firebase wizard's default bundle also granted firebaseauth.admin,
  # cloudfunctions.developer, and run.viewer — dropped as excess privilege on a
  # WIF-impersonable identity. apiKeysViewer stays as deploy-support (the CLI
  # reads the web app config). Additive bindings only.
  github_action_roles = [
    "roles/firebasehosting.admin",
    "roles/serviceusage.apiKeysViewer",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

# --- The project itself ---------------------------------------------------

resource "google_project" "website" {
  name            = "jonnyoc-website"
  project_id      = local.firebase_project_id
  org_id          = "983523067919"
  billing_account = "016014-E934D1-BF77DC"

  # Set and owned by Firebase itself (google_firebase_project); declared to match
  # live state so a from-zero create matches. Firebase may flip these at runtime
  # (e.g. firebase-core) — lifecycle.ignore_changes below lets that drift pass.
  labels = {
    "firebase"      = "enabled"
    "firebase-core" = "disabled"
  }

  # The org enforced skipDefaultNetworkCreation; keep the project network-free so
  # a rebuild matches. auto_create_network is a create-time-only field.
  auto_create_network = false

  # Belt-and-braces against accidental teardown of the one retained project:
  # deletion_policy blocks the delete API call, prevent_destroy blocks the plan.
  deletion_policy = "PREVENT"
  lifecycle {
    prevent_destroy = true
    # The merge auto-apply SA can't update project metadata; ignore Firebase's
    # label drift so it never 403s the whole apply.
    ignore_changes = [labels]
  }
}

# --- Prerequisite service APIs -------------------------------------------

resource "google_project_service" "firebase" {
  for_each = toset(local.firebase_services)

  project = google_project.website.project_id
  service = each.value

  # Never disable an API on destroy — avoids cascading breakage of other work.
  disable_on_destroy = false
}

# --- Firebase enablement + Hosting ---------------------------------------

resource "google_firebase_project" "website" {
  provider = google-beta
  project  = google_project.website.project_id

  depends_on = [google_project_service.firebase]
}

# The default Hosting site; jonnyoc.uk and jonnyoc-website.web.app resolve here.
# `firebase deploy` pushes content to it — the content itself is not managed.
resource "google_firebase_hosting_site" "website" {
  provider = google-beta
  project  = google_project.website.project_id
  site_id  = "jonnyoc-website"

  depends_on = [google_firebase_project.website]
}

# --- CI deploy service account -------------------------------------------

resource "google_service_account" "github_action" {
  project      = google_project.website.project_id
  account_id   = "github-action-815812811"
  display_name = "GitHub Actions (jedimasterjonny/lex-imperialis)"
  description  = "A service account with permission to deploy to Firebase Hosting and Cloud Functions for the GitHub repository jedimasterjonny/lex-imperialis"

  # iam.googleapis.com must be on before the SA can be created (from-zero).
  depends_on = [google_project_service.firebase]
}

resource "google_project_iam_member" "github_action" {
  for_each = toset(local.github_action_roles)

  project = google_project.website.project_id
  role    = each.value
  member  = google_service_account.github_action.member
}
