#!/bin/bash
set -uo pipefail

#####################
##### Variables #####
#####################

C_USER="${C_USER:-cuckoo}"
C_PASS="${C_PASS:-cuckoo}"
CREATE_VMS="${CREATE_VMS:-y}"
STATIC_ROOT="${STATIC_ROOT:-/opt/cuckoo3/static}"
LATEST_SUPPORTED_PYTHON_VERSION=python3.10
CURRENT_PYTHON_MINOR_VERSION=$(python3 --version | awk '{print $2}' | awk -F '.' '{print $2}')
DEFAULT_ROOT=/opt/cuckoo3/static
RED='\e[31m'
ORANGE='\e[33m'
GREEN='\e[32m'
NC='\e[0m'
INETSIM_IP="192.168.30.200"

#################################
##### Vérifications initiales ###
#################################

# S'assurer que le script est lancé en root pour les tâches système
if [[ $(id -u) -ne 0 ]]; then
    echo -e "\n#################\n### ${RED}Attention${NC} ###\n#################"
    echo "Ce script doit être lancé avec des privilèges sudo."
    echo "Veuillez entrer votre mot de passe pour continuer en tant que root : "
    exec sudo bash "$0" "$@"

    if [[ $? -ne 0 ]]; then     
        echo "Échec de l'obtention des privilèges sudo. Arrêt du script."
        exit 1
    fi
fi

#####################
##### Templates #####
#####################

### Installation de VMCloak ###

install_vmcloak_with() {
    local python_version="$1"
    cat << EOF
if [[ ! -d vmcloak ]]; then
    git clone https://github.com/cert-ee/vmcloak.git
fi
cd vmcloak
git fetch --all
git switch main && git pull
if [[ ! -d venv ]]; then
    echo -e "\n### Initialisation de l'environnement virtuel (venv) ###"
    $python_version -m venv venv
    echo -e "\n### Activation du venv ###"
    source venv/bin/activate
    echo -e "\n### Installation des paquets VMCloak ###"
    $python_version -m pip install .
fi
EOF
}

### Installation de Cuckoo ###

install_cuckoo_with() {
    local python_version="$1"
    cat << EOF
if [[ ! -d cuckoo3 ]]; then
    git clone https://github.com/cert-ee/cuckoo3.git
fi
cd cuckoo3
git switch main && git pull
if [[ ! -d venv ]]; then
    echo -e "\n### Initialisation de l'environnement virtuel (venv) ###"
    $python_version -m venv venv
    echo -e "\n### Activation du venv ###"
    source venv/bin/activate
    echo -e "\n### Installation de wheel et requests ###"
    $python_version -m pip install -U wheel requests
    echo -e "\n### Installation des dépendances ###"
    for repo in sflock roach httpreplay; do
        $python_version -m pip install -U git+https://github.com/cert-ee/\$repo
    done
    $python_version -m pip install daphne
    declare -a pkglist=("./common" "./processing" "./machineries" "./web" "./node" "./core")
    echo -e "\n### Installation des paquets Cuckoo ###"
    for pkg in \${pkglist[@]}; do
        if [[ ! -d "\$pkg" ]]; then
            echo "Paquet manquant : \$pkg"
            exit 1
        fi

        $python_version -m pip install -e "\$pkg"
        if [[ \$? -ne 0 ]]; then
            echo "L'installation de \$pkg a échoué"
            exit 1
        fi
    done
fi
# Création du dossier de travail Cuckoo (CWD)
if [[ ! -d ~/.cuckoocwd ]]; then
    echo -e "\n### Création du dossier CWD de Cuckoo3 ###"
    cuckoo createcwd
fi
EOF
}

### Configuration de Cuckoo ###

