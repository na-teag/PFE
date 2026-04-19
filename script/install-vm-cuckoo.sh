#!/bin/bash
set -euo pipefail

########################################
# Variables
########################################
VM_NAME="cuckoo"
VOL_NAME="${1:-cuckoo.qcow2}"
POOL="default"
IP_VM="192.168.122.3"
IMG="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"

USER_SSH_DIR="$HOME/.ssh/kvm"
USER_KEY="$USER_SSH_DIR/id_ed25519_cuckoo"
USER_KEY_PUB="$USER_KEY.pub"

INSTALL_CUCKOO_SCRIPT="$(pwd)/infra/cuckoo3/install.sh"

USERDATA_TEMPLATE="$(pwd)/infra/cuckoo3/vm-cuckoo.yaml"

CLOUDINIT_DIR="/var/lib/libvirt/images/cloudinit/$VM_NAME"
CLOUDINIT_ISO="$CLOUDINIT_DIR/cloudinit.iso"

########################################
# Dépendances
########################################
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils \
  openssh-client

sudo systemctl enable --now libvirtd

if ! groups | grep -q "libvirt"; then
  sudo usermod -aG libvirt $USER
  newgrp libvirt
fi

########################################
# Vérifier ou créer le réseau 'default'
########################################
if ! virsh net-info default &>/dev/null; then
  XML_PATH="$HOME/.default-network.xml"
  cat > "$XML_PATH" <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:58:e6:ee'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.3' end='192.168.122.254'/>
      <host mac='52:54:00:00:00:03' name='cuckoo' ip='192.168.122.3'/>
      <host mac='52:54:00:00:00:01' name='inetsim' ip='192.168.122.100'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_PATH"
else
  virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:00:00:03' name='cuckoo' ip='192.168.122.3'/>" \
    --live --config 2>/dev/null || true
  virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:00:00:01' name='inetsim' ip='192.168.122.100'/>" \
    --live --config 2>/dev/null || true
fi
virsh net-start default &>/dev/null || true
virsh net-autostart default

########################################
# Supprimer VM/volume existants
########################################
if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "VM existante détectée, suppression..."
  virsh destroy "$VM_NAME" || true
  virsh undefine "$VM_NAME"
fi

if virsh vol-info --pool "$POOL" "$VOL_NAME" &>/dev/null; then
  echo "Volume existant détecté, suppression..."
  virsh vol-delete "$VOL_NAME" --pool "$POOL"
fi

########################################
# Génération clé SSH
########################################
mkdir -p "$USER_SSH_DIR"
rm -f "$USER_KEY" "$USER_KEY_PUB"
ssh-keygen -t ed25519 -f "$USER_KEY" -N "" -C ""

########################################
# Télécharger image Ubuntu si nécessaire
########################################
if [ ! -f "$IMG" ]; then
  curl -o "$HOME/jammy.img" https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
  sudo mv "$HOME/jammy.img" "$IMG"
fi

########################################
# Créer ISO cloud-init
########################################
sudo mkdir -p "$CLOUDINIT_DIR"

sed "s|__SSH_KEY__|$(cat "$USER_KEY_PUB")|" "$USERDATA_TEMPLATE" | \
  sudo tee "$CLOUDINIT_DIR/user-data" > /dev/null

sudo tee "$CLOUDINIT_DIR/meta-data" > /dev/null <<EOF
instance-id: iid-local01
local-hostname: $VM_NAME
EOF

sudo cp "$(pwd)/infra/cuckoo3/cuckoo-network-config.yaml" \
  "$CLOUDINIT_DIR/network-config"

sudo xorriso -as genisoimage \
  -output "$CLOUDINIT_ISO" \
  -volid cidata \
  -joliet -rock \
  "$CLOUDINIT_DIR/user-data" \
  "$CLOUDINIT_DIR/meta-data" \
  "$CLOUDINIT_DIR/network-config"

########################################
# Création de la VM avec UEFI + Secure Boot
########################################
virt-install \
  --name "$VM_NAME" \
  --memory 6144 \
  --vcpus 2 \
  --cpu host-passthrough,cache.mode=passthrough \
  --os-variant ubuntu22.04 \
  --disk size=40,backing_store="$IMG",pool="$POOL" \
  --disk path="$CLOUDINIT_ISO",device=cdrom \
  --network network=default,model=virtio,mac=52:54:00:00:00:03 \
  --network network=analysis,model=virtio,mac=52:54:00:00:00:04 \
  --features smm.state=on \
  --boot uefi,loader.secure=yes \
  --machine q35 \
  --noautoconsole

echo "VM '$VM_NAME' créée : $IP_VM"
echo "Connexion : ssh -i $USER_KEY cuckoo@$IP_VM"

########################################
# Installer automatiquement Cuckoo3 via SSH
########################################

ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_VM 2>/dev/null || true

echo "Attente de la VM pour SSH..."
until ssh -o StrictHostKeyChecking=no -i "$USER_KEY" cuckoo@$IP_VM 'echo SSH OK' &>/dev/null; do
    echo -n "."
    sleep 5
done
echo "VM prête !"

echo "Attente complète de cloud-init dans la VM (cela peut prendre entre 3 et 10 min)..."
until ssh -o StrictHostKeyChecking=no -i "$USER_KEY" cuckoo@$IP_VM \
  'test -f /var/lib/cloud/instance/boot-finished' &>/dev/null; do
    echo "cloud-init en cours..."
    sleep 5
done
echo "cloud-init terminé !"

echo "Transfert du script d'installation de Cuckoo3..."
scp -i "$USER_KEY" "$INSTALL_CUCKOO_SCRIPT" cuckoo@$IP_VM:/home/cuckoo/install-cuckoo.sh

echo "Lancement de l'installation sur la VM..."
ssh -t -i "$USER_KEY" cuckoo@$IP_VM 'chmod +x ~/install-cuckoo.sh && sudo ~/install-cuckoo.sh'

echo "Installation de Cuckoo3 terminée !"

# Copier la clé de l'api Cuckoo
ssh -i $USER_KEY cuckoo@$IP_VM "cat /home/cuckoo/cuckoo_api_key.txt" > "$(pwd)/cuckoo_api_key.txt"
chmod 600 "$(pwd)/cuckoo_api_key.txt"

#Supprimer la clé de l'api Cuckoo de la VM
ssh -i "$USER_KEY" cuckoo@$IP_VM "shred -u /home/cuckoo/cuckoo_api_key.txt"

