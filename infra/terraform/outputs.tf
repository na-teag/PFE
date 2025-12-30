output "sandbox_bridge" {
  value = var.sandbox_bridge
}

output "sandbox_network_cidr" {
  value = var.sandbox_network_cidr
}

output "sandbox_network_name" {
  value = libvirt_network.sandbox.name
}

output "inetsim_ip" {
  value = var.inetsim_ip
}

output "external_network_name" {
  value = libvirt_network.external.name
}

output "k3s-master_ip" {
  value = var.k3s_ip
}