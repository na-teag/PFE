resource "libvirt_network" "sandbox" {
  name      = "sandbox-net"
  mode      = "nat"
  domain    = "sandbox.local"
  addresses = [var.sandbox_network_cidr]
  bridge = var.sandbox_bridge
  autostart = true

  dhcp {
    enabled = true
    ranges = ["192.168.100.11,192.168.100.200"]
    host {
      ip   = var.inetsim_ip
      #mac = "52:54:00:aa:bb:cc"  # Optionnel, si INetSim fixe
      name = "inetsim"
    }

    # Forcer l’IP d’INetSim comme DNS pour toutes les VMs sandbox
    options = {
      "dns-server" = var.inetsim_ip
    }
  }

  dns {
    enabled = false
  }
}
