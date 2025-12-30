#!/bin/bash
set -eux

VM_IMAGE="$1"
SAMPLE_PATH="$2"
RESULT_FILE="$3"

MEMORY=2048
CPUS=2
VM_NAME="sandbox-test"

WORKDIR=$(mktemp -d)
echo "[+] Workdir: $WORKDIR"

# 1️⃣ Copier le malware dans un dossier accessible à la VM
cp "$SAMPLE_PATH" "$WORKDIR/sample.bin"

# 2️⃣ Lancer la VM
qemu-system-x86_64 \
  -name "$VM_NAME" \
  -m "$MEMORY" \
  -smp "$CPUS" \
  -drive file="$VM_IMAGE",if=virtio,format=qcow2,snapshot=on \
  -enable-kvm \
  -netdev user,id=net0 \
  -device virtio-net,netdev=net0 \
  -daemonize

sleep 15

# 3️⃣ Lancer Drakvuf
# Exemple minimal (à adapter selon ton setup Xen/KVM)
drakvuf \
  -r "$VM_IMAGE" \
  -o json \
  > "$RESULT_FILE"

# 4️⃣ Stopper la VM
pkill -f "qemu-system-x86_64.*$VM_NAME" || true

echo "[+] Analyse terminée"
