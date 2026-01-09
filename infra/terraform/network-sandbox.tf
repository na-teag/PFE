/*
resource "libvirt_network" "sandbox" {
  name      = "sandbox-net"
  domain    = {
    name = "sandbox.local"
  }
  bridge = {
    name = var.sandbox_bridge
  }
  autostart = true

  ips = [{
    address = "192.168.100.1"
    prefix = 24
    dhcp = {
      ranges = [{
        start ="192.168.100.10"
        end = "192.168.100.200"
      }]
      hosts = [{
        ip = var.inetsim_ip
        name = "inetsim"
      }]
    }
  }]

  dns = {
    enabled = true
    host = [{
      ip = var.inetsim_ip
      hostnames = [{
        hostname = "inetsim"
      }]
    }]
  }

}
*/