configure_cuckoo_for() {
    local username="$1"
    cat << EOF
cd ~/cuckoo3
source venv/bin/activate
echo -e "\n### Importation des binaires du monitor ###"
cuckoo getmonitor monitor.zip &>/dev/null
echo -e "\n### Extraction des signatures ###"
unzip -o -d ~/.cuckoocwd/signatures/cuckoo signatures.zip &>/dev/null
echo -e "\n### Génération de la documentation ###"
cd docs
pip install -r requirements.txt
mkdocs build
cp -R site ../web/cuckoo/web/static/docs
cuckoo web djangocommand collectstatic --noinput
echo -e "\n### Génération de la configuration Nginx ###"
cuckoo web generateconfig --nginx > /home/$username/cuckoo3/cuckoo-web.conf
echo -e "\n### Migration de la base de données ###"
cuckoomigrate database all

echo -e "\\n### Correction du chemin node info dump ###"
NODE_DIR="\$HOME/.cuckoocwd/operational"
mkdir -p "\$NODE_DIR"
touch "\$NODE_DIR/node_info.json"
chmod 644 "\$NODE_DIR/node_info.json"

# Patch cuckoo.yaml avec la config node
if ! grep -q "info_dump_path" ~/.cuckoocwd/conf/cuckoo.yaml; then
    echo -e "\\nnode:\\n  info_dump_path: \$NODE_DIR/node_info.json" >> ~/.cuckoocwd/conf/cuckoo.yaml
    echo "Configuration node ajoutée à cuckoo.yaml"
else
    echo "La configuration node existe déjà"
fi
echo -e "\n### Définition d'INetSim comme passerelle par défaut ###"
sed -i 's/route: none/route: inetsim/' ~/.cuckoocwd/conf/routing.yaml
sed -i 's/inetsim: 192.168.1.1/inetsim: 192.168.30.200/' ~/.cuckoocwd/conf/routing.yaml

EOF
}

### Téléchargement des images ###

download_images_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Téléchargement des images ISO ###"
cd /home/$username/vmcloak
source venv/bin/activate
[ ! -s /home/$username/win10x64.iso ] && vmcloak isodownload --win10x64 --download-to /home/$username/win10x64.iso

EOF
}

### Création des VMs ###

create_vms_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Activation du venv pour VMCloak ###"
cd /home/$username/vmcloak
source venv/bin/activate
echo -e "\n### Création de l'image qcow2 ###"
vmcloak --debug init --win10x64 \
    --hddsize 128 --cpus 2 --ramsize 4096 \
    --network 192.168.30.0/24 \
    --vm qemu \
    --vrde --vrde-port 1 \
    --ip 192.168.30.2 \
    --iso-mount /mnt/win10x64 \
    --cpu-model "Skylake-Client-v3" \
    win10base br0

echo -e "\n### Installation des logiciels, du Hardening et bypass anti-VM ###"
vmcloak --debug install win10base \
    disable_uac \
    disable_defender \
    disable_updates \
    human_activity \
    office \
    adobe_reader \
    wallpaper \
    chrome \
    remove_vm_artifacts \
    rdpwrap

echo "### Vérification de la connectivité vers INetSim ###"
virsh domifaddr win10base 2>/dev/null || true

# Verify INetSim is responding on DNS
if ! nc -zvu 192.168.30.200 53 -w 3; then
    echo "ERREUR: INetSim n'est pas joignable sur 192.168.30.200:53"
    echo "Vérifiez que la VM inetsim est démarrée : virsh list --all"
    exit 1
fi
echo "INetSim est joignable. Lancement des snapshots..."
echo -e "\n### Génération des snapshots ###"
vmcloak --debug snapshot --count 3 win10base win10_ 192.168.30.11
EOF
}

### Configuration des VMs pour Cuckoo ###

configure_vms_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Importation des VMs dans Cuckoo ###"
cd ~/cuckoo3
source venv/bin/activate
cuckoo machine import qemu /home/$username/.vmcloak/vms/qemu
echo -e "\n### Nettoyage des configurations d'exemple ###"
cuckoo machine delete qemu example1
EOF
}

