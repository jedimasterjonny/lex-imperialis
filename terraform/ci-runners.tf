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
