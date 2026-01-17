#!/bin/bash
set -euo pipefail

URL="http://192.168.122.2:8000/"
VM_K3S="k3s.qcow2"
VM_PACKER="packer-ebpf_sandbox.qcow2"

# Vérifier qu'il y a suffisament de place
./script/check_storage.sh $VM_K3S $VM_PACKER

# Installer terraform si absent
if ! terraform --version >/dev/null 2>&1; then
    echo -e "\n#################################\n### Installation de Terraform ###\n#################################"
    wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update
    sudo apt install terraform
fi

# Lancer terraform
cd infra/terraform
terraform init
#terraform apply -auto-approve
cd ../..

# Installation de la vm k3s (si terraform ne fonctionne pas)
./script/install-vm-k3s.sh $VM_K3S # Temps d'installation (hors téléchargement) : 4-5mn

# Installation et mise en route de Cuckoo3 et service WEB/API
./script/install_cuckoo.sh

# TODO lancer le script d'installation de sandbox linux en passant $VM_PACKER

# lancer le service sandbox controller
echo "Lancement du service sandbox controller..."
if ! command -v python3 >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y python3 python3-pip
fi


# attendre que les services soient dispo
echo -e "\n\n"
echo "Merci de patienter jusqu'au démarrage complet des services sur la VM..."
echo
while true; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    if [[ "$STATUS" == "200" ]]; then
        echo "Services disponibles."
        break
    else
        echo "Services non disponible (HTTP $STATUS). Nouvelle tentative dans 10 secondes..."
        sleep 10
    fi
done

# appliquer la clé VirusTotal via ssh
echo
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo

# lire la clé Cuckoo API depuis un fichier local (sur ta machine)
CUCKOO_API_KEY="$(cat "$(pwd)/cuckoo_api_key.txt")"

ssh-keyscan -H 192.168.122.2 >> "$HOME/.ssh/known_hosts"
ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 "VT_KEY='$VT_KEY' CUCKOO_KEY='$CUCKOO_API_KEY' bash -c '
kubectl patch secret vt-credentials -n malware-analysis --type=merge -p \"{\\\"stringData\\\":{\\\"VIRUSTOTAL_API_KEY\\\":\\\"\$VT_KEY\\\",\\\"CUCKOO_API_KEY\\\":\\\"\$CUCKOO_KEY\\\"}}\"
kubectl delete pod -n malware-analysis -l app=worker-static
kubectl delete pod -n malware-analysis -l app=sandbox-controller
echo ok
'"

# Afficher les informations de connexion à argocd
echo -e "\n\n"
ssh k3s@192.168.122.2 -i ~/.ssh/kvm/id_ed25519 'echo "service ArgoCD : https://$(hostname -I | awk "{print \$1}"):$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.port==443)].nodePort}")"; echo "id : admin"; echo "pwd : $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"'

# afficher l'interface graphique du projet sur firefox
if ! command -v firefox >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y firefox
fi
firefox --new-tab "$URL" &
echo "setup terminé."