harden_vms_for() {
    local username="$1"
    cat << 'EOF'
echo -e "\n### Hardening des VMs : suppression des artefacts hyperviseur ###"
VM_DIR="$HOME/.vmcloak/vms/qemu"

[ -d "$VM_DIR" ] || { echo "ERREUR : Dossier VMs introuvable : $VM_DIR"; exit 1; }
cd "$VM_DIR"

for vmdir in */; do
    [ -d "$vmdir" ] || continue
    vmname="${vmdir%/}"
    echo -e "\n  -> Hardening de : $vmname"

    # supprimer les contrôleurs USB
    virt-xml "$vmname" --remove-device --controller type=usb 2>/dev/null || true

    # supprimer les partages de fichiers hôte/invité
    virt-xml "$vmname" --remove-device --filesystem 2>/dev/null || true

    # supprimer le clipboard partagé
    for channel in $(virsh dumpxml "$vmname" 2>/dev/null \
        | grep -oP '(?<=target name=")[^"]+' \
        | grep -v 'org.qemu.guest_agent'); do
        virt-xml "$vmname" --remove-device --channel target.name="$channel" 2>/dev/null || true
    done

    # masquer les features CPU hyperviseur
    tmpxml=$(mktemp)
    virsh dumpxml "$vmname" > "$tmpxml"

    python3 - "$tmpxml" << 'PYEOF'
import sys
import xml.etree.ElementTree as ET

ET.register_namespace('', '')
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()

cpu = root.find('cpu')
if cpu is None:
    cpu = ET.SubElement(root, 'cpu')

cpu.set('mode', 'host-passthrough')
cpu.set('check', 'none')
cpu.set('migratable', 'on')

# Masquer l'hyperviseur au niveau CPUID
feat = cpu.find(".//feature[@name='hypervisor']")
if feat is None:
    feat = ET.SubElement(cpu, 'feature')
feat.set('policy', 'disable')
feat.set('name', 'hypervisor')

tree.write(path, encoding='unicode', xml_declaration=False)
print("  CPU hardening OK")
PYEOF

    virsh define "$tmpxml" > /dev/null
    rm -f "$tmpxml"
    echo "  VM $vmname hardenée avec succès."
done

echo -e "\n### Hardening terminé ###"
EOF
}

############################
##### Fonctions d'aide #####
############################

generate_section_header() {
    local name="$1"
    local header="### $name ###"
    local top_bottom=$(printf '%*s' "${#header}" '' | tr ' ' '#')
    echo -e "\n$top_bottom\n$header\n$top_bottom\n"
}

