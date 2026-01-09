#!/bin/bash

# TODO
# Tester qu'il n'existe pas déjà une VM et un disque du même nom

# Temps d'installation (hors téléchargement) : 4-5mn
echo "Téléchargement de l'image de la VM..."
curl -o jammy-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
sudo mv jammy-server-cloudimg-amd64.img /var/lib/libvirt/images/
echo "installation de la VM..."
virt-install \
  --name k3s \
  --memory 3072 \
  --vcpus 3 \
  --cpu host \
  --os-variant ubuntu22.04 \
  --disk \
    size=10,backing_store="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img",bus=virtio \
  --cloud-init \
    user-data="$(pwd)/infra/terraform/vm-k3s.yaml",network-config="$(pwd)/infra/terraform/network-config.yaml" \
  --network \
    network=default,model=virtio \
  --noautoconsole