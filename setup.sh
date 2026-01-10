#!/bin/bash
set -euo pipefail

URL="http://192.168.122.2:8000/"

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

# Lancer terraform
cd infra/terraform
terraform init
#terraform apply -auto-approve
cd ../..

# Installation de la vm k3s (si terraform ne fonctionne pas)
./script/install-vm-k3s.sh # Temps d'installation (hors téléchargement) : 4-5mn

# Installation rt mise en route de Cuckoo3 et service WEB/API
./script/install_cuckoo.sh

# lancer le service sandbox controller
if ! command -v python3 >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y python3 python3-pip
fi

pip install --user -r services/sandbox/controller/requirements.txt

python3 -m uvicorn main:app \
  --app-dir services/sandbox/controller \
  --host 0.0.0.0 \
  --port 9000 \
  --log-level critical \
  --no-access-log &


# attendre que les services soient dispo
while true; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    if [[ "$STATUS" == "200" ]]; then
        echo "Service disponible."
        break
    else
        echo "Service non disponible (HTTP $STATUS). Nouvelle tentative dans 5 secondes..."
        sleep 10
    fi
done

# appliquer la clé VirusTotal via ssh
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo
ssh-keyscan -H 192.168.122.2 >> "$HOME/.ssh/known_hosts"
ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 "VT_KEY='$VT_KEY' bash -c '
kubectl patch secret vt-credentials -n malware-analysis --type=merge -p \"{\\\"stringData\\\":{\\\"VIRUSTOTAL_API_KEY\\\":\\\"\$VT_KEY\\\"}}\"
kubectl delete pod -n malware-analysis -l app=worker-static
echo ok
'"

# Afficher les informations de connexion à argocd
ssh k3s@192.168.122.2 -i ~/.ssh/kvm/id_ed25519 'echo "service ArgoCD : https://$(hostname -I | awk "{print \$1}"):$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.port==443)].nodePort}")"; echo "id : admin"; echo "pwd : $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"'

# afficher l'interface graphique du projet sur firefox
if ! command -v firefox >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y firefox
fi
firefox --new-tab "$URL" &