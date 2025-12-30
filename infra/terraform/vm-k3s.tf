resource "libvirt_volume" "k3s_master_disk" {
  name   = "k3s-master.qcow2"
  pool   = libvirt_pool.default.name
  type = "file"
  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    }
  }
}

data "template_file" "k3s_master_user_data" {
  template = file("${path.module}/vm-k3s.yaml")
}

resource "libvirt_cloudinit_disk" "k3s_master_init" {
  name      = "k3s-master-init.iso"
  user_data = data.template_file.k3s_master_user_data.rendered
  meta_data = yamlencode({
    instance-id    = "vm-k3s"
    local-hostname = "k3s-master"
  })
}

resource "libvirt_domain" "k3s_master" {
  name   = "k3s-master"
  type   = "kvm"
  memory = 2048
  vcpu   = 2

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
  }

  devices = {

    disk = {
      volume_id = libvirt_volume.k3s_master_disk.id
    }

    interfaces = [{
      network_id = libvirt_network.external.id
      addresses  = [var.k3s_ip]
    }]

  cloudinit = libvirt_cloudinit_disk.k3s_master_init.id


    console = {
      type        = "pty"
      target_type = "serial"
      target_port = "0"
    }
  }

}

