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
