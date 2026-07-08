# emmasedit.com DNS records, imported from Cloudflare. WordPress on rogue-trader
# sits behind Cloudflare's proxy; mail is received via Google Workspace, and SPF +
# DKIM also authorise Brevo for transactional sending.
#
# The apex A and AAAA carry rogue-trader's origin IP — the address Cloudflare's
# proxy hides. Committing it to this public repo would defeat that, so the content
# is read from the Hetzner API at plan time via the hcloud_server data source
# below, never hardcoded.

locals {
  emmasedit_com_zone_id = "b6791c95e583b4af99fd5eb01f183bc4"
}

# rogue-trader's live attributes from the Hetzner API: the origin IP for the
# apex records below (never committed — Cloudflare's proxy hides it) and the
# server id for the firewall's apply_to (firewall-rogue-trader.tf).
data "hcloud_server" "rogue_trader" {
  name = "rogue-trader"
}

# --- Website: WordPress on rogue-trader, behind Cloudflare (proxied) ---

resource "cloudflare_dns_record" "emmas_apex_a" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "A"
  content = data.hcloud_server.rogue_trader.ipv4_address
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "emmas_apex_aaaa" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "AAAA"
  content = data.hcloud_server.rogue_trader.ipv6_address
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "emmas_www" {
  zone_id = local.emmasedit_com_zone_id
  name    = "www.emmasedit.com"
  type    = "CNAME"
  content = "emmasedit.com"
  ttl     = 1
  proxied = true
}

# --- Email: received via Google Workspace ---

resource "cloudflare_dns_record" "emmas_mx_primary" {
  zone_id  = local.emmasedit_com_zone_id
  name     = "emmasedit.com"
  type     = "MX"
  content  = "aspmx.l.google.com"
  priority = 1
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "emmas_mx_alt1" {
  zone_id  = local.emmasedit_com_zone_id
  name     = "emmasedit.com"
  type     = "MX"
  content  = "alt1.aspmx.l.google.com"
  priority = 5
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "emmas_mx_alt2" {
  zone_id  = local.emmasedit_com_zone_id
  name     = "emmasedit.com"
  type     = "MX"
  content  = "alt2.aspmx.l.google.com"
  priority = 5
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "emmas_mx_alt3" {
  zone_id  = local.emmasedit_com_zone_id
  name     = "emmasedit.com"
  type     = "MX"
  content  = "alt3.aspmx.l.google.com"
  priority = 10
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "emmas_mx_alt4" {
  zone_id  = local.emmasedit_com_zone_id
  name     = "emmasedit.com"
  type     = "MX"
  content  = "alt4.aspmx.l.google.com"
  priority = 10
  ttl      = 1
  proxied  = false
}

# --- Email authentication: SPF, DKIM (Google + Brevo), DMARC ---

# mx mechanism dropped as redundant: the MX hosts are Google's, already covered by
# include:_spf.google.com.
resource "cloudflare_dns_record" "emmas_spf" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.google.com include:spf.brevo.com ~all\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "emmas_google_dkim" {
  zone_id = local.emmasedit_com_zone_id
  name    = "google._domainkey.emmasedit.com"
  type    = "TXT"
  content = "\"v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAx9aKeQeF4v/kD1h1w+auk8OuekR6+IO5cxzCMqVAS8ribRFoMAz2aqoIWXbug+jFtwY9yH12Cy/6X4f2EItRm/+Oq3fKBF9rNs1PNmC2wwComuPtku6h7+4rVZuZj7/CAi6T98mTNuIC+DzqB/y7zi8qwcAYOZB/h3Yd1LmrbYrmCGFGihS6v8oyCjJWNO6F6\" \"JxrF4CgHky09JTIiLKOcWHNski9GS+wvNK1OQpotSBtXCg7eb7TC3INyEF1YmKtZ5K5jUEru8V/ELbwVXuktWdmx/y3I+LvgAkpgV0tnjn+4yQ/W1qFq/SrkEQgYk4Zer630l4QDei2QYtTAntkPwIDAQAB\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "emmas_brevo_dkim1" {
  zone_id = local.emmasedit_com_zone_id
  name    = "brevo1._domainkey.emmasedit.com"
  type    = "CNAME"
  content = "b1.emmasedit-com.dkim.brevo.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "emmas_brevo_dkim2" {
  zone_id = local.emmasedit_com_zone_id
  name    = "brevo2._domainkey.emmasedit.com"
  type    = "CNAME"
  content = "b2.emmasedit-com.dkim.brevo.com"
  ttl     = 1
  proxied = false
}

# p=reject: 30 days of Cloudflare aggregate reports showed every real sender
# (Google Workspace + Brevo) DKIM-aligned and the only failure was a spoof, so
# rejecting is safe. Alignment stays relaxed (Brevo only relaxed-aligns). The
# Cloudflare rua is kept for ongoing monitoring; sp=reject covers subdomains.
resource "cloudflare_dns_record" "emmas_dmarc" {
  zone_id = local.emmasedit_com_zone_id
  name    = "_dmarc.emmasedit.com"
  type    = "TXT"
  content = "\"v=DMARC1; p=reject; sp=reject; rua=mailto:0fdca29454ac4c7dbe57a0284f476d35@dmarc-reports.cloudflare.net\""
  ttl     = 1
  proxied = false
}

# --- Domain verification (all three required — do not prune) ---
# Brevo, plus two google-site-verification tokens: one for Google Workspace and
# one for Google Search Console.

resource "cloudflare_dns_record" "emmas_brevo_verification" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "TXT"
  content = "\"brevo-code:9c550236885bbb8669ed8f556e999649\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "emmas_google_verification_1" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "TXT"
  content = "\"google-site-verification=waenfQEYIM-EblgSGDA1jRXOTtsuEmEbLyc9C1v2c_c\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "emmas_google_verification_2" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "TXT"
  content = "\"google-site-verification=7vtD2byB9CuCKsM6Ii81bKo0JUZ8DBCb87nFFPgpQeg\""
  ttl     = 1
  proxied = false
}

# --- Security: CAA ---
#
# Restrict issuance to letsencrypt.org (the origin's caddy cert) and pki.goog
# (Cloudflare Universal SSL / Google Trust Services), plus an iodef incident
# contact. Cloudflare auto-injects its full CA pool once any CAA record exists,
# so these are for explicit, deterministic parity with the sibling zones.

resource "cloudflare_dns_record" "emmas_caa" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "CAA"
  ttl     = 1
  proxied = false
  data = {
    flags = 0
    tag   = "iodef"
    value = "mailto:emma@emmasedit.com"
  }
}

resource "cloudflare_dns_record" "emmas_caa_pki_goog" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "CAA"
  ttl     = 1
  proxied = false
  data = {
    flags = 0
    tag   = "issue"
    value = "pki.goog"
  }
}

resource "cloudflare_dns_record" "emmas_caa_letsencrypt" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com"
  type    = "CAA"
  ttl     = 1
  proxied = false
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}

# --- Security: DNSSEC ---
#
# Signing was enabled out-of-band and is already active/validating; this resource
# brings it under Terraform (imported), matching the sibling zones. No live change.

resource "cloudflare_zone_dnssec" "emmasedit_com" {
  zone_id = local.emmasedit_com_zone_id
  status  = "active"
}
