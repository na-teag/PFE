packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "malware_target" {
  # Utilisation d'une image Cloud (plus rapide et fiable que l'ISO)
  iso_url            = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  iso_checksum       = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image         = true
  disk_size          = "20G"
  format             = "qcow2"
  accelerator        = "kvm"
    display      = "none"

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

  output_directory   = "output"
  vm_name            = "packer-malware-target.qcow2"
}

    build {
    sources = ["source.qemu.malware_target"]

provisioner "shell" {
  inline = [
    "echo 'Waiting for cloud-init (non-blocking)...'",
    "sudo cloud-init status --wait || true",

    "echo 'Waiting for apt locks to be released...'",
    "while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 5; done",

    "sudo systemctl disable apt-daily.timer || true",
    "sudo systemctl disable apt-daily-upgrade.timer || true",

    "sudo apt-get update",
    "sudo apt-get install -y tcpdump python3-pip curl",

    "sudo ufw disable || true"
  ]
}

}