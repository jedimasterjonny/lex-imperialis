# jonnyoc.co.uk edge configuration: the dynamic redirect that canonicalises the
# zone onto jonnyoc.uk. DNS records live in dns-jonnyoc-co-uk.tf; the zone_id
# local is defined there.

# --- Canonical redirect ---

# 301 every apex and www request to the same path on jonnyoc.uk, preserving the
# query string. Fires at the edge on the proxied placeholder records, so no
# origin is ever contacted.
resource "cloudflare_ruleset" "couk_redirect" {
  zone_id = local.jonnyoc_co_uk_zone_id
  name    = "jonnyoc.co.uk canonical redirect to jonnyoc.uk"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "redirect_couk_to_jonnyoc_uk"
      description = "301 apex + www to jonnyoc.uk, preserving path and query"
      expression  = "(http.host eq \"jonnyoc.co.uk\") or (http.host eq \"www.jonnyoc.co.uk\")"
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