generate_warning() {
    local name="$1"
    local header="### ${RED}$name${NC} ###"
    local adjusted_length=$((${#header} - 11))
    local top_bottom=$(printf '%*s' "${adjusted_length}" '' | tr ' ' '#')
    echo -e "\n$top_bottom\n$header\n$top_bottom\n"
}

create_user() {
    local username="$1"
    local password="$2"

    if id "$username" &>/dev/null; then
        echo "L'utilisateur $username existe déjà."
        mkdir -p /home/$username && chown -R $username:$username /home/$username
    else
        sudo useradd -m -s /bin/bash "$username"
        echo "$username:$password" | chpasswd
        echo "L'utilisateur $username a été créé avec le mot de passe fourni."
    fi
}

run_as_cuckoo() {
    local username="$1"
    local commands="$2"
    su - "$username" -c "$commands"
}

###################################################
#### Confirmations et configuration utilisateur ###
###################################################

generate_section_header "Options utilisateur"

echo -e "${RED}NOTE !${NC} Utilisation des paramètres par défaut : Création de l'utilisateur '$C_USER' avec installation automatisée."

username="$C_USER"
password="$C_PASS"

# Création immédiate de l'utilisateur
create_user "$username" "$password"

generate_section_header "Options VM"
create_cuckoo_vms="$CREATE_VMS"
echo "La création des VMs est réglée sur : $create_cuckoo_vms"

generate_section_header "Options Web"
echo "Le STATIC_ROOT de Cuckoo est : $STATIC_ROOT"
cuckoo_web_static_root="$STATIC_ROOT"

###################################################
##### Installation des dépendances système #####
###################################################

generate_section_header "Installation des dépendances système"

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -yq build-essential \
        software-properties-common \
        git \
        unzip \
        libhyperscan5 libhyperscan-dev \
        libjpeg8-dev zlib1g-dev p7zip-full rar unace-nonfree cabextract \
        yara \
        tcpdump \
        libssl-dev libcapstone-dev \
        genisoimage qemu-system-common qemu-utils qemu-system-x86 \
        uwsgi uwsgi-plugin-python3 \
        nginx \
        iptables-persistent

###################################################
##### Installation de la version Python supportée #####
###################################################

generate_section_header "Installation de la version Python $LATEST_SUPPORTED_PYTHON_VERSION"
    add-apt-repository -y ppa:deadsnakes/ppa
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $LATEST_SUPPORTED_PYTHON_VERSION \
        $LATEST_SUPPORTED_PYTHON_VERSION-dev \
        $LATEST_SUPPORTED_PYTHON_VERSION-venv

##################################
##### Installation de VMCloak #####
##################################

generate_section_header "Installation de VMCloak"
run_as_cuckoo "$username" "$(install_vmcloak_with "$LATEST_SUPPORTED_PYTHON_VERSION")"

###################################
##### Installation de Cuckoo3 #####
###################################

generate_section_header "Installation de Cuckoo3"
run_as_cuckoo "$username" "$(install_cuckoo_with "$LATEST_SUPPORTED_PYTHON_VERSION")"

############################################
##### Configuration de l'utilisateur Cuckoo #####
############################################

generate_section_header "Configuration de l'utilisateur $username"

echo -e "\n### Ajout de l'utilisateur au groupe kvm ###"
sudo adduser $username kvm && sudo chmod 666 /dev/kvm

echo -e "\n### Configuration de tcpdump pour $username ###"
sudo groupadd -f pcap
sudo adduser $username pcap
sudo chgrp pcap /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump

echo -e "\n### Autorisation de Cuckoo dans le profil AppArmor de tcpdump ###"
sudo sed -i 's|audit deny @{HOME}/.\*/\*\* mrwkl,|audit deny @{HOME}/.[^c]\*/\*\* mrwkl,\n  audit deny @{HOME}/.c[^u]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cu[^c]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuc[^k]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuck[^o]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cucko[^o]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuckoo[^c]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuckooc[^w]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuckoocw[^d]\*/\*\* mrwkl,\n  audit deny @{HOME}/.cuckoocwd?\*/\*\* mrwkl,|g' /etc/apparmor.d/usr.bin.tcpdump
sudo apparmor_parser -r /etc/apparmor.d/usr.bin.tcpdump

#############################
##### Setup persistent br0 ##
#############################

echo -e "\n### Creating persistent bridge br0 ###"

NETPLAN_FILE="/etc/netplan/02-br0.yaml"

sudo tee $NETPLAN_FILE > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  bridges:
    br0:
      interfaces: []
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0
EOF

sudo chmod 600 $NETPLAN_FILE
sudo chown root:root $NETPLAN_FILE

sudo netplan apply
echo "Bridge br0 created and persisted via Netplan"

echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-cuckoo-forward.conf
sudo sysctl -p /etc/sysctl.d/99-cuckoo-forward.conf
echo "IP forwarding enabled and persisted"

###########################
##### Création des VMs #####
###########################

if [[ $create_cuckoo_vms == "y" ]]; then
    generate_section_header "Création des VMs via VMCloak"

    echo -e "\n### Récupération des images pour VMCloak ###"
    run_as_cuckoo "$username" "$(download_images_for "$username")"

    generate_section_header "Hardening des VMs (anti-détection hyperviseur)"
    run_as_cuckoo "$username" "$(harden_vms_for "$username")"

    echo -e "\n### Activation de l'interface bridge et montage de l'ISO ###"
    sudo /home/$username/vmcloak/bin/vmcloak-qemubridge br0 192.168.30.1/24 && \
    sudo mkdir -p /etc/qemu/ && echo "allow br0" | sudo tee /etc/qemu/bridge.conf && \
    sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper && \
    sudo mkdir -p /mnt/win10x64 && sudo mount -o loop,ro /home/$username/win10x64.iso /mnt/win10x64

    echo -e "\n### Création des VMs et des snapshots ###"
    run_as_cuckoo "$username" "$(create_vms_for "$username")"
fi

##############################
##### Initialisation Cuckoo3 #####
##############################

generate_section_header "Configuration finale de Cuckoo3"
run_as_cuckoo "$username" "$(configure_vms_for "$username")"

###########################
###### Cuckoo Web UI ######
###########################

generate_section_header "Configuration de l'interface Web Cuckoo3"

echo -e "\n### Configuration réseau du Web ###"
sudo sed -i 's/allowed_subnets: 127.0.0.0\/8,10.0.0.0\/8/allowed_subnets: 127.0.0.0\/8,10.0.0.0\/8,192.168.122.0\/24/g' /home/$username/.cuckoocwd/conf/web/web.yaml
sudo sed -i "s|# STATIC_ROOT = \"\"|STATIC_ROOT = \"$cuckoo_web_static_root\"|g" /home/$username/.cuckoocwd/web/web_local_settings.py

echo -e "\n### Création du dossier des fichiers statiques ###"
sudo mkdir -p $cuckoo_web_static_root
sudo chown -R $username:$username $cuckoo_web_static_root
sudo adduser www-data "$username"
run_as_cuckoo "$username" "$(configure_cuckoo_for "$username")"

# Nettoyage Nginx
sudo rm /etc/nginx/sites-enabled/cuckoo-web.conf 2>/dev/null
sudo rm /etc/nginx/sites-enabled/default 2>/dev/null

echo -e "\n### Création du service Systemd ASGI (Daphne) ###"
sudo cat <<EOF > /etc/systemd/system/cuckoo-web.service
[Unit]
Description=Serveur ASGI Daphne pour Cuckoo Web
After=network.target

[Service]
User=$username
Group=$username
WorkingDirectory=/home/$username/cuckoo3/web/cuckoo/web
ExecStart=/home/$username/cuckoo3/venv/bin/daphne -p 9090 cuckoo.web.web.asgi:application
Environment=CUCKOO_APP=web
Environment=CUCKOO_CWD=/home/$username/.cuckoocwd
Environment=CUCKOO_LOGLEVEL=DEBUG
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n### Démarrage du service Web ###"
sudo systemctl enable cuckoo-web.service && \
sudo systemctl start cuckoo-web.service

echo -e "\n### Configuration du reverse-proxy Nginx ###"
sudo cat <<EOF > /etc/nginx/sites-available/cuckoo-web.conf
upstream cuckoo_web {
    server 127.0.0.1:9090;
}

server {
    listen 80;

    location /static {
        alias $cuckoo_web_static_root;
    }

    location / {
        client_max_body_size 1G;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://cuckoo_web;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/cuckoo-web.conf /etc/nginx/sites-enabled/cuckoo-web.conf
sudo systemctl restart nginx cuckoo-web.service

#####################################
##### Migration API DB Cuckoo3 ######
#####################################

generate_section_header "Migration de la base de données de l'API"
run_as_cuckoo "$username" "cd ~/cuckoo3 && source venv/bin/activate && cuckoo api djangocommand migrate"

#################################
##### Jeton d'API Cuckoo3 ######
#################################

generate_section_header "Génération du jeton d'API Cuckoo3"

API_KEY=$(su - "$username" -c '
cd ~/cuckoo3
source venv/bin/activate

EXISTING=$(cuckoo api token --list 2>/dev/null | grep "sandbox-api" || true)
if [ -z "$EXISTING" ]; then
    cuckoo api token --create sandbox-api >/dev/null 2>&1
fi
cuckoo api token --list 2>/dev/null | awk -F"|" '\''/sandbox-api/ {gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6}'\''
')


echo "$API_KEY" > "$(pwd)/cuckoo_api_key.txt"
chown $username:$username "$(pwd)/cuckoo_api_key.txt"
chmod 600 "$(pwd)/cuckoo_api_key.txt"
echo "API key written to $(pwd)/cuckoo_api_key.txt"


###############################
##### Service API Cuckoo3 #####
###############################

generate_section_header "Configuration du service API"

sudo cat <<EOF > /etc/systemd/system/cuckoo-api.service
[Unit]
Description=API Cuckoo3 (Serveur Django)
After=network.target

[Service]
User=$username
Group=$username
WorkingDirectory=/home/$username/cuckoo3
ExecStart=/home/$username/cuckoo3/venv/bin/cuckoo api --host 0.0.0.0 --port 8080
Environment=CUCKOO_APP=api
Environment=CUCKOO_CWD=/home/$username/.cuckoocwd
Environment=CUCKOO_LOGLEVEL=DEBUG
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cuckoo-api.service
sudo systemctl start cuckoo-api.service

##################################
##### Service Core Cuckoo3 #######
##################################

generate_section_header "Configuration du service Core (Moteur principal)"

sudo cat <<EOF > /etc/systemd/system/cuckoo.service
[Unit]
Description=Moteur principal Cuckoo3
After=network.target

[Service]
User=$username
Group=$username
WorkingDirectory=/home/$username/cuckoo3
ExecStart=/home/$username/cuckoo3/venv/bin/cuckoo
Environment=CUCKOO_APP=core
Environment=CUCKOO_CWD=/home/$username/.cuckoocwd
Environment=CUCKOO_LOGLEVEL=DEBUG
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cuckoo.service
sudo systemctl start cuckoo.service

######################################
##### Création des scripts d'aide #####
######################################

generate_section_header "Création des scripts utilitaires dans $(pwd)"

mkdir -p /home/cuckoo/script
cat <<'EOT' > "/home/cuckoo/script/helper_script.sh"
#!/bin/bash
set -euo pipefail

INETSIM_IP="192.168.30.200"
ANALYSIS_BRIDGE="br0"          # bridge VMCloak dans la Cuckoo VM
ANALYSIS_NET="192.168.30.0/24"

echo "=== [1/4] IP Forwarding ==="
sysctl -w net.ipv4.ip_forward=1

echo "=== [2/4] Remontage bridge VMCloak ==="
/home/cuckoo/vmcloak/bin/vmcloak-qemubridge br0 192.168.30.1/24
mkdir -p /etc/qemu
echo "allow br0" > /etc/qemu/bridge.conf
chmod u+s /usr/lib/qemu/qemu-bridge-helper

echo "=== [3/4] Montage ISO ==="
mkdir -p /mnt/win10x64
mountpoint -q /mnt/win10x64 || mount -o loop,ro /home/cuckoo/win10x64.iso /mnt/win10x64

echo "=== [4/4] Règles iptables ==="
iptables -F FORWARD
iptables -t nat -F

# Autoriser trafic ESTABLISHED
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Autoriser trafic direct vers INetSim
iptables -A FORWARD -i $ANALYSIS_BRIDGE -d $INETSIM_IP -j ACCEPT

# MASQUERADE pour que INetSim puisse répondre correctement
ANALYSIS_NIC=$(ip route | awk '/192.168.30/ {print $3; exit}')
iptables -t nat -A POSTROUTING -o $ANALYSIS_NIC -j MASQUERADE
# Autoriser le retour du trafic depuis INetSim vers les VMs Windows
iptables -A FORWARD -i $ANALYSIS_NIC -o $ANALYSIS_BRIDGE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNAT — Rediriger tout le trafic des VMs Windows vers INetSim
iptables -t nat -A PREROUTING -i $ANALYSIS_BRIDGE -s $ANALYSIS_NET \
  ! -d $INETSIM_IP -p udp --dport 53 -j DNAT --to-destination $INETSIM_IP:53
iptables -t nat -A PREROUTING -i $ANALYSIS_BRIDGE -s $ANALYSIS_NET \
  ! -d $INETSIM_IP -p tcp --dport 53 -j DNAT --to-destination $INETSIM_IP:53
iptables -t nat -A PREROUTING -i $ANALYSIS_BRIDGE -s $ANALYSIS_NET \
  ! -d $INETSIM_IP -p tcp --dport 80 -j DNAT --to-destination $INETSIM_IP:80
iptables -t nat -A PREROUTING -i $ANALYSIS_BRIDGE -s $ANALYSIS_NET \
  ! -d $INETSIM_IP -p tcp --dport 443 -j DNAT --to-destination $INETSIM_IP:443
iptables -t nat -A PREROUTING -i $ANALYSIS_BRIDGE -s $ANALYSIS_NET \
  ! -d $INETSIM_IP -p tcp -m multiport --dports 21,25,110,143,465,587,6667 \
  -j DNAT --to-destination $INETSIM_IP

# Bloquer tout le reste (pas d'internet pour les VMs Windows)
iptables -A FORWARD -i $ANALYSIS_BRIDGE -j REJECT --reject-with icmp-net-prohibited

echo "Configuration réseau Cuckoo terminée."
EOT
chmod +x /home/cuckoo/script/helper_script.sh

: <<'COMMENT'
# Apply network isolation on the Cuckoo VM
echo "Applying network isolation..."

# Reset
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD

# Default policy
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH only from management network
iptables -A INPUT -p tcp -s 192.168.122.0/24 --dport 22 -j ACCEPT

# Allow libvirt network (virbr0)
iptables -A INPUT -s 192.168.123.0/24 -j ACCEPT
iptables -A OUTPUT -d 192.168.123.0/24 -j ACCEPT

# Allow Cuckoo network
iptables -A INPUT -s 192.168.30.0/24 -j ACCEPT
iptables -A OUTPUT -d 192.168.30.0/24 -j ACCEPT

# Block malware VMs from accessing external networks
iptables -A FORWARD -s 192.168.30.0/24 -j DROP

iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

# Persist rules
sudo netfilter-persistent save

echo "Network isolation applied"

COMMENT