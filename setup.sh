#!/bin/bash

# Installer terraform si absent
if terraform --version >/dev/null 2>&1; then
    echo "Terraform est déjà installé"
else
    echo "Installation de Terraform..."
    wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update
    sudo apt install terraform
fi


# Installer Drakvuf



# lancer le fichier de création du .env et de son symlink
./script/setup-env.sh