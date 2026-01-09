/*
resource "libvirt_network" "external" {
name      = "external-net"
domain    = {
  name = "k3s.local"
}
bridge    = {
  name = var.k3s_bridge
}
autostart = true
ips = [{
  address = "192.168.122.1"
  prefix = 24
  dhcp = {
    ran [{
      start ="192.168.122.10"
      end = "192.168.122.254"
    }]
    hosts = [{
      ip = var.k3s_ip
      name = "k3s"
    }]
  }
}]
}
*/
