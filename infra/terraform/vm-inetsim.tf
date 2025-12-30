resource "libvirt_volume" "inetsim_disk" {
  name   = "inetsim.qcow2"
  pool   = libvirt_pool.default.name
  type = "file"
  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    }
  }
}

data "template_file" "inetsim_cloudinit" {
  template = file("${path.module}/vm-inetsim.yaml")
}

resource "libvirt_cloudinit_disk" "inetsim_init" {
  name      = "inetsim-init.iso"
  user_data = data.template_file.inetsim_cloudinit.rendered
  meta_data = yamlencode({
    instance-id    = "vm-inetsim"
    local-hostname = "inetsim"
  })
}

resource "libvirt_domain" "inetsim" {
  name   = "inetsim"
  type   = "kvm"
  memory = 2048
  vcpu   = 2

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type = "hvm"
    type_arch = "x86_64"
  }

  devices = {

    disk = {
      volume_id = libvirt_volume.inetsim_disk.id
    }

    interfaces = [{
      network_id = libvirt_network.sandbox.id
      addresses  = [var.inetsim_ip]   # IP statique OK
    }]

    cloudinit = libvirt_cloudinit_disk.inetsim_init.id


    console = {
      type        = "pty"
      target_type = "serial"
      target_port = "0"
    }
  }
}
