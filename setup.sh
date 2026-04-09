#!/bin/bash
set -euo pipefail

URL="http://192.168.122.2:8000/"
VM_K3S="k3s.qcow2"
#VM_EBPF="sandbox-ebpf"

# Ajouter les droits d'éxecution pour tout les scripts
sudo chmod +x infra/cuckoo3/install.sh
sudo chmod +x infra/packer/linux/dynamic-worker/build_vm.sh
sudo chmod +x script/*
#sudo chmod +x services/sandbox-controller/ebpf/analysis/run_analysis.sh

# Vérifier qu'il y a suffisament de place
./script/check_storage.sh $VM_K3S $VM_EBPF

# Installation de la vm k3s (si terraform ne fonctionne pas)
./script/install-vm-k3s.sh $VM_K3S # Temps d'installation (hors téléchargement) : 4-5mn

# Installation et mise en route de Cuckoo3 et service WEB/API
./script/install-vm-cuckoo.sh


# lancer le service sandbox controller
echo "Lancement du service sandbox controller..."
if ! command -v python3 >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y python3 python3-pip
fi

python3 -m venv venv
source venv/bin/activate
pip install -r services/sandbox-controller/ebpf/requirements.txt
uvicorn main:app --app-dir services/sandbox-controller/ebpf --host 0.0.0.0 --port 7070 --log-level warning --no-access-log &

# éteindre la golden VM
#virsh shutdown "$VM_EBPF"
#while [ "$(virsh domstate "$VM_EBPF")" != "shut off" ]; do
#    echo -e "\n\nAttente de l'arrêt de la VM..."
#    sleep 1
#done
#virsh autostart --disable "$VM_EBPF"



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
echo -e "\n\n"
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

# restart services to reload config
sudo systemctl restart cuckoo-api
sudo systemctl restart cuckoo

echo "setup terminé."
