#!/bin/bash
set -euo pipefail

XML_PATH=".default-network.xml"
VM_NAME="k3s"
VOL_NAME="${1:-k3s.qcow2}"
POOL="default"

sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  virt-manager \
  openssh-client
sudo systemctl enable --now libvirtd

if ! groups | grep -q "libvirt"; then
  sudo usermod -aG libvirt $USER
  newgrp libvirt # actualiser
fi



# Vérifier que virbr0 existe
if ! ip -d link show virbr0 2>/dev/null | grep -q "bridge"; then
  echo -e "\n\nerreur: le bridge virbr0 n'existe pas" 1>&2
  exit 1
fi

# vérifier que le réseau default existe bien, le créer si non
if ! virsh net-info default &>/dev/null; then
  cat > "$XML_PATH" <<'EOF'
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
# démarrer le réseau
virsh net-start default &>/dev/null || true
virsh net-autostart default



# Vérifier si une VM du même nom existe
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo -e "\n\nErreur : la VM '$VM_NAME' existe déjà." 1>&2
    echo "Pour supprimer la VM '$VM_NAME' tapez : virsh destroy $VM_NAME && virsh undefine $VM_NAME"
    exit 1
fi

# Vérifier si un volume du même nom existe
if virsh vol-info --pool "$POOL" "$VOL_NAME" >/dev/null 2>&1; then
    echo -e "\n\nErreur : le volume '$VOL_NAME' existe déjà dans le pool '$POOL'." 1>&2
    echo "Pour supprimer le volume '$VOL_NAME' tapez : virsh vol-delete $VM_NAME.qcow2 --pool $POOL"
    exit 1
fi

# Générer une clé ssh
mkdir -p ~/.ssh/kvm/
rm -f ~/.ssh/kvm/id_ed25519 ~/.ssh/kvm/id_ed25519.pub
ssh-keygen -t ed25519 -f ~/.ssh/kvm/id_ed25519 -N "" -C ""
ssh-keygen -f "$HOME/.ssh/known_hosts" -R 192.168.122.2 2>/dev/null || true

# Temps d'installation (hors téléchargement) : 4-5mn
if [ ! -f "/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img" ]; then
    echo -e "\n##########################################\n### Téléchargement de l'image de la VM ###\n##########################################"
    curl -o jammy-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
    sudo mv jammy-server-cloudimg-amd64.img /var/lib/libvirt/images/
fi
TMP_USERDATA="$(mktemp)"
sed "s|__SSH_KEY__|$(cat ~/.ssh/kvm/id_ed25519.pub)|" "$(pwd)/infra/terraform/vm-k3s.yaml" > "$TMP_USERDATA"
echo -e "\n#############################\n### installation de la VM ###\n#############################"
virt-install \
  --connect qemu:///system \
  --name $VM_NAME \
  --memory 3072 \
  --vcpus 3 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk \
    size=10,backing_store="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img",bus=virtio \
  --cloud-init \
    user-data="$TMP_USERDATA",network-config="$(pwd)/infra/terraform/network-config.yaml" \
  --network \
    network=default,model=virtio \
  --noautoconsole
echo "VM $VM_NAME installé avec succès."