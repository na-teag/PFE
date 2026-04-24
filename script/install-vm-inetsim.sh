#!/bin/bash
set -euo pipefail

# --- Configuration ---
VM_NAME="inetsim"
IMAGE_NAME="$1"
LIBVIRT_DIR="$2"
IP_INETSIM="$3"
SSH_KEY_PATH="$HOME/.ssh/kvm/id_ed25519.pub"

# --- Host Infrastructure Check ---
echo "### [0/4] Setting up 'analysis' network ###"

# Détruire et recréer proprement à chaque fois pour éviter les états incohérents
sudo virsh net-destroy analysis 2>/dev/null || true
sudo virsh net-undefine analysis 2>/dev/null || true

cat <<NETEOF > /tmp/analysis-net.xml
<network>
  <name>analysis</name>
  <bridge name="virbr1" stp="on" delay="0"/>
  <ip address="192.168.40.1" netmask="255.255.255.0"/>
</network>
NETEOF

sudo virsh net-define /tmp/analysis-net.xml
sudo virsh net-start analysis
sudo virsh net-autostart analysis

# Vérification que virbr1 est bien monté
if ! ip link show virbr1 &>/dev/null; then
    echo "ERREUR: virbr1 n'est pas monté après création du réseau analysis"
    exit 1
fi
echo "Network 'analysis' ready (virbr1 @ 192.168.40.1/24)"

echo "### [1/3] Cleaning Old Instances ###"
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

echo "### [2/3] Generating Autonomous Cloud-init ###"
TMP_USERDATA=$(mktemp)
cat <<EOF > "$TMP_USERDATA"
#cloud-config
hostname: $VM_NAME
keyboard:
  layout: fr
  variant: ""
users:
  - name: $VM_NAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_KEY_PATH")

package_update: true
runcmd:
  # Ajout du dépôt INetSim
  - wget -qO - https://www.inetsim.org/inetsim-archive-signing-key.asc | gpg --dearmor -o /usr/share/keyrings/inetsim-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/inetsim-archive-keyring.gpg] http://www.inetsim.org/debian/ binary/" > /etc/apt/sources.list.d/inetsim.list
  - apt-get update && apt-get install -y inetsim net-tools

  # Libérer le port 53
  - systemctl stop systemd-resolved
  - systemctl disable systemd-resolved
  - systemctl mask systemd-resolved
  - rm -f /etc/resolv.conf
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf

  # Configurer INetSim
  - sed -i 's/^#*service_bind_address.*/service_bind_address 0.0.0.0/' /etc/inetsim/inetsim.conf
  - sed -i 's/^#*dns_default_ip.*/dns_default_ip $IP_INETSIM/' /etc/inetsim/inetsim.conf

  # Démarrer INetSim
  - systemctl enable inetsim
  - systemctl restart inetsim
EOF

TMP_NETCONFIG=$(mktemp)
cat <<EOF > "$TMP_NETCONFIG"
version: 2
ethernets:
  enp1s0:
    dhcp4: yes
  enp2s0:
    dhcp4: no
    addresses:
      - $IP_INETSIM/24
EOF

echo "### [3/3] Deploying VM ###"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk size=10,backing_store="$LIBVIRT_DIR/$IMAGE_NAME",bus=virtio \
  --cloud-init user-data="$TMP_USERDATA",network-config="$TMP_NETCONFIG" \
  --network network=default,model=virtio,mac=52:54:00:00:00:01 \
  --network network=analysis,model=virtio,mac=52:54:00:00:00:02 \
  --controller type=usb,model=none \
  --features smm.state=on \
  --boot uefi,loader.secure=yes \
  --noautoconsole

echo "------------------------------------------------------"
echo "Deployment started!"
echo "Please wait 3 minutes for cloud-init to finish."
echo "Then check with: ssh -i ${SSH_KEY_PATH%.*} $VM_NAME@$IP_INETSIM"
echo "------------------------------------------------------"

rm "$TMP_USERDATA" "$TMP_NETCONFIG"