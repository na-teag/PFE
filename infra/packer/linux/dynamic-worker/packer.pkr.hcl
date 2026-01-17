packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "ebpf_sandbox" {
  iso_url = "https://cloud-images.ubuntu.com/jammy/20220308/jammy-server-cloudimg-amd64.img"
  iso_checksum       = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image         = true
  disk_size          = "9G"
  format             = "qcow2"
  accelerator        = "kvm"
  display            = "none"
  net_device         = "virtio-net"
  net_bridge         = ""

  # Configuration SSH
  ssh_username       = "analyst"
  ssh_password       = "infected"
  ssh_timeout        = "15m"
  ssh_handshake_attempts = 100

  # On expose le fichier user-data via un serveur HTTP local intégré à Packer
  http_directory     = "."

  # Argument pour dire à la VM où chercher sa configuration au boot
  qemuargs = [
    ["-display", "none"],
    ["-smbios", "type=1,serial=ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/"],
    ["-cpu", "host"]
  ]

  output_directory   = "ebpf_sandbox"
  vm_name            = "packer-ebpf_sandbox.qcow2"
}

build {
  sources = ["source.qemu.ebpf_sandbox"]

  provisioner "shell" {
  inline = [
    "echo 'Waiting for cloud-init...'",
    "sudo cloud-init status --wait || true",
    "echo 'Waiting for apt locks...'",
    "while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 5; done",

    "sudo systemctl disable apt-daily.timer || true",
    "sudo systemctl disable apt-daily-upgrade.timer || true",

    "sudo apt-get update",
    "sudo tee /etc/netplan/01-netcfg.yaml > /dev/null << 'EOF'\nnetwork:\n  version: 2\n  renderer: networkd\n  ethernets:\n    enp1s0:\n      dhcp4: true\nEOF",
    "sudo chmod 600 /etc/netplan/01-netcfg.yaml",
    "sudo netplan generate",
    "sudo netplan apply || true",

    "sudo systemctl enable systemd-networkd",
    "sudo systemctl restart systemd-networkd",
    "sudo mkdir -p /etc/cloud/cloud.cfg.d",
    "sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg > /dev/null << 'EOF' \nnetwork: {config: disabled} \nEOF",

    "echo 'analyst ALL=(root) NOPASSWD: /usr/bin/bpftrace, /bin/mkdir, /bin/chown' | sudo tee /etc/sudoers.d/ebpf",
    "sudo chmod 440 /etc/sudoers.d/ebpf",

    "sudo mkdir -p /home/analyst/.ssh",
    "sudo chmod 700 /home/analyst/.ssh",
    "echo '${file("~/.ssh/sandbox_key.pub")}' > /home/analyst/.ssh/authorized_keys",
    "sudo chmod 600 /home/analyst/.ssh/authorized_keys",
    "sudo chown -R analyst:analyst /home/analyst/.ssh",

    "sudo apt-get install -y bpftrace",
    "sudo apt-get install -y linux-tools-$(uname -r)",
    "sudo apt-get install -y linux-tools-common",
    "sudo apt-get install -y linux-headers-$(uname -r)",
    "sudo apt-get install -y clang llvm libelf-dev zlib1g-dev",
    "sudo apt-get install -y python3-pip tcpdump curl",

    "sudo ufw disable || true"
  ]
}
}