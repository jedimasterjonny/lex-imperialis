provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Wired for the cross-provider VM->DNS work to come; stays unconfigured (its
# token unneeded) until a resource uses it.
provider "hcloud" {
  token = var.hcloud_token
}

# Google / Firebase. Local-execution mode means these use your own gcloud
# Application Default Credentials (`gcloud auth application-default login` as
# me@jonnyoc.uk) — no key or CI service account. Firebase management APIs bill
# quota to the target project, so user_project_override routes it there (ADC has
# no default quota project). google-beta serves the google_firebase_* resources.
provider "google" {
  project               = "jonnyoc-website"
  user_project_override = true
  billing_project       = "jonnyoc-website"
}

provider "google-beta" {
  project               = "jonnyoc-website"
  user_project_override = true
  billing_project       = "jonnyoc-website"
}
