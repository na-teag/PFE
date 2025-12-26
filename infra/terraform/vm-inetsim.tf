resource "libvirt_volume" "inetsim_disk" {
  name   = "inetsim.qcow2"
  pool   = var.storage_pool
  source = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  format = "qcow2"
}

data "template_file" "inetsim_cloudinit" {
  template = file("${path.module}/cloudinit/inetsim.yaml")
}

resource "libvirt_cloudinit_disk" "inetsim_init" {
  name      = "inetsim-init.iso"
  user_data = data.template_file.inetsim_cloudinit.rendered
}

resource "libvirt_domain" "inetsim" {
  name   = "inetsim"
  memory = 2048
  vcpu   = 2

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.sandbox.id
    addresses  = [var.inetsim_ip]
  }

  disk {
    volume_id = libvirt_volume.inetsim_disk.id
  }

  cloudinit = libvirt_cloudinit_disk.inetsim_init.id

  graphics {
    type        = "vnc"
    listen_type = "none"
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}
