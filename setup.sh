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


# Installation rt mise en route de Cuckoo3 et service WEB/API
./script/install_cuckoo.sh


# lancer le fichier de création du .env et de son symlink
#./script/setup-env.sh

# lancer le service sandbox controller
if ! command -v python3 >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y python3 python3-pip
fi

pip install -r services/sandbox/controller/requirements.txt
uvicorn main:app --app-dir services/sandbox/controller --host 0.0.0.0 --port 9000 --log-level critical --no-access-log &
