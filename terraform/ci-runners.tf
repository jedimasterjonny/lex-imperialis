# ci-runners — the permanent GCP substrate the ephemeral GitHub Actions runners
# for jedimasterjonny/exactis boot into. The VMs are not here and never will be:
# a workflow creates one per job and deletes it when the job ends, so what
# terraform owns is only what has to outlive a run.
#
# The shape is fixed by measurement, not preference. Runners are n4a-standard-8
# (Google Axion, ARM64), which europe-west1 offers in zones b and c only and
# europe-north1 does not offer at all — hence a region away from the state
# bucket, and only two of that region's four zones — europe-west1-d offers no
# N4A machine type whatsoever. N4A also requires a hyperdisk-balanced boot disk;
# pd-balanced is refused at create.
#
# The binding quota is CPUS_ALL_REGIONS at 32, not the N4A per-family
# quota of 200, so concurrency caps at four runners and a fifth job queues.
# Raising that ceiling is a quota-increase request against the project, not a
# change to this file.
#
# No Cloud NAT. It bills per gateway-hour and per GB where an ephemeral external
# IP on the VM bills neither, and the runners need egress to github.com,
# nodejs.org, bun.sh and the npm registry. Egress rides the VM's own address;
# inbound stays shut because the IAP rule below is the only ingress rule in the
# network and a VPC denies what no rule allows.

resource "google_compute_network" "ci_runners" {
  project                 = google_project.infra_shared.project_id
  name                    = "ci-runners"
  description             = "Ephemeral GitHub Actions runners for jedimasterjonny/exactis."
  auto_create_subnetworks = false

  # compute.googleapis.com must be on before a network can be created (from-zero).
  depends_on = [google_project_service.infra_shared]
}

resource "google_compute_subnetwork" "ci_runners" {
  project = google_project.infra_shared.project_id
  name    = "ci-runners-europe-west1"
  network = google_compute_network.ci_runners.id
  region  = "europe-west1"

  # A custom-mode subnet cannot exist without a range, and this one maps
  # nothing: the VPC is isolated — no peering, no VPN, no route to the fleet —
  # so the literal describes no reachable surface. A /24 is far more than the
  # four-runner ceiling needs.
  ip_cidr_range = "10.10.0.0/24"

  # Private Google Access is deliberately off. The runners reach Google APIs
  # over the same external address they reach github.com over, so enabling it
  # would buy nothing and imply a private-egress design this is not.
  private_ip_google_access = false
}

resource "google_compute_firewall" "ci_runners_iap_ssh" {
  project     = google_project.infra_shared.project_id
  name        = "ci-runners-iap-ssh"
  network     = google_compute_network.ci_runners.id
  description = "Admin SSH over IAP TCP forwarding only."
  direction   = "INGRESS"

  # IAP's TCP-forwarding range, the whole of it. Admin access to a runner is a
  # tunnel — `gcloud compute ssh --tunnel-through-iap` — authorised by IAM
  # rather than by source address, so there is no public 22 to find and no
  # operator address committed here. This is the only ingress rule the network
  # will ever carry: a public inbound rule is not a tightening decision to be
  # revisited, it is out of bounds.
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # No target_tags or target_service_accounts: the network holds runners and
  # nothing else, so the rule's target set and the intended one are already the
  # same. Give the rule a target the day something else joins this VPC.
}

# --- Identities ----------------------------------------------------------
#
# Two service accounts with nothing in common. exactis-ci-runner is the
# provisioning identity the workflow federates in as, and may create and delete
# instances. exactis-ci-runner-vm is attached to the VM, and is close to
# powerless on purpose: a runner executes whatever a workflow in that repo says,
# so whatever the VM's metadata token can reach, that code can reach.
#
# The split is also what keeps the project's default compute service account —
# which Google grants roles/editor and attaches to any VM created without an
# explicit one — off these runners. Attaching a service account needs
# iam.serviceAccounts.actAs on it, and the provisioning identity has that on
# exactly one account, so a create that omits --service-account is refused
# rather than quietly handed an editor token. That is the enforcement; the
# workflow naming the right account is only the happy path.

