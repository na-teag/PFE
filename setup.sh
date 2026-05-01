#!/bin/bash
set -euo pipefail

K3S_NAME="k3s"
INETSIM_NAME="inetsim"
DOWNLOAD_NAME="download"
CUCKOO_NAME="cuckoo"
NAMESPACE="malware-analysis"

VM_K3S="$K3S_NAME.qcow2"
VM_INETSIM="$INETSIM_NAME.qcow2"
VM_DOWNLOAD="$DOWNLOAD_NAME.qcow2"
VM_CUCKOO="$CUCKOO_NAME.qcow2"

IP_K3S="192.168.122.2"
IP_NAT_K3S="192.168.123.2"
IP_INETSIM="192.168.40.200"
IP_DOWNLOAD="192.168.122.15"
IP_NAT_DOWNLOAD="192.168.123.3"
IP_CUCKOO="192.168.122.3"
IP_GATEWAY="192.168.122.1"

SSH_KEY="$HOME/.ssh/kvm/id_ed25519"
SSH_KEY_CUCKOO="$HOME/.ssh/kvm/id_ed25519_cuckoo"

SSH_TARGET_K3S="$K3S_NAME@${IP_K3S}"
SSH_TARGET_CUCKOO="$CUCKOO_NAME@$IP_CUCKOO"
SSH_TARGET_DOWNLOAD="$DOWNLOAD_NAME@$IP_DOWNLOAD"
SSH_TARGET_INETSIM="$INETSIM_NAME@$IP_INETSIM"

CERT_DIR="./certs"
URL="https://$IP_K3S/"
IMAGE_VERSION="jammy"
IMAGE_NAME="$IMAGE_VERSION-server-cloudimg-amd64.img"
POOL_NAME="default"
POOL_PATH="/var/lib/libvirt/images"
IMAGE_PATH="$POOL_PATH/$IMAGE_NAME"

NETWORK_HOST_ONLY="default"
XML_PATH=".$NETWORK_HOST_ONLY-network.xml"

