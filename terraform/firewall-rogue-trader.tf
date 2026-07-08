# rogue-trader's Hetzner cloud firewall. Default-deny inbound; only 80/443 are
# open for the public WordPress site. SSH rides the WireGuard tunnel
# (outbound-initiated conntrack return traffic), so there is no inbound 22 or
# 51820. No out rules, so outbound is unrestricted. apply_to attaches it to the
# VM via the hcloud_server data source in dns-emmasedit-com.tf.

resource "hcloud_firewall" "vpc" {
  name = "vpc-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  apply_to {
    server = data.hcloud_server.rogue_trader.id
  }
}
