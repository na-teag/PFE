#!/bin/bash
set -euo pipefail

########################
# CONFIG
########################
VM_NAME="sandbox-ebpf"
PACKER_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKER_TEMPLATE="packer.pkr.hcl"

PACKER_OUTPUT_DIR="$PACKER_DIR/ebpf_sandbox"
PACKER_IMAGE="$PACKER_OUTPUT_DIR/packer-ebpf_sandbox.qcow2"

LIBVIRT_IMG_DIR="/var/lib/libvirt/images"
LIBVIRT_IMAGE="$LIBVIRT_IMG_DIR/${VM_NAME}.qcow2"

RAM_MB=2048
VCPUS=2
DISK_SIZE=20
OS_VARIANT="ubuntu22.04"
NETWORK="default"

########################
# CHECKS
########################
command -v packer >/dev/null || { echo "[-] packer not installed"; exit 1; }
command -v virt-install >/dev/null || { echo "[-] virt-install not installed"; exit 1; }
command -v virsh >/dev/null || { echo "[-] virsh not installed"; exit 1; }

########################
# PACKER INIT
########################
echo "[+] Running packer init"
cd "$PACKER_DIR"
packer init .

########################
# PACKER BUILD
########################
echo "[+] Running packer build"
packer build -force .

if [[ ! -f "$PACKER_IMAGE" ]]; then
  echo "[-] Packer image not found: $PACKER_IMAGE"
  exit 1
fi

########################
# CLEAN EXISTING VM
########################
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "[+] Existing VM found, destroying it"
  virsh destroy "$VM_NAME" || true
  virsh undefine "$VM_NAME" --remove-all-storage || true
fi

########################
# INSTALL IMAGE
########################
echo "[+] Installing qcow2 to libvirt images"
sudo mkdir -p "$LIBVIRT_IMG_DIR"
sudo cp "$PACKER_IMAGE" "$LIBVIRT_IMAGE"
sleep 2
sudo chown libvirt-qemu:libvirt-qemu "$LIBVIRT_IMAGE"
sudo chmod 660 "$LIBVIRT_IMAGE"
sleep 2

########################
# CREATE VM
########################
echo "[+] Creating VM with virt-install"

sudo virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --disk path="$LIBVIRT_IMAGE",format=qcow2 \
  --os-variant "$OS_VARIANT" \
  --network network="$NETWORK",model=virtio \
  --graphics none \
  --noautoconsole \
  --import

########################
# DONE
########################
echo "[+] VM '$VM_NAME' created and started"
echo "[+] Use: virsh domifaddr $VM_NAME"
