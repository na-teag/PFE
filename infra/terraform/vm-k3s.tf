
resource "libvirt_volume" "k3s_disk" {
  name   = "k3s.qcow2"
  pool   = "default" #libvirt_pool.default.name
  type = "file"
  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    }
  }
}

resource "libvirt_volume" "k3s_cloudinit" {
  name   = "k3s-cloudinit.iso"
  pool   = "default"
  format = "iso"

  create = {
    content = {
      url = libvirt_cloudinit_disk.k3s_init.path
    }
  }
}


resource "libvirt_cloudinit_disk" "k3s_init" {
  name      = "k3s-init.iso"
  user_data = file("${path.module}/vm-k3s.yaml")
  network_config = file("${path.module}/network-config.yaml")
  meta_data = yamlencode({
    instance-id    = "k3s"
    local-hostname = "k3s"
  })
}

resource "libvirt_domain" "k3s_master" {
  name   = "k3s"
  type   = "kvm"
  memory = 3072
  unit   = "MiB"
  vcpu   = 3

  features = {
    acpi = true
  }

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type             = "hvm"
    type_arch        = "x86_64"
    type_machine     = "q35"
    firmware         = "efi"
    loader           = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    /*
    loader_readonly  = true
    loader_type      = "pflash"
     */
    nv_ram = {
      nv_ram   = "/var/lib/libvirt/qemu/nvram/k3s.fd"
      template = "/usr/share/OVMF/OVMF_VARS_4M.fd"
    }
    boot_devices     = ["hd"]
  }

  devices = {
    disks = [
      {
        source = {
          file = libvirt_volume.k3s_disk.id
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        source = {
          file = libvirt_volume.k3s_cloudinit.path
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]

    interfaces = [
      {
        type = "network"
        model = "virtio"
        source = {
          network = "default"
        }
      }
    ]


    consoles = [{
      type        = "pty"
      target_type = "serial"
      target_port = "0"
    }]

  }

}

