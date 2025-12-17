output "sandbox_network_name" {
  value = libvirt_network.sandbox.name
}

output "inetsim_ip" {
  value = var.inetsim_ip
}
