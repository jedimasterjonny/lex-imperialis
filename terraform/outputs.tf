# Values needed to configure the GitHub Actions `google-github-actions/auth`
# step (workload_identity_provider + service_account). Not secret.

output "github_wif_provider" {
  description = "Full resource name of the GitHub WIF provider, for workload_identity_provider in the auth step."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deploy_sa_email" {
  description = "Deploy service account the Firebase Hosting workflow impersonates."
  value       = google_service_account.github_action.email
}

output "tofu_plan_sa_email" {
  description = "Read-only service account the terraform.yml `tofu plan` job impersonates."
  value       = google_service_account.tofu_plan.email
}

output "tofu_apply_sa_email" {
  description = "Write service account the terraform.yml `tofu apply` job impersonates on merge to main."
  value       = google_service_account.tofu_apply.email
}

output "exactis_ci_runner_sa_email" {
  description = "Provisioning service account the jedimasterjonny/exactis runner workflow impersonates; it federates through the same github_wif_provider above."
  value       = google_service_account.exactis_ci_runner.email
}

output "exactis_ci_runner_vm_sa_email" {
  description = "Service account the runner workflow must attach to each VM (--service-account). The provisioning SA can act as this one and no other, so omitting it fails the create rather than falling back to the default compute SA."
  value       = google_service_account.exactis_ci_runner_vm.email
}
