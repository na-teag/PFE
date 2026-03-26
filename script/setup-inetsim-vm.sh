#!/bin/bash
set -euo pipefail

# --- Configuration ---
VM_NAME="inetsim"
IMAGE_NAME="jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
LIBVIRT_DIR="/var/lib/libvirt/images"
STATIC_IP="192.168.122.10"
SSH_KEY_PATH="$HOME/.ssh/kvm/id_ed25519.pub"

echo "### [1/4] Vérification de l'image de base ###"

# Automatisation du téléchargement de l'image
if [ ! -f "$LIBVIRT_DIR/$IMAGE_NAME" ]; then
    echo "Image introuvable. Téléchargement de Ubuntu Jammy (22.04)..."
    sudo wget -O "$LIBVIRT_DIR/$IMAGE_NAME" "$IMAGE_URL"
    sudo chmod 644 "$LIBVIRT_DIR/$IMAGE_NAME"
else
    echo "L'image $IMAGE_NAME est déjà présente."
fi

echo "### [2/4] Nettoyage de l'ancienne infrastructure ###"
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

echo "### [3/4] Préparation de la configuration Cloud-init ###"

# --- Cloud-init : User Data ---
TMP_USERDATA=$(mktemp)
cat <<EOF > "$TMP_USERDATA"
#cloud-config
hostname: inetsim
users:
  - name: cuckoo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_KEY_PATH")

package_update: true
packages:
  - inetsim
  - net-tools

runcmd:
  # Correction de l'erreur sudo
  - echo "127.0.0.1 inetsim" >> /etc/hosts

  # Neutralisation définitive de systemd-resolved pour libérer le port 53
  - systemctl stop systemd-resolved
  - systemctl disable systemd-resolved
  - systemctl mask systemd-resolved
  - rm -f /etc/resolv.conf
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf

  # Configuration INetSim (Regex robuste pour les bind addresses)
  - sed -i 's/^#*service_bind_address.*/service_bind_address 0.0.0.0/' /etc/inetsim/inetsim.conf
  - sed -i "s/^#*dns_default_ip.*/dns_default_ip $STATIC_IP/" /etc/inetsim/inetsim.conf

  # Démarrage du service
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

echo "### [4/4] Déploiement de la VM avec virt-install ###"

virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk size=10,backing_store="$LIBVIRT_DIR/$IMAGE_NAME",bus=virtio \
  --cloud-init user-data="$TMP_USERDATA",network-config="$TMP_NETCONFIG" \
  --network network=default,model=virtio \
  --noautoconsole

echo "------------------------------------------------------"
echo "VM $VM_NAME déployée avec succès !"
echo "IP statique : $STATIC_IP"
echo "Attendez 2-3 minutes pour la fin du setup interne."
echo "Connexion : ssh -i ${SSH_KEY_PATH%.*} cuckoo@$STATIC_IP"
echo "------------------------------------------------------"

rm "$TMP_USERDATA" "$TMP_NETCONFIG"