# infra-shared — a dedicated project that hosts the Workload Identity Federation
# pool letting GitHub Actions authenticate to GCP with no service-account keys.
# Kept separate from workload projects (jonnyoc-website) so the identity plumbing
# has one home and can serve more repos later.
#
# The project *id* is prefixed because the bare "infra-shared" is globally taken;
# the display name is the requested "infra-shared".
#
# Three CI identities federate in from jedimasterjonny/lex-imperialis:
#   - the Firebase Hosting deploy, impersonating the deploy SA in jonnyoc-website
#   - `tofu plan` on a PR, impersonating the read-only tofu-plan SA created here
#   - `tofu apply` on merge to main, impersonating the write tofu-apply SA here
# The pool/provider trusts the whole owner; the per-SA bindings pin the exact
# repo — and, for the write tofu-apply SA, the main branch — that may impersonate
# each SA.

locals {
  infra_shared_services = [
    "iam.googleapis.com",
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudbilling.googleapis.com",
  ]
  github_owner = "jedimasterjonny"
  github_repo  = "jedimasterjonny/lex-imperialis"

  # The exact-repo principal the tofu-plan and deploy SA bindings trust (they run
  # on PRs too); the write tofu-apply SA gets the tighter repo + main-branch one.
  github_repo_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${local.github_repo}"
  github_main_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_ref/${local.github_repo}@refs/heads/main"
}

resource "google_project" "infra_shared" {
  name            = "infra-shared"
  project_id      = "jonnyoc-infra-shared"
  org_id          = "983523067919"
  billing_account = "016014-E934D1-BF77DC"

  auto_create_network = false
  deletion_policy     = "DELETE"

  # Hosts the WIF pool + CI SAs the whole keyless pipeline depends on, and
  # tofu-apply can't recreate it (no project-create). Guard against an accidental
  # or auto-apply teardown; deletion_policy stays DELETE so a deliberate rebuild
  # just removes this guard first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_service" "infra_shared" {
  for_each = toset(local.infra_shared_services)

  project            = google_project.infra_shared.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Workload Identity Federation: GitHub OIDC ---------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.infra_shared.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for GitHub Actions in jedimasterjonny repos."

  depends_on = [google_project_service.infra_shared]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.infra_shared.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    # repo@ref composite, for the main-only tofu-apply binding below.
    "attribute.repository_ref" = "assertion.repository + '@' + assertion.ref"
  }

  # Only tokens minted for this owner's repos are accepted at all; the per-SA
  # bindings below further restrict to the exact repository.
  attribute_condition = "assertion.repository_owner == '${local.github_owner}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- Deploy SA (in jonnyoc-website): let the repo impersonate it ----------

resource "google_service_account_iam_member" "github_action_wif" {
  service_account_id = google_service_account.github_action.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_repo_principal
}

# --- Read-only SA for `tofu plan` in CI ----------------------------------

resource "google_service_account" "tofu_plan" {
  project      = google_project.infra_shared.project_id
  account_id   = "tofu-plan"
  display_name = "OpenTofu plan (CI, read-only)"
  description  = "Read-only identity for `tofu plan` in lex-imperialis CI, impersonated via WIF from ${local.github_repo}."

  # iam.googleapis.com must be on before the SA can be created (from-zero).
  depends_on = [google_project_service.infra_shared]
}

resource "google_service_account_iam_member" "tofu_plan_wif" {
  service_account_id = google_service_account.tofu_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_repo_principal
}

# Read access for the plan SA across the two managed projects + the billing
# account (google_project refreshes its billing_account), plus serviceusage on
# jonnyoc-website because the provider routes quota there (user_project_override).
resource "google_project_iam_member" "tofu_plan_reads" {
  for_each = {
    "website/viewer"       = { project = google_project.website.project_id, role = "roles/viewer" }
    "website/firebase"     = { project = google_project.website.project_id, role = "roles/firebase.viewer" }
    "website/serviceusage" = { project = google_project.website.project_id, role = "roles/serviceusage.serviceUsageConsumer" }
    "infra-shared/viewer"  = { project = google_project.infra_shared.project_id, role = "roles/viewer" }
  }

  project = each.value.project
  role    = each.value.role
  member  = google_service_account.tofu_plan.member
}

