# jonnyoc.uk DNS records, imported from Cloudflare. A dynamic-DNS A record in this
# zone is deliberately left unmanaged (updated out-of-band); Terraform must not
# fight it.

locals {
  jonnyoc_uk_zone_id = "8f66264106b3e851966618a5ce41e0d7"
}

# --- Website: Firebase Hosting ---

resource "cloudflare_dns_record" "apex_a" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "A"
  content = "199.36.158.100"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "www" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "www.jonnyoc.uk"
  type    = "CNAME"
  content = "jonnyoc-website.web.app"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "firebase_verification" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "TXT"
  content = "\"hosting-site=jonnyoc-website\""
  ttl     = 1
  proxied = false
}

# --- Email: iCloud Custom Email Domain ---

resource "cloudflare_dns_record" "icloud_mx1" {
  zone_id  = local.jonnyoc_uk_zone_id
  name     = "jonnyoc.uk"
  type     = "MX"
  content  = "mx01.mail.icloud.com"
  priority = 10
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "icloud_mx2" {
  zone_id  = local.jonnyoc_uk_zone_id
  name     = "jonnyoc.uk"
  type     = "MX"
  content  = "mx02.mail.icloud.com"
  priority = 10
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "icloud_dkim" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "sig1._domainkey.jonnyoc.uk"
  type    = "CNAME"
  content = "sig1.dkim.jonnyoc.uk.at.icloudmailadmin.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "spf" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "TXT"
  content = "\"v=spf1 include:icloud.com ~all\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "apple_domain_verification" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "TXT"
  content = "\"apple-domain=4R7LyMZ4Xef8sxTt\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "_dmarc.jonnyoc.uk"
  type    = "TXT"
  content = "\"v=DMARC1; p=reject; rua=mailto:dd6600e2f33a4eb5a1f1b96efa135234@dmarc-reports.cloudflare.net\""
  ttl     = 1
  proxied = false
}

# --- Security: CAA (restrict issuance to Firebase's rotating CAs) ---

resource "cloudflare_dns_record" "caa_pki_goog" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "CAA"
  ttl     = 1
  proxied = false
  data = {
    flags = 0
    tag   = "issue"
    value = "pki.goog"
  }
}

resource "cloudflare_dns_record" "caa_letsencrypt" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk"
  type    = "CAA"
  ttl     = 1
  proxied = false
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}