# Ajouter les droits d'éxecution pour tout les scripts
sudo chmod +x infra/cuckoo3/install.sh
sudo chmod +x script/*

sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  virt-manager \
  virt-manager \
  openssh-client \
  netcat
sudo systemctl enable --now libvirtd

if ! groups | grep -q "libvirt"; then
  sudo usermod -aG libvirt $USER
  newgrp libvirt # actualiser
fi

# Vérifier qu'il y a suffisamment de place
./script/check_storage.sh $VM_K3S $VM_DOWNLOAD $VM_INETSIM $VM_CUCKOO $IMAGE_NAME $POOL_PATH

# Temps d'installation (hors téléchargement) : 4-5mn
if [ ! -f "$IMAGE_PATH" ]; then
    echo -e "\n##########################################\n### Téléchargement de l'image de la VM ###\n##########################################"
    curl -o $IMAGE_NAME https://cloud-images.ubuntu.com/$IMAGE_VERSION/current/$IMAGE_NAME
    sudo mv $IMAGE_NAME $POOL_PATH
fi

# Mise en place des réseaux
./script/setup-networks.sh $IP_CUCKOO $IP_NAT_K3S $IP_NAT_DOWNLOAD $NETWORK_HOST_ONLY $XML_PATH

# Installation de la vm k3s et download
./script/install-vm-k3s.sh $VM_K3S $POOL_PATH $IMAGE_PATH $IP_K3S # Temps d'installation (hors téléchargement) : 4-5mn
./script/install-vm-download.sh $IP_DOWNLOAD $IP_GATEWAY $IMAGE_PATH $POOL_PATH $IP_K3S # Temps d'installation (hors téléchargement) : 3-4 mn

# Installation et mise en route de Cuckoo3 et service WEB/API + INetSim
./script/install-vm-inetsim.sh $IMAGE_NAME $POOL_PATH $IP_INETSIM
./script/install-vm-cuckoo.sh $VM_CUCKOO $POOL_NAME $IP_CUCKOO $IMAGE_PATH $POOL_PATH


# attendre que les services k3s soient dispo
echo -e "\n\n"
echo "Merci de patienter jusqu'au démarrage complet des services sur la VM $K3S_NAME..."
echo -e "\nAttente de la VM"
while ! nc -z "$IP_K3S" 22 >/dev/null 2>&1; do
  sleep 2
  echo -n "."
done
echo
ssh-keyscan -H $IP_K3S >> "$HOME/.ssh/known_hosts"

while true; do
    STATUS=$(ssh -i ~/.ssh/kvm/id_ed25519 k3s@192.168.122.2 "cloud-init status | cut -d\" \" -f2")
    if [[ "$STATUS" == "done" ]]; then
        echo "Cloud-init terminé"
        break
    else
        echo "Cloud-init non terminé ($STATUS), attente..."
        sleep 10
    fi
done
while true; do
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    PODS=$(ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | grep -c Running 2>/dev/null || true")
    PODS=${PODS:-0}
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
echo -e "\n=== Configuration des Secrets et Application ArgoCD ==="

# Récupération des clés nécessaires
echo -e "\n"
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo
if [ -z "$VT_KEY" ]; then echo "Erreur: La clé VT est vide."; exit 1; fi

CUCKOO_API_KEY="$(cat "$(pwd)/cuckoo_api_key.txt")"
API_KEY=$(openssl rand -base64 32)
# log de la clé avant la fin du script, pour éviter de devoir tout recommencer en cas d'erreur
echo "API_KEY=$API_KEY"


# Créer le secret vt-credentials
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vt-credentials
  namespace: '$NAMESPACE'
stringData:
  VIRUSTOTAL_API_KEY: '$VT_KEY'
  CUCKOO_API_KEY: '$CUCKOO_API_KEY'
  API_KEY: '$API_KEY'
type: Opaque
EOF"


# Nettoyage des pods pour forcer le redémarrage avec les nouveaux secrets
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl delete pod -n "$NAMESPACE" -l app=worker-static"
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "kubectl delete pod -n "$NAMESPACE" -l app=sandbox-controller"


########################################
# Création du certificat TLS si nécessaire
########################################
mkdir -p "$CERT_DIR"
echo -e "\n=== Génération du certificat TLS ==="
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
echo -r "\n=== Déploiement du Secret TLS ==="
scp -i "$SSH_KEY" "${CERT_DIR}/tls.crt" "${CERT_DIR}/tls.key" "${SSH_TARGET_K3S}:/tmp/"
ssh -i "$SSH_KEY" "$SSH_TARGET_K3S" "
  kubectl create secret tls api-tls \
    --cert=/tmp/tls.crt \
    --key=/tmp/tls.key \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f - && \
  rm -f /tmp/tls.crt /tmp/tls.key
"


echo -r "\n=== Configuration de Traefik sur le port 443 ==="
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

wait_for_VMs() {
	targets=("$IP_CUCKOO" "$IP_K3S" "$IP_DOWNLOAD" "$IP_INETSIM")
    while [ ${#targets[@]} -gt 0 ]; do
        for i in "${!targets[@]}"; do
            target=${targets[$i]}
            if nc -z "$target" 22 >/dev/null 2>&1 ; then
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
}
echo -e "\n=== Attente des VMs ==="
wait_for_VMs

# Faire confiance au certificat localement
sudo cp "${CERT_DIR}/tls.crt" /usr/local/share/ca-certificates/malware-analysis.crt
sudo update-ca-certificates



# appliquer les règles d'isolation des réseaux sur les VMs nécessitant internet
echo -e "\n=== Isoler les réseaux sur les VMs $K3S_NAME et $DOWNLOAD_NAME ==="
TMP_FILE=$(mktemp)
cat > $TMP_FILE << 'EOF'
set -euo pipefail

sudo iptables -C FORWARD -i eth0 -o eth1 -j DROP 2>/dev/null || \
sudo iptables -A FORWARD -i eth0 -o eth1 -j DROP

sudo iptables -C FORWARD -i eth1 -o eth0 -j DROP 2>/dev/null || \
sudo iptables -A FORWARD -i eth1 -o eth0 -j DROP

sudo ip6tables -C FORWARD -i eth0 -o eth1 -j DROP 2>/dev/null || \
sudo ip6tables -A FORWARD -i eth0 -o eth1 -j DROP

sudo ip6tables -C FORWARD -i eth1 -o eth0 -j DROP 2>/dev/null || \
sudo ip6tables -A FORWARD -i eth1 -o eth0 -j DROP

sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 >/dev/null
EOF

scp -i "$SSH_KEY" "$TMP_FILE" "${SSH_TARGET_K3S}:~/iptables.sh"
ssh -i "$SSH_KEY" -tt "$SSH_TARGET_K3S" 'chmod +x ~/iptables.sh && ~/iptables.sh'
rm -f $TMP_FILE
ssh -i "$SSH_KEY" -tt "$SSH_TARGET_DOWNLOAD" 'sudo nft -f /etc/nftables.conf && sudo nft add rule inet filter forward iif eth0 oif eth1 drop && sudo nft add rule inet filter forward iif eth1 oif eth0 drop'

ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_INETSIM 2>/dev/null || true
ssh-keyscan -H $IP_INETSIM >> "$HOME/.ssh/known_hosts"

echo -e "\n=== Hardening des VMs ===\n"
echo -e "\n=== Hardening de k3s ==="
scp -i $SSH_KEY "$(pwd)/script/hardening.sh" $SSH_TARGET_K3S:~/hardening.sh
ssh -i $SSH_KEY -tt $SSH_TARGET_K3S "chmod +x hardening.sh && sudo ./hardening.sh"
virsh shutdown $K3S_NAME
echo -e "\n=== Hardening de download ==="
scp -i $SSH_KEY "$(pwd)/script/hardening.sh" $SSH_TARGET_DOWNLOAD:~/hardening.sh
ssh -i $SSH_KEY -tt $SSH_TARGET_DOWNLOAD "chmod +x hardening.sh && sudo ./hardening.sh"
virsh shutdown $DOWNLOAD_NAME
echo -e "\n=== Hardening de cuckoo ==="
scp -i $SSH_KEY_CUCKOO "$(pwd)/script/hardening.sh" $SSH_TARGET_CUCKOO:~/hardening.sh
ssh -i $SSH_KEY_CUCKOO -tt $SSH_TARGET_CUCKOO "chmod +x hardening.sh && sudo ./hardening.sh"
virsh shutdown $CUCKOO_NAME
echo -e "\n=== Hardening de inetsim ==="
scp -i $SSH_KEY "$(pwd)/script/hardening.sh" $SSH_TARGET_INETSIM:~/hardening.sh
ssh -i $SSH_KEY -tt $SSH_TARGET_INETSIM "chmod +x hardening.sh && sudo ./hardening.sh"
virsh shutdown $INETSIM_NAME

VMS=("$K3S_NAME" "$DOWNLOAD_NAME" "$CUCKOO_NAME" "$INETSIM_NAME")
echo "Attente de l'extinction des VMs..."
while true; do
    ALL_OFF=true
    for VM in "${VMS[@]}"; do
        STATE=$(virsh domstate "$VM" 2>/dev/null)
        if [[ "$STATE" != "shut off" ]]; then
            ALL_OFF=false
            break
        fi
    done
    if $ALL_OFF; then
        break
    fi
    sleep 2
    echo -n "."
done



# passage en host-only
echo -e "\n\n\n=== Passage du réseau $NETWORK_HOST_ONLY en host-only ==="
virsh net-destroy $NETWORK_HOST_ONLY
virsh net-undefine $NETWORK_HOST_ONLY

sudo systemctl restart libvirtd
cat > $XML_PATH <<EOF
<network>
  <name>$NETWORK_HOST_ONLY</name>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:58:e6:ee'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.10' end='192.168.122.254'/>
      <host mac='52:54:00:00:00:03' name='cuckoo' ip='$IP_CUCKOO'/>
    </dhcp>
  </ip>
</network>
EOF
virsh net-define $XML_PATH
virsh net-start $NETWORK_HOST_ONLY
virsh net-autostart $NETWORK_HOST_ONLY

# redémarrage des VMs
echo -e "\n=== Redémarrage des VMs ==="
virsh start $K3S_NAME
virsh start $CUCKOO_NAME
virsh start $DOWNLOAD_NAME
virsh start $INETSIM_NAME

echo -e "\n=== Attente des VMs ==="
wait_for_VMs


# enregistrer les VMs en tant que known_host après le `dpkg-reconfigure openssh-server` du script de hardening
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_K3S 2>/dev/null || true
ssh-keyscan -H $IP_K3S >> "$HOME/.ssh/known_hosts"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_CUCKOO 2>/dev/null || true
ssh-keyscan -H $IP_CUCKOO >> "$HOME/.ssh/known_hosts"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_INETSIM 2>/dev/null || true
ssh-keyscan -H $IP_INETSIM >> "$HOME/.ssh/known_hosts"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $IP_DOWNLOAD 2>/dev/null || true
ssh-keyscan -H $IP_DOWNLOAD >> "$HOME/.ssh/known_hosts"



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