resource "google_billing_account_iam_member" "tofu_plan_billing_viewer" {
  billing_account_id = "016014-E934D1-BF77DC"
  role               = "roles/billing.viewer"
  member             = google_service_account.tofu_plan.member
}

# --- Write SA for `tofu apply` on merge to main --------------------------
#
# The ungated auto-apply identity. Its roles are the least privilege that lets
# an apply manage every resource in this config *in steady state* — enable APIs,
# set project IAM, manage service accounts and the WIF pool, and administer
# Firebase. Deliberately withheld: project create/delete (no org-level
# resourcemanager role) and billing changes (billing.viewer, read-only). Those
# rarer, higher-blast-radius acts stay local operator applies and fail closed in
# CI. Scope is the two managed projects only — never the org or other projects.

resource "google_service_account" "tofu_apply" {
  project      = google_project.infra_shared.project_id
  account_id   = "tofu-apply"
  display_name = "OpenTofu apply (CI, write)"
  description  = "Write identity for `tofu apply` on merge to main in lex-imperialis CI, impersonated via WIF from ${local.github_repo}."

  # iam.googleapis.com must be on before the SA can be created (from-zero).
  depends_on = [google_project_service.infra_shared]
}

resource "google_service_account_iam_member" "tofu_apply_wif" {
  service_account_id = google_service_account.tofu_apply.name
  role               = "roles/iam.workloadIdentityUser"
  # Main-branch only: a PR branch (which could edit terraform.yml) can't reach it.
  member = local.github_main_principal
}

resource "google_project_iam_member" "tofu_apply" {
  for_each = {
    # jonnyoc-website: APIs, project IAM, service accounts, Firebase. viewer for
    # refresh; serviceUsageConsumer because user_project_override routes quota here.
    "website/viewer"          = { project = google_project.website.project_id, role = "roles/viewer" }
    "website/serviceusage"    = { project = google_project.website.project_id, role = "roles/serviceusage.serviceUsageAdmin" }
    "website/usageconsumer"   = { project = google_project.website.project_id, role = "roles/serviceusage.serviceUsageConsumer" }
    "website/projectiam"      = { project = google_project.website.project_id, role = "roles/resourcemanager.projectIamAdmin" }
    "website/serviceaccounts" = { project = google_project.website.project_id, role = "roles/iam.serviceAccountAdmin" }
    "website/firebase"        = { project = google_project.website.project_id, role = "roles/firebase.admin" }
    # infra-shared: APIs, project IAM, service accounts, the WIF pool.
    "infra-shared/viewer"          = { project = google_project.infra_shared.project_id, role = "roles/viewer" }
    "infra-shared/serviceusage"    = { project = google_project.infra_shared.project_id, role = "roles/serviceusage.serviceUsageAdmin" }
    "infra-shared/projectiam"      = { project = google_project.infra_shared.project_id, role = "roles/resourcemanager.projectIamAdmin" }
    "infra-shared/serviceaccounts" = { project = google_project.infra_shared.project_id, role = "roles/iam.serviceAccountAdmin" }
    "infra-shared/wif"             = { project = google_project.infra_shared.project_id, role = "roles/iam.workloadIdentityPoolAdmin" }
  }

  project = each.value.project
  role    = each.value.role
  member  = google_service_account.tofu_apply.member
}

# Read-only on billing so an apply can refresh the billing_account attribute and
# the plan SA's billing binding; changing billing IAM stays a local operator act.
resource "google_billing_account_iam_member" "tofu_apply_billing_viewer" {
  billing_account_id = "016014-E934D1-BF77DC"
  role               = "roles/billing.viewer"
  member             = google_service_account.tofu_apply.member
}
