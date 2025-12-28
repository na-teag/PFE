resource "libvirt_volume" "k3s_master_disk" {
  name   = "k3s-master.qcow2"
  pool   = "default"
  type = "qcow2"
  capacity   = 10
  capacity_unit = "GB"
}

data "template_file" "k3s_master_user_data" {
  template = file("${path.module}/vm-k3s.yaml")
}

resource "libvirt_cloudinit_disk" "k3s_master_init" {
  name      = "k3s-master-init.iso"
  user_data = data.template_file.k3s_master_user_data.rendered
  meta_data = yamlencode({
    instance-id    = "vm-k3s"
    local-hostname = "k3s"
  })
}

resource "libvirt_domain" "k3s_master" {
  name   = "k3s-master"
  type   = "kvm"
  memory = 2048
  vcpu   = 2

  devices = {

    interfaces = [{
      network_id = libvirt_network.external.id
      addresses  = [var.k3s_ip]
    }]

    disk = {
      volume_id = libvirt_volume.k3s_master_disk.id
    }

  cloudinit = libvirt_cloudinit_disk.k3s_master_init.id
  }

}

