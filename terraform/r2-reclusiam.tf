# reclusiam — a Cloudflare R2 bucket, the backups' last-resort third copy
# behind the NAS repos and the Hetzner storage box. Nothing writes to it yet:
# this provisions the target, not the job that fills it.
#
# The storage box is in Finland, so the bucket is hinted to Western Europe —
# far enough that a regional loss cannot take both off-site copies, close enough
# to stay in Europe. `location` is best effort and is honoured only the first
# time a bucket of this name is created, so a delete-and-recreate inherits the
# original placement. Jurisdiction is deliberately unset: it pins residency, not
# distance, and the dashboard offers it as an alternative to the hint rather
# than alongside it. Residency is moot here anyway — every restic repo is
# encrypted with a per-host key from the vault, so the provider holds ciphertext.
#
# No versioning: R2 implements none at all (PutBucketVersioning is unimplemented
# in its S3 API), which is what we want — snapshot history and retention are
# restic's, as in every other repo. For the same reason there is no bucket lock:
# object retention would refuse restic's own prune.
#
# The S3 credential restic will need is NOT minted here — a cloudflare_api_token
# resource would write the secret into Terraform state. Mint it by hand and put
# it in the vault when the backup job lands.
#
# This is the config's first account-scoped Cloudflare resource: both provider
# tokens need Account | Workers R2 Storage (Edit to apply, Read to plan) on top
# of their zone permissions, or the apply fails at create and every later plan
# fails at refresh.

locals {
  # Non-secret account identifier, same standing as the zone ids in dns-*.tf.
  cloudflare_account_id = "7663931fe9b786a37028a39541dbfa34"
}

resource "cloudflare_r2_bucket" "reclusiam" {
  account_id = local.cloudflare_account_id
  name       = "reclusiam"
  location   = "weur"

  # Standard, not InfrequentAccess: the minimum storage duration and per-read
  # retrieval fee are the wrong trade for a repo restic prunes and re-reads to
  # verify. Egress is free either way, which is what makes R2 a restore target.
  storage_class = "Standard"

  # Deleting the bucket deletes every object in it, and name, location and
  # jurisdiction all force replacement. The CI gate blocks a destructive plan
  # from applying unattended; this blocks it at plan.
  lifecycle {
    prevent_destroy = true
  }
}