resource "google_service_account" "exactis_ci_runner" {
  project      = google_project.infra_shared.project_id
  account_id   = "exactis-ci-runner"
  display_name = "exactis CI runner provisioning"
  description  = "Creates and deletes the ephemeral runner VMs, impersonated via WIF from ${local.github_repo_exactis}."

  # iam.googleapis.com must be on before the SA can be created (from-zero).
  depends_on = [google_project_service.infra_shared]
}

resource "google_service_account_iam_member" "exactis_ci_runner_wif" {
  service_account_id = google_service_account.exactis_ci_runner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_exactis_principal
}

# instanceAdmin.v1 is the narrowest predefined role that covers an instance
# create: not just instances.create/delete but the disks.create,
# images.useReadOnly, subnetworks.use, subnetworks.useExternalIp and
# zoneOperations.get that one create actually touches. A custom role would trim
# little the workflow does not use, and the project holds no compute outside
# this VPC for the surplus to reach. roles/editor, for the avoidance of doubt,
# is not on the table.
resource "google_project_iam_member" "exactis_ci_runner" {
  project = google_project.infra_shared.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = google_service_account.exactis_ci_runner.member
}

resource "google_service_account" "exactis_ci_runner_vm" {
  project      = google_project.infra_shared.project_id
  account_id   = "exactis-ci-runner-vm"
  display_name = "exactis CI runner VM"
  description  = "Attached to the ephemeral runner VMs. Writes logs; nothing else."

  depends_on = [google_project_service.infra_shared]
}

# Not monitoring.metricWriter: nothing here reads GCP metrics for a machine
# that lives a few minutes.
resource "google_project_iam_member" "exactis_ci_runner_vm" {
  project = google_project.infra_shared.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.exactis_ci_runner_vm.member
}

# The VM's second and last power: deleting itself once its work is done. It
# does that over the Compute REST API with the token from its own metadata
# server — Ubuntu's cloud image ships no gcloud — as a bare DELETE that does
# not poll the operation it starts. So compute.instances.delete is the whole
# requirement: not compute.zoneOperations.get, which only a polling client
# needs, and not compute.disks.delete, which is for force-deleting a disk that
# is not auto-delete. The boot disk is created with the instance and goes with
# it.
#
# Without this the runner cannot tidy up after itself. The reaper would still
# catch it, but only on a fifteen-minute sweep past a sixty-minute threshold,
# so a finished VM would sit for up to an hour billing a 100GB hyperdisk
# instead of disappearing in seconds.
resource "google_project_iam_custom_role" "exactis_ci_runner_self_delete" {
  project     = google_project.infra_shared.project_id
  role_id     = "exactisCiRunnerSelfDelete"
  title       = "exactis CI runner self-delete"
  description = "Delete a CI runner instance. One permission, and pointedly not instances.create."

  permissions = ["compute.instances.delete"]
}

# Conditioned on the instance name, not granted project-wide: the workflow
# names its VMs exactis-ci-<run>-<attempt>-<n>, so the prefix is stable and the
# binding holds this account to its own kind in a project that also carries the
# state bucket and the WIF pool.
#
# Two things the condition cannot do. It cannot say "this instance and no
# other" — IAM has no attribute for the caller's own identity as a resource —
# so one runner could in principle delete another, which is a set of machines
# the reaper deletes wholesale anyway. And it cannot use contains(): IAM
# conditions expose only startsWith, endsWith and extract, so the name is
# pulled out of the resource path with extract() rather than matched inside it.
# Both forms were checked against the IAM lintPolicy API before landing here.
resource "google_project_iam_member" "exactis_ci_runner_vm_self_delete" {
  project = google_project.infra_shared.project_id
  role    = google_project_iam_custom_role.exactis_ci_runner_self_delete.name
  member  = google_service_account.exactis_ci_runner_vm.member

  condition {
    title       = "exactis CI runner instances only"
    description = "Instances named exactis-ci-*, which is what the runner workflow creates."
    expression  = "resource.type == 'compute.googleapis.com/Instance' && resource.name.extract('/instances/{name}').startsWith('exactis-ci-')"
  }
}

# actAs, and only on this one account — see the section header.
resource "google_service_account_iam_member" "exactis_ci_runner_actas" {
  service_account_id = google_service_account.exactis_ci_runner_vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.exactis_ci_runner.member
}
