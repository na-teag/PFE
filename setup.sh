#!/bin/bash
set -euo pipefail

K3S_NAME="k3s"
NAMESPACE="malware-analysis"

VM_K3S="$K3S_NAME.qcow2"
VM_INETSIM="inetsim.qcow2"
VM_DOWNLOAD="download.qcow2"
VM_CUCKOO="cuckoo.qcow2"

IP_K3S="192.168.122.2"
IP_INETSIM="192.168.40.200"
IP_DOWNLOAD="192.168.122.15"
IP_CUCKOO="192.168.122.3"
IP_GATEWAY="192.168.122.1"

SSH_KEY="$HOME/.ssh/kvm/id_ed25519"
SSH_KEY_CUCKOO="$HOME/.ssh/kvm/id_ed25519_cuckoo"

SSH_TARGET_K3S="$K3S_NAME@${IP_K3S}"
SSH_TARGET_CUCKOO="cuckoo@$IP_CUCKOO"
SSH_TARGET_DOWNLOAD="download@$IP_DOWNLOAD"
SSH_TARGET_INSETSIM="inetsim@$IP_INETSIM"

CERT_DIR="./certs"
URL="https://$IP_K3S/"
IMAGE_VERSION="jammy"
IMAGE_NAME="$IMAGE_VERSION-server-cloudimg-amd64.img"
POOL_NAME="default"
POOL_PATH="/var/lib/libvirt/images"
IMAGE_PATH="$POOL_PATH/$IMAGE_NAME"

