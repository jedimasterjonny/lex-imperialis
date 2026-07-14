# rogue-trader's Hetzner cloud firewall. Default-deny inbound; 80/443 are open
# only to Cloudflare's edge, so the WAF and rate limit in edge-emmasedit-com.tf
# cannot be bypassed by hitting the origin's IP directly. SSH rides the WireGuard
# tunnel (outbound-initiated conntrack return traffic), so there is no inbound 22
# or 51820. No out rules, so outbound is unrestricted. apply_to attaches it to the
# VM via the hcloud_server data source in dns-emmasedit-com.tf.

# Cloudflare's published edge ranges. caddy issues its cert over DNS-01, so
# closing 80 to the public internet does not break ACME.
data "cloudflare_ip_ranges" "cloudflare" {}

resource "hcloud_firewall" "vpc" {
  name = "vpc-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = concat(
      data.cloudflare_ip_ranges.cloudflare.ipv4_cidrs,
      data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs,
    )
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = concat(
      data.cloudflare_ip_ranges.cloudflare.ipv4_cidrs,
      data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs,
    )
  }

  apply_to {
    server = data.hcloud_server.rogue_trader.id
  }
}
