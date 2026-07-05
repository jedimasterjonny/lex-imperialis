# jonnyoc.co.uk DNS records, imported from Cloudflare. The zone serves the same
# Firebase Hosting site as jonnyoc.uk (apex A, www, hosting TXT) and forwards email
# to the primary via Cloudflare Email Routing.
#
# Email Routing's MX and DKIM records are meta.read_only in Cloudflare's API — it
# owns and rotates them and rejects writes — so they are deliberately left
# unmanaged (as jonnyoc.uk's dynamic-DNS A record is); Terraform must not fight
# them. Only the writable SPF record is managed here.

locals {
  jonnyoc_co_uk_zone_id = "4827f6bf281be34b6875330347412734"
}

# --- Website: Firebase Hosting (same site as jonnyoc.uk) ---

resource "cloudflare_dns_record" "couk_apex_a" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "jonnyoc.co.uk"
  type    = "A"
  content = "199.36.158.100"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "couk_www" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "www.jonnyoc.co.uk"
  type    = "CNAME"
  content = "jonnyoc-website.web.app"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "couk_firebase_verification" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "jonnyoc.co.uk"
  type    = "TXT"
  content = "\"hosting-site=jonnyoc-website\""
  ttl     = 1
  proxied = false
}

# --- Email: Cloudflare Email Routing (SPF only; MX + DKIM are read_only) ---

resource "cloudflare_dns_record" "couk_spf" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "jonnyoc.co.uk"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.mx.cloudflare.net ~all\""
  ttl     = 1
  proxied = false
}
