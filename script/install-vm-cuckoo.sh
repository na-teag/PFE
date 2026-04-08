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

USERDATA_TEMPLATE="$(pwd)/infra/terraform/vm-cuckoo.yaml"
USERDATA_FILE="/tmp/cuckoo3-user-data.yaml"

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
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_PATH"
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

# Remplacer __SSH_KEY__ dans le template YAML
sed "s|__SSH_KEY__|$(cat "$USER_KEY_PUB")|" "$USERDATA_TEMPLATE" > "$USERDATA_FILE"

########################################
# Télécharger image Ubuntu si nécessaire
########################################
if [ ! -f "$IMG" ]; then
  curl -o "$HOME/jammy.img" https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
  sudo mv "$HOME/jammy.img" "$IMG"
fi

########################################
# Création VM
########################################
virt-install \
  --name "$VM_NAME" \
  --memory 6144 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk size=40,backing_store="$IMG",pool="$POOL" \
  --cloud-init user-data="$USERDATA_FILE",network-config="$(pwd)/infra/terraform/cuckoo-network-config.yaml" \
  --network network=default,model=virtio \
  --noautoconsole

echo "VM '$VM_NAME' créée : $IP_VM"
echo "Connexion : ssh -i $USER_KEY cuckoo@$IP_VM"

########################################
# Installer automatiquement Cuckoo3 via SSH
########################################
ssh-keygen -f "$HOME/.ssh/known_hosts" -R 192.168.122.3 2>/dev/null || true

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
scp -i "$USER_KEY" "$INSTALL_CUCKOO_SCRIPT" cuckoo@$IP_VM:/home/cuckoo/install_cuckoo.sh

echo "Lancement de l'installation sur la VM..."
ssh -t -i "$USER_KEY" cuckoo@$IP_VM 'chmod +x ~/install_cuckoo.sh && sudo ~/install_cuckoo.sh'

echo "Installation de Cuckoo3 terminée !"