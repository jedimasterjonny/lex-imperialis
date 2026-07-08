# emmasedit.com edge configuration: Cloudflare zone settings (TLS, security,
# caching) and the WordPress cache ruleset. DNS records live in
# dns-emmasedit-com.tf; the zone_id local is defined there. Tiered Cache is
# read-only on the Free plan, so it is left unmanaged.
#
# The origin (caddy on rogue-trader) owns the response security headers and the
# static-asset Cache-Control; these settings govern only what Cloudflare's edge
# adds or overrides.

# --- TLS and HTTPS ---

resource "cloudflare_zone_setting" "emmas_ssl" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "ssl"
  value      = "strict" # Full (strict): validate the origin's public LE cert.
}

resource "cloudflare_zone_setting" "emmas_min_tls_version" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "emmas_tls_1_3" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

resource "cloudflare_zone_setting" "emmas_always_use_https" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "emmas_automatic_https_rewrites" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

# --- Security ---

resource "cloudflare_zone_setting" "emmas_security_level" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "security_level"
  value      = "medium"
}

resource "cloudflare_zone_setting" "emmas_browser_check" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "browser_check"
  value      = "on"
}

resource "cloudflare_zone_setting" "emmas_email_obfuscation" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "email_obfuscation"
  value      = "on"
}

# Edge HSTS: one year, subdomains, and preload. The origin (caddy) also sends
# HSTS, but this covers Cloudflare-generated responses (redirects, challenges)
# and adds preload. Preload is a standing commitment — the domain is on the
# browser preload list, so do not disable this without unlisting first.
resource "cloudflare_zone_setting" "emmas_hsts" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 31536000
      include_subdomains = true
      preload            = true
      nosniff            = true
    }
  }
}

# --- Performance and caching ---

# Respect the origin's Cache-Control for browser caching rather than forcing a
# fixed 4h TTL; caddy already sets a one-year immutable header on static assets.
resource "cloudflare_zone_setting" "emmas_browser_cache_ttl" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "browser_cache_ttl"
  value      = 0
}

resource "cloudflare_zone_setting" "emmas_brotli" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "brotli"
  value      = "on"
}

resource "cloudflare_zone_setting" "emmas_early_hints" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "early_hints"
  value      = "on"
}

# Rocket Loader defers/reorders JavaScript and breaks WordPress front-end JS;
# pinned off so it cannot be toggled on by accident.
resource "cloudflare_zone_setting" "emmas_rocket_loader" {
  zone_id    = local.emmasedit_com_zone_id
  setting_id = "rocket_loader"
  value      = "off"
}

# --- Cache rules ---

# HTML stays dynamic (served from the origin's Jetpack Boost page cache). Two
# rules: cache static assets honouring the origin's immutable Cache-Control, and
# never cache admin, login, or logged-in/commenter responses. The bypass rule is
# ordered last so it wins for a logged-in user's static-asset requests.
resource "cloudflare_ruleset" "emmas_cache" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com WordPress cache policy"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [
    {
      ref         = "cache_static_assets"
      description = "Edge-cache static assets, honouring the origin's Cache-Control"
      expression  = "http.request.uri.path.extension in {\"css\" \"js\" \"svg\" \"ico\" \"gif\" \"png\" \"jpg\" \"jpeg\" \"webp\" \"avif\" \"woff\" \"woff2\" \"ttf\" \"otf\" \"eot\"}"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache       = true
        edge_ttl    = { mode = "respect_origin" }
        browser_ttl = { mode = "respect_origin" }
      }
    },
    {
      ref         = "bypass_wp_dynamic"
      description = "Never cache wp-admin, login, or logged-in/commenter responses"
      expression  = "starts_with(http.request.uri.path, \"/wp-admin/\") or http.request.uri.path eq \"/wp-login.php\" or http.cookie contains \"wordpress_logged_in\" or http.cookie contains \"comment_author\" or http.cookie contains \"wp-postpass\""
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = false
      }
    },
  ]
}

# --- WAF custom rules ---

# Challenge the WordPress login POST and XML-RPC at the edge, before the origin.
# The login GET and front-end stay clean, so only credential submission and the
# XML-RPC machine endpoint are gated.
resource "cloudflare_ruleset" "emmas_waf" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com WordPress login protection"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [
    {
      ref         = "challenge_wp_login_post"
      description = "Managed-challenge credential POSTs to wp-login.php; GET renders clean"
      expression  = "http.request.method eq \"POST\" and http.request.uri.path eq \"/wp-login.php\""
      action      = "managed_challenge"
      enabled     = true
    },
    # challenge, not block: the conservative posture — automated brute-force and
    # pingback/multicall abuse can't solve it, and a hard block is avoided.
    # Jetpack/WP.com (AS2635) can't solve any challenge, so exclude it inline
    # (KISS: only one consumer needs the bypass) by ASN — its IPs churn, and an
    # ASN keeps origin topology out of this public repo.
    {
      ref         = "challenge_xmlrpc"
      description = "Challenge xmlrpc.php, excluding Jetpack/WP.com (AS2635)"
      expression  = "http.request.uri.path eq \"/xmlrpc.php\" and not (http.request.uri.query contains \"for=jetpack\" and ip.src.asnum eq 2635)"
      action      = "challenge"
      enabled     = true
    },
  ]
}

# --- Rate limiting ---

# Per-IP throttle on the login. Free allows one rate-limit rule and only the URI
# path in its expression — no method match, so it counts GET and POST alike.
# Spent on wp-login.php; xmlrpc.php is left to the WAF challenge. cf.colo.id is a
# mandatory counting characteristic (per-colo edge count) the API requires.
resource "cloudflare_ruleset" "emmas_ratelimit" {
  zone_id = local.emmasedit_com_zone_id
  name    = "emmasedit.com WordPress login rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [
    {
      ref         = "ratelimit_wp_login"
      description = "Throttle wp-login.php per IP"
      expression  = "http.request.uri.path eq \"/wp-login.php\""
      action      = "block"
      enabled     = true
      ratelimit = {
        characteristics     = ["cf.colo.id", "ip.src"]
        period              = 10
        requests_per_period = 5
        mitigation_timeout  = 10
      }
    },
  ]
}
