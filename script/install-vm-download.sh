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
SSH_KEY_PATH="$HOME/.ssh/kvm/id_ed25519.pub"



echo -e "\n######################################\n### Vérification du réseau default ###\n######################################"


# Vérifier que le réseau default existe bien
if ! virsh net-info default &>/dev/null; then
	echo "Erreur, le réseau default n'existe pas"
	exit 1
fi

# Ajouter l'IP à l'hôte sur le bridge pour accès
sudo ip addr add $IP_GATEWAY/24 dev virbr0 2>/dev/null || true

echo -e "\n#######################################\n### Vérification de la VM existante ###\n#######################################"

# Vérifier si une VM du même nom existe
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
	echo "Erreur : la VM '$VM_NAME' existe déjà." 1>&2
	echo "Pour supprimer la VM '$VM_NAME' tapez : virsh destroy $VM_NAME && virsh undefine $VM_NAME"
	exit 1
fi

# Vérifier si un volume du même nom existe
if virsh vol-info --pool "$POOL" "$VM_NAME".qcow2 >/dev/null 2>&1; then
    virsh vol-delete $VM_NAME.qcow2 --pool $POOL
fi


# Générer une clé ssh
if [ ! -f ~/.ssh/kvm/id_ed25519 ]; then
	mkdir -p ~/.ssh/kvm/
	echo -e "\n################################\n### Génération de la clé SSH ###\n################################"
	ssh-keygen -t ed25519 -f ~/.ssh/kvm/id_ed25519 -N "" -C ""
fi
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP_DOWNLOAD" 2>/dev/null || true

echo -e "\n#################################\n### Préparation de cloud-init ###\n#################################"

sudo mkdir -p $CLOUDINIT_PATH/$VM_NAME

# Créer une config user-data personnalisée pour download
PASSWORD='$6$8HnNkXiciaai5RDJ$6sEe5zHc.uMcs3S62tamFUWDPY/Foey/krrTxPqRsLf6.WgE9IY/bs0fd2wEiw39z4qWzcgTetNVBr3VRiq8n.'
sudo tee $CLOUDINIT_PATH/$VM_NAME/user-data > /dev/null <<EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_NAME
    shell: /bin/bash
    passwd: "$PASSWORD"
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - $(cat "$SSH_KEY_PATH")

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

# Créer une config réseau pour download
sudo tee $CLOUDINIT_PATH/$VM_NAME/network-config > /dev/null <<EOF
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


sudo tee $CLOUDINIT_PATH/$VM_NAME/meta-data > /dev/null <<EOF
instance-id: iid-local01
local-hostname: $VM_NAME
EOF

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
  --import \
  --disk size=10,backing_store="$IMAGE_PATH",bus=virtio \
  --disk path=$CLOUDINIT_PATH/$VM_NAME/cloudinit.iso,device=cdrom\
  --noautoconsole \
  --controller type=usb,model=none \
  --features smm.state=on \
  --boot uefi,loader.secure=yes

echo "VM $VM_NAME installée avec succès."

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