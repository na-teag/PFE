#!/bin/bash
set -euo pipefail

# Variables
VM_NAME="inetsim"
VOL_NAME="${1:-inetsim.qcow2}"
POOL="default"
IMAGE_NAME="noble-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
STATIC_IP="192.168.122.10"

# --- Vérifications ---
if ! virsh net-info default &>/dev/null; then
    echo "Erreur: Le réseau 'default' n'est pas configuré ou démarré."
    exit 1
fi

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "Erreur : la VM '$VM_NAME' existe déjà."
    exit 1
fi

if [ ! -f "/var/lib/libvirt/images/$IMAGE_NAME" ]; then
    echo "### Téléchargement de l'image Ubuntu 24.04 Noble ###"
    curl -L -o "$IMAGE_NAME" "$IMAGE_URL"
    sudo mv "$IMAGE_NAME" /var/lib/libvirt/images/
fi

# --- Cloud-init : User Data ---
TMP_USERDATA=$(mktemp)
cat <<EOF > "$TMP_USERDATA"
#cloud-config
hostname: inetsim
users:
  - name: cuckoo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat ~/.ssh/kvm/id_ed25519.pub)

package_update: true
packages:
  - inetsim
  - net-tools

runcmd:
  # Configuration INetSim pour écouter partout
  - sed -i 's/#service_bind_address   127.0.0.1/service_bind_address   0.0.0.0/' /etc/inetsim/inetsim.conf
  # Redirection DNS vers soi-même (Fake Internet)
  - sed -i 's/#dns_default_ip          10.10.10.1/dns_default_ip          $STATIC_IP/' /etc/inetsim/inetsim.conf
  # Forcer le redémarrage pour appliquer les binds
  - systemctl restart inetsim
EOF

# --- Cloud-init : Network Config ---
TMP_NETCONFIG=$(mktemp)
cat <<EOF > "$TMP_NETCONFIG"
version: 2
ethernets:
  enp1s0:
    dhcp4: no
    addresses:
      - $STATIC_IP/24
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
    routes:
      - to: default
        via: 192.168.122.1
EOF

echo "### Installation de la VM INetSim ###"

virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu24.04 \
  --disk size=10,backing_store="/var/lib/libvirt/images/$IMAGE_NAME",bus=virtio \
  --cloud-init user-data="$TMP_USERDATA",network-config="$TMP_NETCONFIG" \
  --network network=default,model=virtio \
  --noautoconsole

echo "VM $VM_NAME installée avec l'IP $STATIC_IP."
rm "$TMP_USERDATA" "$TMP_NETCONFIG"