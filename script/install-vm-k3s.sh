#!/bin/bash
set -euo pipefail

VM_NAME="k3s"
VOL_NAME="${1:-k3s.qcow2}"
POOL="default"
POOL_PATH="$2"
CLOUDINIT_PATH="$POOL_PATH/cloudinit"
IMAGE_PATH=$3
IP_K3S="$4"


# Vérifier si une VM du même nom existe
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    virsh destroy $VM_NAME >/dev/null 2>&1 || true
    virsh undefine $VM_NAME >/dev/null 2>&1 || true
fi

# Vérifier si un volume du même nom existe
if virsh vol-info --pool "$POOL" "$VOL_NAME" >/dev/null 2>&1; then
    virsh vol-delete $VM_NAME.qcow2 --pool $POOL >/dev/null
fi

# Générer une clé ssh
mkdir -p ~/.ssh/kvm/
if [ ! -f ~/.ssh/kvm/id_ed25519 ]; then
    echo -e "\n###############################################\n### création d'une clé SSH dans ~/.ssh/kvm/ ###\n###############################################"
    ssh-keygen -t ed25519 -f ~/.ssh/kvm/id_ed25519 -N "" -C ""
fi
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_K3S 2>/dev/null || true


sudo mkdir -p $CLOUDINIT_PATH/$VM_NAME

# appliquer la clé ssh au fichier de configuration user-data
sed "s|__SSH_KEY__|$(cat ~/.ssh/kvm/id_ed25519.pub)|" "$(pwd)/infra/$VM_NAME/vm-k3s.yaml" | sudo tee "$CLOUDINIT_PATH/$VM_NAME/user-data" > /dev/null

# ajouter les autres fichiers de config
sudo tee $CLOUDINIT_PATH/$VM_NAME/meta-data > /dev/null <<EOF
instance-id: iid-local01
local-hostname: $VM_NAME
EOF
sudo cp "$(pwd)/infra/$VM_NAME/network-config.yaml" $CLOUDINIT_PATH/$VM_NAME/network-config

echo -e "\n####################################\n### Création d'un ISO cloud-init ###\n####################################"
sudo xorriso -as genisoimage \
  -output $CLOUDINIT_PATH/$VM_NAME/cloudinit.iso \
  -volid cidata \
  -joliet -rock \
  $CLOUDINIT_PATH/$VM_NAME/user-data \
  $CLOUDINIT_PATH/$VM_NAME/meta-data \
  $CLOUDINIT_PATH/$VM_NAME/network-config


echo -e "\n#############################\n### installation de la VM ###\n#############################"
virt-install \
  --connect qemu:///system \
  --name $VM_NAME \
  --memory 3072 \
  --vcpus 3 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --import \
  --disk \
    size=9,backing_store="$IMAGE_PATH",bus=virtio \
  --disk path=$CLOUDINIT_PATH/$VM_NAME/cloudinit.iso,device=cdrom \
  --network network=default,model=virtio,mac=52:54:00:00:00:10 \
  --network network=default-nat,model=virtio,mac=52:54:00:00:00:20 \
  --controller type=usb,model=none \
  --features smm.state=on \
  --boot uefi,loader.secure=yes \
  --machine q35 \
  --noautoconsole
echo "VM $VM_NAME installé avec succès."