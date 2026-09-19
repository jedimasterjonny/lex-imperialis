# The orphan reaper for the ci-runners VMs. A runner is created by a workflow
# and deleted by that same workflow, so every VM has exactly one thing keeping
# it from billing forever — and a cancelled job, a runner that never registers,
# or a workflow that dies between create and delete removes it. An n4a-standard-8
# left running is not a rounding error, and nothing else here would ever notice.
#
# So: a Cloud Scheduler job pokes a Cloud Run job every fifteen minutes, which
# deletes any instance labelled purpose=exactis-ci that was created more than an
# hour ago. Sixty minutes is comfortably longer than any real job and short
# enough that a leak costs little; the worst case for a leaked VM is therefore
# about seventy-five minutes.
#
# It keys on the label, not on a self-destruct the workflow has to remember to
# ask for. GCE's own max_run_duration + instance_termination_action = DELETE is
# the better first line and the workflow should pass it, but it is set at create
# time by the very code whose failure this exists to survive. Belt here, braces
# there.
#
# Rejected: a Cloud Function, which would drag in a source archive, Cloud Build
# and an Artifact Registry repo to run nine lines of shell. This runs a stock
# google-cloud-cli image with no build step and no source of ours to maintain.
#
# Known gap: a failing reaper is silent. Nothing alerts on a Cloud Run job's
# executions — auspex's Prometheus watches the fleet, not GCP — so a sustained
# failure shows up as a surprising bill rather than as a page.

resource "google_service_account" "exactis_ci_reaper" {
  project      = google_project.infra_shared.project_id
  account_id   = "exactis-ci-reaper"
  display_name = "exactis CI runner reaper"
  description  = "Runs the scheduled sweep that deletes orphaned exactis CI runner VMs."

  depends_on = [google_project_service.infra_shared]
}

# A custom role rather than roles/compute.instanceAdmin.v1, which the
# provisioning SA in ci-runners.tf takes: this identity must never create an
# instance, and the predefined role that lets it delete one also lets it create
# one. Seven permissions, each needed by one of the two gcloud calls below —
# list, then delete and poll the resulting zone operation.
resource "google_project_iam_custom_role" "exactis_ci_reaper" {
  project     = google_project.infra_shared.project_id
  role_id     = "exactisCiRunnerReaper"
  title       = "exactis CI runner reaper"
  description = "List and delete exactis CI runner instances. Deliberately cannot create one."

  permissions = [
    "compute.instances.delete",
    "compute.instances.get",
    "compute.instances.list",
    "compute.projects.get",
    "compute.zoneOperations.get",
    "compute.zoneOperations.list",
    "compute.zones.list",
  ]
}

resource "google_project_iam_member" "exactis_ci_reaper" {
  project = google_project.infra_shared.project_id
  role    = google_project_iam_custom_role.exactis_ci_reaper.name
  member  = google_service_account.exactis_ci_reaper.member
}

resource "google_cloud_run_v2_job" "exactis_ci_reaper" {
  project  = google_project.infra_shared.project_id
  name     = "exactis-ci-runner-reaper"
  location = "europe-west1"

  # Nothing here is precious — the job is a few lines of shell and a pinned
  # public image — so leave it destroyable rather than guarded.
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.exactis_ci_reaper.email

      # The schedule is the retry. A transient failure is picked up by the next
      # sweep fifteen minutes later, so retrying within an execution only doubles
      # the work of a run that is going to fail anyway.
      max_retries = 0
      timeout     = "300s"

      containers {
        # renovate: datasource=docker depName=gcr.io/google.com/cloudsdktool/google-cloud-cli
        image = "gcr.io/google.com/cloudsdktool/google-cloud-cli:585.0.0-alpine@sha256:dfde8bdf3d5c8ac07111d82a63e8cb708da97dd88df7cd36b08b688373d8be2d"

        command = ["/bin/sh"]

        # The age test is gcloud's own relative-duration filter (-PT60M, sixty
        # minutes ago) rather than date arithmetic in the container, which
        # busybox's date would make awkward. zone.basename() because value(zone)
        # yields the full resource URL, which `instances delete --zone` rejects.
        # set -eu: a failed delete fails the execution rather than being swallowed
        # by the loop.
        args = ["-c", <<-EOT
          set -eu
          gcloud compute instances list \
            --project=${google_project.infra_shared.project_id} \
            --filter='labels.purpose=exactis-ci AND creationTimestamp<-PT60M' \
            --format='value(name,zone.basename())' |
          while read -r name zone; do
            echo "reaping $name in $zone"
            gcloud compute instances delete "$name" \
              --project=${google_project.infra_shared.project_id} \
              --zone="$zone" --quiet
          done
        EOT
        ]
      }
    }
  }

  depends_on = [google_project_service.infra_shared]
}

# The scheduler runs as the same account the job runs as. A second identity
# would only hold roles/run.invoker on one job, which is no less authority than
# this one already has over the thing it invokes.
resource "google_cloud_run_v2_job_iam_member" "exactis_ci_reaper_invoker" {
  project  = google_project.infra_shared.project_id
  location = google_cloud_run_v2_job.exactis_ci_reaper.location
  name     = google_cloud_run_v2_job.exactis_ci_reaper.name
  role     = "roles/run.invoker"
  member   = google_service_account.exactis_ci_reaper.member
}

resource "google_cloud_scheduler_job" "exactis_ci_reaper" {
  project     = google_project.infra_shared.project_id
  name        = "exactis-ci-runner-reaper"
  region      = "europe-west1"
  description = "Sweep orphaned exactis CI runner VMs every fifteen minutes."
  schedule    = "*/15 * * * *"
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.exactis_ci_reaper.id}:run"

    # oauth_token, not oidc_token: the target is a Google API, which takes an
    # access token. OIDC is for a Cloud Run service's own endpoint.
    oauth_token {
      service_account_email = google_service_account.exactis_ci_reaper.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.infra_shared]
}

# Attaching a service account to the Cloud Run job, and to the scheduler job
# that calls it, needs iam.serviceAccounts.actAs on that account. The local
# operator applies as owner and has it implicitly; CI's tofu-apply does not.
resource "google_service_account_iam_member" "tofu_apply_reaper_actas" {
  service_account_id = google_service_account.exactis_ci_reaper.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.tofu_apply.member
}