# Ajouter les droits d'éxecution pour tout les scripts
sudo chmod +x infra/cuckoo3/install.sh
sudo chmod +x script/*

# Vérifier qu'il y a suffisament de place
./script/check_storage.sh $VM_K3S $VM_DOWNLOAD $VM_INETSIM $VM_CUCKOO $IMAGE_NAME $POOL_PATH

# Temps d'installation (hors téléchargement) : 4-5mn
if [ ! -f "$IMAGE_PATH" ]; then
    echo -e "\n##########################################\n### Téléchargement de l'image de la VM ###\n##########################################"
    curl -o $IMAGE_NAME https://cloud-images.ubuntu.com/$IMAGE_VERSION/current/$IMAGE_NAME
    sudo mv $IMAGE_NAME $POOL_PATH
fi

# Installation de la vm k3s
./script/install-vm-k3s.sh $VM_K3S $POOL_PATH $IMAGE_PATH # Temps d'installation (hors téléchargement) : 4-5mn
./script/install-vm-download.sh $IP_DOWNLOAD $IP_GATEWAY $IMAGE_PATH $POOL_PATH $IP_K3S # Temps d'installation (hors téléchargement) : 3-4 mn

# Installation et mise en route de Cuckoo3 et service WEB/API + INetSim
./script/install-vm-inetsim.sh $IMAGE_NAME $POOL_PATH $IP_INETSIM
./script/install-vm-cuckoo.sh $VM_CUCKOO $POOL_NAME $IP_CUCKOO $IMAGE_PATH


# attendre que les services soient dispo
echo -e "\n\n"
echo "Merci de patienter jusqu'au démarrage complet des services sur la VM..."
echo
while true; do
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    PODS=$(ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl get pods -n malware-analysis --no-headers | grep -c "Running"")
    if [[ "$STATUS" == "200" &&  "$PODS" == "7" ]]; then
        echo "Services disponibles."
        break
    else
        echo -e "Services non disponible (réponse HTTP: $STATUS, pods démarrés : $PODS/7).\nNouvelle tentative dans 10 secondes..."
        sleep 10
    fi
done


########################################
# Configuration des Secrets et Application
########################################
echo "=== Configuration des Secrets et Application ArgoCD ==="

# Récupération des clés nécessaires
echo -e "\n"
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo
if [ -z "$VT_KEY" ]; then echo "Erreur: La clé VT est vide."; exit 1; fi

CUCKOO_API_KEY="$(cat "$(pwd)/cuckoo_api_key.txt")"
API_KEY=$(openssl rand -base64 32)


# Créer le secret vt-credentials
ssh-keyscan -H $IP_K3S >> "$HOME/.ssh/known_hosts"
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "cat <<EOF | kubectl apply -f -
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


# Nettoyage des pods pour forcer le redémarrage avec les nouveaux secrets
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl delete pod -n malware-analysis -l app=worker-static"
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl delete pod -n malware-analysis -l app=sandbox-controller"


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
    -subj   "/CN=${IP_K3S}/O=MalwareAnalysis" \
    -addext "subjectAltName=IP_K3S:${IP_K3S}"
fi

# 2. Pousser le Secret TLS sur K3s
echo "=== Déploiement du Secret TLS ==="
scp -i "$SSH_KEY" "${CERT_DIR}/tls.crt" "${CERT_DIR}/tls.key" "${SSH_TARGET_K3S}:/tmp/"
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "
  kubectl create secret tls api-tls \
    --cert=/tmp/tls.crt \
    --key=/tmp/tls.key \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f - && \
  rm -f /tmp/tls.crt /tmp/tls.key
"


echo "=== Configuration de Traefik sur le port 443 ==="
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" '
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

# On crée un service pour forcer le bon redéploiement d'argocd à chaque redémarrage de la vm
cat << 'EOF' | ssh -i ~/.ssh/kvm/id_ed25519 $SSH_TARGET_K3S 'cat > /tmp/fix-argocd.sh'
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

ssh -t -i ~/.ssh/kvm/id_ed25519 $SSH_TARGET_K3S 'sudo bash /tmp/fix-argocd.sh && rm /tmp/fix-argocd.sh'

# Faire confiance au certificat localement
sudo cp "${CERT_DIR}/tls.crt" /usr/local/share/ca-certificates/malware-analysis.crt
sudo update-ca-certificates

echo -e "\n=== Hardening des VMs ==="
echo -e "\n=== Hardening de k3s ==="
ssh -i $SSH_KEY -t $SSH_TARGET_K3S "sudo bash -s" < $(pwd)/script/hardening.sh
echo -e "\n=== Hardening de download ==="
ssh -i $SSH_KEY -t $SSH_TARGET_DOWNLOAD "sudo bash -s" < $(pwd)/script/hardening.sh
echo -e "\n=== Hardening de cuckoo ==="
ssh -i $SSH_KEY_CUCKOO -t $SSH_SSH_TARGET_CUCKOO "sudo bash -s" < $(pwd)/script/hardening.sh
echo -e "\n=== Hardening de inetsim ==="
ssh -i $SSH_KEY -t $SSH_TARGET_INSETSIM "sudo bash -s" < $(pwd)/script/hardening.sh



echo -e "\n=== Attente des VMs ==="

targets=("$IP_CUCKOO" "$IP_K3S" "$IP_DOWNLOAD" "$IP_INETSIM")
while [ ${#targets[@]} -gt 0 ]; do
    for i in "${!targets[@]}"; do
        target=${targets[$i]}
        if ping -c 1 -W 1 "$target" > /dev/null 2>&1; then
            echo "[OK] $target répond."
            unset 'targets[$i]'
        else
            echo "[..] $target ne répond pas encore."
        fi
    done
    # Réindexer le tableau pour éviter les trous
    targets=("${targets[@]}")
    echo -e "\nAttente de 10 secondes avant le prochain test..."
    sleep 10
done


# Afficher les informations de connexion à argocd
echo -e "\n\n"
ssh $SSH_TARGET_K3S -i ~/.ssh/kvm/id_ed25519 'echo "service ArgoCD : https://$(hostname -I | awk "{print \$1}"):$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.port==443)].nodePort}")"; echo "id : admin"; echo "pwd : $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"'

# Afficher la clé API
echo "API KEY: $API_KEY"

# afficher l'interface graphique du projet sur firefox
if ! command -v firefox >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y firefox
fi
firefox --new-tab "$URL" &

echo "setup terminé."
