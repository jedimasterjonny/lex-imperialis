# jonnyoc.co.uk DNS records, imported from Cloudflare. The zone no longer serves
# the website: apex and www are 301-redirected to the canonical jonnyoc.uk by an
# edge redirect rule (edge-jonnyoc-co-uk.tf), fronted by a proxied placeholder
# origin. Email still forwards to the primary via Cloudflare Email Routing.
#
# Email Routing's MX and DKIM records are meta.read_only in Cloudflare's API — it
# owns and rotates them and rejects writes — so they are deliberately left
# unmanaged (as jonnyoc.uk's dynamic-DNS A record is); Terraform must not fight
# them. Only the writable SPF record is managed here.

locals {
  jonnyoc_co_uk_zone_id = "4827f6bf281be34b6875330347412734"
}

# --- Web: 301-redirect to canonical jonnyoc.uk ---
#
# Apex and www resolve to a proxied RFC 5737 placeholder; the dynamic redirect
# rule in edge-jonnyoc-co-uk.tf answers at the edge, so the placeholder origin is
# never contacted. Proxying is what lets the edge rule run.

resource "cloudflare_dns_record" "couk_apex_a" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "jonnyoc.co.uk"
  type    = "A"
  content = "192.0.2.1"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "couk_www" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "www.jonnyoc.co.uk"
  type    = "A"
  content = "192.0.2.1"
  ttl     = 1
  proxied = true
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
