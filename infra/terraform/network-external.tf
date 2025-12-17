resource "libvirt_network" "external" {
  name      = "external-net"
  mode      = "bridge"
  bridge    = var.k3s_bridge
  autostart = true
  addresses = [var.k3s_network_cidr]
  domain    = "k3s.local"

  dhcp {
    enabled = true
    ranges = ["192.168.122.10,192.168.122.200"]
  }

  dns {
    enabled = false
  }
}
