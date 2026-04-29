#!/bin/bash
set -euo pipefail

########################################
# Variables
########################################
VM_NAME="cuckoo"
VOL_NAME="${1:-cuckoo.qcow2}"
POOL="$2"
IP_VM="$3"
IMG="$4"

USER_SSH_DIR="$HOME/.ssh/kvm"
USER_KEY="$USER_SSH_DIR/id_ed25519_cuckoo"
USER_KEY_PUB="$USER_KEY.pub"

INSTALL_CUCKOO_SCRIPT="$(pwd)/infra/cuckoo3/install.sh"

USERDATA_TEMPLATE="$(pwd)/infra/cuckoo3/vm-cuckoo.yaml"

CLOUDINIT_DIR="/var/lib/libvirt/images/cloudinit/$VM_NAME"
CLOUDINIT_ISO="$CLOUDINIT_DIR/cloudinit.iso"



########################################
# Vérifier ou créer le réseau 'default'
########################################
if ! virsh net-info default &>/dev/null; then
  echo "Erreur, le réseau default n'existe pas"
  exit 1
fi

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
  --import \
  --disk size=25,backing_store="$IMG",pool="$POOL" \
  --disk path="$CLOUDINIT_ISO",device=cdrom \
  --network network=default,model=virtio,mac=52:54:00:00:00:03 \
  --network network=analysis,model=virtio,mac=52:54:00:00:00:04 \
  --controller type=usb,model=none \
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

