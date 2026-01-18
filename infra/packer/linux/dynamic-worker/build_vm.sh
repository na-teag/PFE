#!/bin/bash
set -euo pipefail

########################
# CONFIG
########################
VM_NAME="${1:-sandbox-ebpf}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKER_DIR="$SCRIPT_DIR"
PACKER_IMAGE="$PACKER_DIR/ebpf_sandbox/packer-ebpf_sandbox.qcow2"

USERDATA_TEMPLATE="user-data"

LIBVIRT_IMG_DIR="/var/lib/libvirt/images"
LIBVIRT_IMAGE="$LIBVIRT_IMG_DIR/${VM_NAME}.qcow2"

RAM_MB=2048
VCPUS=2
OS_VARIANT="ubuntu22.04"
NETWORK="default"

SSH_DIR="$HOME/.ssh/sandbox_key"
SSH_KEY="$SSH_DIR/id_ed25519"

########################
# CHECKS
########################
for cmd in packer virt-install virsh ssh-keygen; do
  command -v "$cmd" >/dev/null || { echo "[-] $cmd not installed"; exit 1; }
done

[[ -f "$USERDATA_TEMPLATE" ]] || { echo "[-] user-data not found"; exit 1; }

########################
# PACKER BUILD
########################
echo "[+] Running packer init"
cd "$PACKER_DIR"
packer init .

rm -f ~/.ssh/packer_ed25519 ~/.ssh/packer_ed25519.pub
ssh-keygen -t ed25519 -f ~/.ssh/packer_ed25519 -N "" -C ""

echo "[+] Running packer build"
packer build -force .

[[ -f "$PACKER_IMAGE" ]] || { echo "[-] Packer image not found"; exit 1; }

########################
# CLEAN EXISTING VM
########################
if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "[+] Removing existing VM"
  virsh destroy "$VM_NAME" || true
  virsh undefine "$VM_NAME" --remove-all-storage || true
fi

########################
# INSTALL IMAGE
########################
echo "[+] Installing qcow2 image"
sudo cp "$PACKER_IMAGE" "$LIBVIRT_IMAGE"
sudo chown libvirt-qemu:libvirt-qemu "$LIBVIRT_IMAGE"
sudo chmod 660 "$LIBVIRT_IMAGE"

########################
# SSH KEY GENERATION
########################
echo "[+] Generating SSH key"
rm -rf "$SSH_DIR"
mkdir -p "$SSH_DIR"
rm -f "$SSH_KEY" "$SSH_KEY.pub"

ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C ""

########################
# PREPARE USER-DATA
########################
TMP_USERDATA="$(mktemp)"
sed "s|__SSH_KEY__|$(cat "$SSH_KEY.pub")|" "$USERDATA_TEMPLATE" > "$TMP_USERDATA"

########################
# CREATE VM WITH CLOUD-INIT
########################
echo "[+] Creating VM with virt-install (cloud-init)"
sudo virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --disk path="$LIBVIRT_IMAGE",format=qcow2 \
  --os-variant "$OS_VARIANT" \
  --network network="$NETWORK",model=virtio \
  --graphics none \
  --noautoconsole \
  --import \
  --cloud-init user-data="$TMP_USERDATA"

VM_IP=$(virsh domifaddr sandbox-ebpf | awk '/ipv4/ {print $4}' | cut -d/ -f1)
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" 2>/dev/null || true