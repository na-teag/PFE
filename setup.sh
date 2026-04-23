#!/bin/bash
set -euo pipefail

VM_K3S="k3s.qcow2"
IP="192.168.122.2"
NAMESPACE="malware-analysis"
SSH_KEY="$HOME/.ssh/kvm/id_ed25519"
SSH_TARGET="k3s@${IP}"
CERT_DIR="./certs"
URL="https://192.168.122.2/"

# Ajouter les droits d'éxecution pour tout les scripts
sudo chmod +x infra/cuckoo3/install.sh
sudo chmod +x script/*

# Vérifier qu'il y a suffisament de place
#./script/check_storage.sh $VM_K3S $VM_EBPF

# Installation et mise en route de Cuckoo3 et service WEB/API + INetSim
./script/install-vm-inetsim.sh
./script/install-vm-cuckoo.sh

# Installation de la vm k3s
./script/install-vm-k3s.sh $VM_K3S # Temps d'installation (hors téléchargement) : 4-5mn
./script/install-vm-download.sh # Temps d'installation (hors téléchargement) : 3-4 mn


# attendre que les services soient dispo
echo -e "\n\n"
echo "Merci de patienter jusqu'au démarrage complet des services sur la VM..."
echo
while true; do
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    if [[ "$STATUS" == "200" ]]; then
        echo "Services disponibles."
        break
    else
        echo "Services non disponible (HTTP $STATUS). Nouvelle tentative dans 10 secondes..."
        sleep 10
    fi
done

# appliquer la clé VirusTotal via ssh
#echo -e "\n\n"
#read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
#echo

# lire la clé Cuckoo API depuis un fichier local (sur ta machine)
#CUCKOO_API_KEY="$(cat "$(pwd)/cuckoo_api_key.txt")"

#générer la clé API
#API_KEY=$(openssl rand -base64 32)

#ssh-keyscan -H 192.168.122.2 >> "$HOME/.ssh/known_hosts"
#ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 "kubectl create namespace malware-analysis --dry-run=client -o yaml | kubectl apply -f -"
#ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 "VT_KEY='$VT_KEY' CUCKOO_KEY='$CUCKOO_API_KEY' API_KEY='$API_KEY' bash -c '
#kubectl patch secret vt-credentials -n malware-analysis --type=merge -p \"{\\\"stringData\\\":{\\\"VIRUSTOTAL_API_KEY\\\":\\\"\$VT_KEY\\\",\\\"CUCKOO_API_KEY\\\":\\\"\$CUCKOO_KEY\\\",\\\"API_KEY\\\":\\\"\$API_KEY\\\"}}\"
#kubectl delete pod -n malware-analysis -l app=worker-static
#kubectl delete pod -n malware-analysis -l app=sandbox-controller
#echo ok
#'"


########################################
# Configuration des Secrets et Application
########################################
echo "=== Configuration des Secrets et Application ArgoCD ==="

# Récupération des clés nécessaires
echo -e "\n"
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo
# Vérification rapide pour éviter les variables vides
if [ -z "$VT_KEY" ]; then echo "Erreur: La clé VT est vide."; exit 1; fi

CUCKOO_API_KEY="$(cat "$(pwd)/cuckoo_api_key.txt")"
API_KEY=$(openssl rand -base64 32)

# Créer le namespace
ssh -i "$SSH_KEY" "$SSH_TARGET" "kubectl create namespace malware-analysis --dry-run=client -o yaml | kubectl apply -f -"

# Créer le secret vt-credentials
# Le 'cat <<EOF' permet d'injecter tes variables locales directement dans le flux SSH
ssh -i "$SSH_KEY" "$SSH_TARGET" "cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vt-credentials
  namespace: malware-analysis
stringData:
  VIRUSTOTAL_API_KEY: '$VT_KEY'
  CUCKOO_API_KEY: '$CUCKOO_API_KEY'
  API_KEY: '$API_KEY'
type: Opaque
EOF"

# Appliquer l'application ArgoCD
# On lit le fichier local et on le pousse via le pipe
cat infra/argocd/malware-analysis-app.yaml | ssh -i "$SSH_KEY" "$SSH_TARGET" "kubectl apply -f - -n argocd"

# Nettoyage des pods pour forcer le redémarrage avec les nouveaux secrets
ssh -i "$SSH_KEY" "$SSH_TARGET" "kubectl delete pod -n malware-analysis -l app=worker-static --ignore-not-found"
ssh -i "$SSH_KEY" "$SSH_TARGET" "kubectl delete pod -n malware-analysis -l app=sandbox-controller --ignore-not-found"


########################################
# Création du certificat TLS si nécessaire
########################################
mkdir -p "$CERT_DIR"
echo "=== Génération du certificat TLS ==="
if [[ ! -f "$CERT_DIR/tls.crt" || ! -f "$CERT_DIR/tls.key" ]]; then
    openssl req -x509 -nodes \
    -newkey rsa:4096 \
    -keyout "${CERT_DIR}/tls.key" \
    -out    "${CERT_DIR}/tls.crt" \
    -days   365 \
    -subj   "/CN=${IP}/O=MalwareAnalysis" \
    -addext "subjectAltName=IP:${IP}"
fi

# 2. Pousser le Secret TLS sur K3s
echo "=== Déploiement du Secret TLS ==="
scp -i "$SSH_KEY" "${CERT_DIR}/tls.crt" "${CERT_DIR}/tls.key" "${SSH_TARGET}:/tmp/"
ssh -i "$SSH_KEY" "$SSH_TARGET" "
  kubectl create secret tls api-tls \
    --cert=/tmp/tls.crt \
    --key=/tmp/tls.key \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f - && \
  rm -f /tmp/tls.crt /tmp/tls.key
"


echo "=== Configuration de Traefik sur le port 443 ==="
ssh -i "$SSH_KEY" "$SSH_TARGET" '
  TRAEFIK_SVC=$(kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik -o name | head -1)
  kubectl patch "$TRAEFIK_SVC" -n kube-system --type=merge -p '"'"'{
    "spec": {
      "type": "LoadBalancer",
      "ports": [
        {"name": "web", "port": 80, "targetPort": "web", "protocol": "TCP"},
        {"name": "websecure", "port": 443, "targetPort": "websecure", "protocol": "TCP"}
      ]
    }
  }'"'"'
  echo "Traefik sur port 443"
  '

ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 \
  "kubectl patch svc argocd-server -n argocd --type=merge -p '{\"spec\":{\"type\":\"NodePort\"}}'"

# On crée un service pour forcer le bon redéploiement d'argocd à chaque redémarrage de la vm
cat << 'EOF' | ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 'cat > /tmp/fix-argocd.sh'
cat > /etc/systemd/system/fix-argocd.service << 'UNIT'
[Unit]
Description=Fix argocd-repo-server after boot
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
Environment=KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ExecStart=/bin/bash -c 'until /usr/local/bin/kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do echo "Attente k3s..."; sleep 5; done; sleep 10; /usr/local/bin/kubectl rollout restart deployment argocd-repo-server -n argocd'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable fix-argocd.service
echo "Service créé et activé."
EOF

ssh -t -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 'sudo bash /tmp/fix-argocd.sh && rm /tmp/fix-argocd.sh'

# Afficher les informations de connexion à argocd
echo -e "\n\n"
ssh k3s@192.168.122.2 -i ~/.ssh/kvm/id_ed25519 'echo "service ArgoCD : https://$(hostname -I | awk "{print \$1}"):$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.port==443)].nodePort}")"; echo "id : admin"; echo "pwd : $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"'

# Afficher la clé API
echo "API KEY: $API_KEY"

# Faire confiance au certificat localement
sudo cp "${CERT_DIR}/tls.crt" /usr/local/share/ca-certificates/malware-analysis.crt 
sudo update-ca-certificates

# afficher l'interface graphique du projet sur firefox
if ! command -v firefox >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y firefox
fi
firefox --new-tab "$URL" &

echo "setup terminé."
