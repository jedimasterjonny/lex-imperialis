# jonnyoc.uk edge configuration: the dynamic redirect that sends www to the
# canonical apex. DNS records live in dns-jonnyoc-uk.tf; the zone_id local is
# defined there. The apex itself stays on Firebase Hosting.

# --- Canonical redirect ---

# 301 www.jonnyoc.uk to the apex, preserving path and query. Fires at the edge on
# the proxied placeholder record, so no origin is ever contacted.
resource "cloudflare_ruleset" "www_redirect" {
  zone_id = local.jonnyoc_uk_zone_id
  name    = "jonnyoc.uk www canonical redirect to apex"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "redirect_www_to_apex"
      description = "301 www to the jonnyoc.uk apex, preserving path and query"
      expression  = "(http.host eq \"www.jonnyoc.uk\")"
      action      = "redirect"
      enabled     = true
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://jonnyoc.uk\", http.request.uri.path)"
          }
        }
      }
    },
  ]
}

# --- TLS ---
#
# These apply only to the proxied www redirect endpoint; the apex is served
# Firebase-direct (DNS-only) and is unaffected. ssl=strict is a safe default
# even though the placeholder origin is never contacted; min_tls_version=1.2
# stops a TLS 1.0/1.1 client reaching the redirect, matching emmasedit.com.

resource "cloudflare_zone_setting" "jonnyoc_uk_ssl" {
  zone_id    = local.jonnyoc_uk_zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "jonnyoc_uk_min_tls_version" {
  zone_id    = local.jonnyoc_uk_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# --- Security headers ---
#
# HSTS on the www redirect responses, which otherwise carry none. Only the
# proxied www hostname is touched — the apex is Firebase-direct and sends its own
# header via firebase.json. include_subdomains stays off: the zone carries an
# unmanaged dynamic-DNS subdomain, and binding the whole tree to HTTPS-only for a
# year is not this redirect header's call. preload stays off too — the apex it
# would bind is not served from this edge.
resource "cloudflare_zone_setting" "jonnyoc_uk_hsts" {
  zone_id    = local.jonnyoc_uk_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 31536000
      include_subdomains = false
      preload            = false
      nosniff            = true
    }
  }
}
