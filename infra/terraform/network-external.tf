resource "libvirt_network" "external" {
  name      = "external-net"
  bridge    = {
    name = var.k3s_bridge
  }
  autostart = true
  domain    = {
    name = "k3s.local"
  }
}
