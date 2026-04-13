#!/bin/bash
set -euo pipefail

# --- Configuration ---
VM_NAME="inetsim"
IMAGE_NAME="jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
LIBVIRT_DIR="/var/lib/libvirt/images"
STATIC_IP="192.168.30.200"
SSH_KEY_PATH="$HOME/.ssh/kvm/id_ed25519.pub"

# --- 1. Host Infrastructure Check ---
if ! virsh net-info analysis &>/dev/null; then
    echo "Creating 'analysis' network on the host..."
    cat <<EOF > /tmp/analysis-net.xml
<network>
  <name>analysis</name>
  <bridge name='br0' stp='on' delay='0'/>
  <ip address='192.168.30.1' netmask='255.255.255.0'/>
</network>
EOF
    sudo virsh net-define /tmp/analysis-net.xml
    sudo virsh net-start analysis
    sudo virsh net-autostart analysis
fi

# Ensure the host actually has the IP to talk to the VM
sudo ip addr add 192.168.30.1/24 dev br0 2>/dev/null || true

echo "### [1/4] Preparing Base Image ###"
if [ ! -f "$LIBVIRT_DIR/$IMAGE_NAME" ]; then
    sudo wget -O "$LIBVIRT_DIR/$IMAGE_NAME" "$IMAGE_URL"
    sudo chmod 644 "$LIBVIRT_DIR/$IMAGE_NAME"
fi

echo "### [2/4] Cleaning Old Instances ###"
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

echo "### [3/4] Generating Autonomous Cloud-init ###"

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

runcmd:
  #Add INetSim Repository & GPG Key
  - wget -qO - https://www.inetsim.org/inetsim-archive-signing-key.asc | gpg --dearmor -o /usr/share/keyrings/inetsim-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/inetsim-archive-keyring.gpg] http://www.inetsim.org/debian/ binary/" > /etc/apt/sources.list.d/inetsim.list
  
  - apt-get update
  - apt-get install -y inetsim net-tools

  # Kill systemd-resolved (Liberate Port 53)
  - systemctl stop systemd-resolved
  - systemctl disable systemd-resolved
  - systemctl mask systemd-resolved
  - rm -f /etc/resolv.conf
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf

  - echo "127.0.0.1 inetsim" >> /etc/hosts

  - sed -i 's/^#*service_bind_address.*/service_bind_address 0.0.0.0/' /etc/inetsim/inetsim.conf
  - sed -i "s/^#*dns_default_ip.*/dns_default_ip $STATIC_IP/" /etc/inetsim/inetsim.conf

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
      - 192.168.30.200/24
EOF

echo "### [4/4] Deploying VM ###"
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
  --noautoconsole

echo "------------------------------------------------------"
echo "Deployment started! "
echo "Please wait 3 minutes for it to finish everything."
echo "Then check with: ssh -i ${SSH_KEY_PATH%.*} cuckoo@$STATIC_IP"
echo "------------------------------------------------------"

rm "$TMP_USERDATA" "$TMP_NETCONFIG"