#!/bin/bash
set -euo pipefail

# --- Configuration ---
VM_NAME="download"
POOL="default"
IMAGE_NAME="jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
STATIC_IP="192.168.122.15"
XML_PATH=".default-network.xml"


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
      <range start='192.168.122.3' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_PATH"
fi
virsh net-start default &>/dev/null || true
virsh net-autostart default

# Ajouter l'IP à l'hôte sur le bridge pour accès
sudo ip addr add 192.168.122.1/24 dev virbr0 2>/dev/null || true

echo -e "\n###############################################\n### Vérification de la VM existante ###\n###############################################"

# Vérifier si une VM du même nom existe
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "Erreur : la VM '$VM_NAME' existe déjà." 1>&2
    echo "Pour supprimer la VM '$VM_NAME' tapez : virsh destroy $VM_NAME && virsh undefine $VM_NAME"
    exit 1
fi

echo -e "\n###############################################\n### Téléchargement de l'image de base ###\n###############################################"

# Téléchargement de l'image
if [ ! -f "/var/lib/libvirt/images/$IMAGE_NAME" ]; then
    echo "Téléchargement de Ubuntu Jammy (22.04)..."
    curl -o "$IMAGE_NAME" "$IMAGE_URL"
    sudo mv "$IMAGE_NAME" /var/lib/libvirt/images/
else
    echo "L'image $IMAGE_NAME est déjà présente."
fi

echo -e "\n###############################################\n### Génération de la clé SSH ###\n###############################################"

# Générer une clé ssh
mkdir -p ~/.ssh/kvm/
if [ ! -f ~/.ssh/kvm/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/kvm/id_ed25519 -N "" -C ""
fi
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$STATIC_IP" 2>/dev/null || true

echo -e "\n#############################\n### Préparation de cloud-init ###\n#############################"

# Créer une config user-data personnalisée pour download
TMP_USERDATA="$(mktemp)"
cat > "$TMP_USERDATA" <<'EOF'
#cloud-config
hostname: download
users:
  - name: download
    shell: /bin/bash
    passwd: "$6$8HnNkXiciaai5RDJ$6sEe5zHc.uMcs3S62tamFUWDPY/Foey/krrTxPqRsLf6.WgE9IY/bs0fd2wEiw39z4qWzcgTetNVBr3VRiq8n."
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - __SSH_KEY__

ssh_pwauth: true
chpasswd:
  list: |
    analyst:infected
  expire: false

keyboard:
  layout: fr
  variant: azerty

package_update: true
packages:
  - inetsim
  - net-tools
  - qemu-system-x86
  - qemu-utils

runcmd:
  # Appliquer le hostname
  - hostnamectl set-hostname download
  - sed -i 's/^127.0.0.1.*/127.0.0.1 localhost download/' /etc/hosts
  
  # Appliquer la configuration du clavier azerty
  - echo 'XKBLAYOUT=fr' > /etc/default/keyboard
  - echo 'XKBVARIANT=azerty' >> /etc/default/keyboard
  - setupcon -k --force || true
  - localectl set-keymap fr || true
  
  # Configuration INetSim
  - sed -i 's/^#*service_bind_address.*/service_bind_address 0.0.0.0/' /etc/inetsim/inetsim.conf
  - sed -i "s/^#*dns_default_ip.*/dns_default_ip $STATIC_IP/" /etc/inetsim/inetsim.conf
  
  # Démarrage du service
  - systemctl restart inetsim
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
      - $STATIC_IP/24
    gateway4: 192.168.122.1
    nameservers:
      addresses: [8.8.8.8]
EOF

echo -e "\n#############################\n### Installation de la VM ###\n#############################"

virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk size=10,backing_store="/var/lib/libvirt/images/$IMAGE_NAME",bus=virtio \
  --import \
  --cloud-init user-data="$TMP_USERDATA",network-config="$TMP_NETCONFIG" \
  --network network=default,model=virtio \
  --noautoconsole

echo "VM $VM_NAME installée avec succès."

echo "Attente de la VM pour SSH..."
until ssh -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 download@$STATIC_IP 'echo SSH OK' &>/dev/null; do
    echo -n "."
    sleep 5
done
echo "VM prête !"

echo "Attente complète de cloud-init dans la VM (cela peut prendre quelques minutes..."
until ssh -o StrictHostKeyChecking=no -i ~/.ssh/kvm/id_ed25519 download@$STATIC_IP \
  'test -f /var/lib/cloud/instance/boot-finished' &>/dev/null; do
    echo "cloud-init en cours..."
    sleep 5
done
echo "cloud-init terminé !"