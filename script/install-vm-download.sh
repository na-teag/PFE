#!/bin/bash
set -euo pipefail

# --- Configuration ---
VM_NAME="download"
POOL="default"
IP_DOWNLOAD="$1"
IP_GATEWAY="$2"
IMAGE_PATH=$3
POOL_PATH="$4"
CLOUDINIT_PATH="$POOL_PATH/cloudinit"
XML_PATH=".default-network.xml"
IP_K3S="$5"


if ! groups | grep -q "libvirt"; then
  sudo usermod -aG libvirt $USER
  newgrp libvirt
fi

echo -e "\n###############################################\n### Vérification du réseau default ###\n###############################################"


# Vérifier que le réseau default existe bien, le créer si non
if ! virsh net-info default &>/dev/null; then
  XML_PATH=".default-network.xml"
  cat > "$XML_PATH" <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:58:e6:ee'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.10' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_PATH"
fi
virsh net-start default &>/dev/null || true
virsh net-autostart default

# Ajouter l'IP à l'hôte sur le bridge pour accès
sudo ip addr add $IP_GATEWAY/24 dev virbr0 2>/dev/null || true

echo -e "\n###############################################\n### Vérification de la VM existante ###\n###############################################"

# Vérifier si une VM du même nom existe
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "Erreur : la VM '$VM_NAME' existe déjà." 1>&2
    echo "Pour supprimer la VM '$VM_NAME' tapez : virsh destroy $VM_NAME && virsh undefine $VM_NAME"
    exit 1
fi

echo -e "\n###############################################\n### Génération de la clé SSH ###\n###############################################"

# Générer une clé ssh
mkdir -p ~/.ssh/kvm/
if [ ! -f ~/.ssh/kvm/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/kvm/id_ed25519 -N "" -C ""
fi
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP_DOWNLOAD" 2>/dev/null || true

echo -e "\n#############################\n### Préparation de cloud-init ###\n#############################"

# Créer une config user-data personnalisée pour download
TMP_USERDATA="$(mktemp)"
cat > "$TMP_USERDATA" <<'EOF'
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_NAME
    shell: /bin/bash
    passwd: "$6$8HnNkXiciaai5RDJ$6sEe5zHc.uMcs3S62tamFUWDPY/Foey/krrTxPqRsLf6.WgE9IY/bs0fd2wEiw39z4qWzcgTetNVBr3VRiq8n."
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - __SSH_KEY__

keyboard:
  layout: fr
  variant: azerty

package_update: true
packages:
  - qemu-system-x86
  - qemu-utils

runcmd:
  # Appliquer le hostname
  - hostnamectl set-hostname $VM_NAME
  - sed -i 's/^127.0.0.1.*/127.0.0.1 localhost $VM_NAME/' /etc/hosts

  - systemctl stop systemd-resolved
  - systemctl disable systemd-resolved
  - systemctl mask systemd-resolved
  - rm -f /etc/resolv.conf
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf

EOF

# Remplacer le placeholder SSH_KEY par la vraie clé
sed -i "s|__SSH_KEY__|$(cat ~/.ssh/kvm/id_ed25519.pub)|" "$TMP_USERDATA"

# Créer une config réseau pour download
TMP_NETCONFIG="$(mktemp)"
cat > "$TMP_NETCONFIG" <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - $IP_DOWNLOAD/24
    gateway4: $IP_GATEWAY
    nameservers:
      addresses: [8.8.8.8]
EOF

sudo mkdir -p $CLOUDINIT_PATH/$VM_NAME

sudo tee $CLOUDINIT_PATH/$VM_NAME/meta-data > /dev/null <<EOF
instance-id: iid-local01
local-hostname: $VM_NAME
EOF

sudo cp "$TMP_USERDATA" $CLOUDINIT_PATH/$VM_NAME/user-data
sudo cp "$TMP_NETCONFIG" $CLOUDINIT_PATH/$VM_NAME/network-config

sudo xorriso -as genisoimage \
  -output $CLOUDINIT_PATH/$VM_NAME/cloudinit.iso \
  -volid cidata \
  -joliet -rock \
  $CLOUDINIT_PATH/$VM_NAME/user-data \
  $CLOUDINIT_PATH/$VM_NAME/network-config \
  $CLOUDINIT_PATH/$VM_NAME/meta-data


echo -e "\n#############################\n### Installation de la VM ###\n#############################"

virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk size=10,backing_store="$IMAGE_PATH",bus=virtio \
  --disk path=$CLOUDINIT_PATH/$VM_NAME/cloudinit.iso,device=cdrom\
  --noautoconsole \
  --controller type=usb,model=none \
  --features smm.state=on \
  --boot uefi,loader.secure=yes

echo "VM $VM_NAME installée avec succès."

echo "Démarrage de la VM..."
sleep 5
virsh start "$VM_NAME"

echo "Attente de la VM pour SSH..."
until ssh -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 $VM_NAME@$IP_DOWNLOAD 'echo SSH OK' &>/dev/null; do
    echo -n "."
    sleep 5
done

echo "Attente complète de cloud-init dans la VM, cela peut prendre quelques minutes..."
until ssh -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 $VM_NAME@$IP_DOWNLOAD \
  'test -f /var/lib/cloud/instance/boot-finished' &>/dev/null; do
    echo "cloud-init en cours..."
    sleep 5
done
echo "cloud-init terminé !"
echo "Pour accéder à la VM :"
echo "ssh -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 $VM_NAME@$IP_DOWNLOAD"
echo "pour copier un fichier dans la VM : scp -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 cheminFichier  $VM_NAME@$IP_DOWNLOAD:/home/download"
echo "pour envoyer un fichier à analyser : curl -k -X POST https://$IP_K3S/api/submit -F "file=@sample.exe" -F "sandbox_os=windows""