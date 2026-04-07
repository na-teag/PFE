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

#########################
##### Flight checks #####
#########################

# Ensure the script is run as root for system-related tasks
if [[ $(id -u) -ne 0 ]]; then
        echo -e "\n#################\n### ${RED}Attention${NC} ###\n#################"
    echo "This script must be run with sudo privileges to manage system-related tasks."
    echo "Please enter your password to run as sudo: "
    exec sudo bash "$0" "$@"

    if [[ $? -ne 0 ]]; then
	    echo "Failed to obtain sudo privileges. Exiting"
	    exit 1
    fi
fi

#####################
##### Templates #####
#####################

### Install VMCloak ###

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
    echo -e "\n### Initiating new virtualenv ###"
    $python_version -m venv venv
    echo -e "\n### Activating new virtualenv ###"
    source venv/bin/activate
    echo -e "\n### Installing VMCloak packages ###"
    $python_version -m pip install .
fi
EOF
}

### Install Cuckoo ###

install_cuckoo_with() {
    local python_version="$1"
    cat << EOF
if [[ ! -d cuckoo3 ]]; then
    git clone https://github.com/cert-ee/cuckoo3.git
fi
cd cuckoo3
git switch main && git pull
if [[ ! -d venv ]]; then
    echo -e "\n### Initiating new virtualenv ###"
    $python_version -m venv venv
    echo -e "\n### Activating virtualenv ###"
    source venv/bin/activate
    echo -e "\n### Installing wheel and requests ###"
    $python_version -m pip install -U wheel requests
    echo -e "\n### Installing dependencies ###"
    for repo in sflock roach httpreplay; do
        $python_version -m pip install -U git+https://github.com/cert-ee/\$repo
    done
    $python_version -m pip install daphne
    declare -a pkglist=("./common" "./processing" "./machineries" "./web" "./node" "./core")
    echo -e "\n### Installing Cuckoo packages ###"
    for pkg in \${pkglist[@]}; do
        if [[ ! -d "\$pkg" ]]; then
            echo "Missing package: \$pkg"
            exit 1
        fi

        $python_version -m pip install -e "\$pkg"
        if [[ \$? -ne 0 ]]; then
            echo "Install of \$pkg failed"
            exit 1
        fi
    done
fi
# Create Cuckoo3 cwd folder
if [[ ! -d ~/.cuckoocwd ]]; then
    echo -e "\n### Creating Cuckoo3 cwd folder ###"
    cuckoo createcwd
fi
EOF
}

### Configure Cuckoo ###

configure_cuckoo_for() {
    local username="$1"
    cat << EOF
cd ~/cuckoo3
source venv/bin/activate
# Import monitor binaries and extract signatures
echo -e "\n### Importing monitor binaries ###"
cuckoo getmonitor monitor.zip &>/dev/null
echo -e "\n### Extracting signatures ###"
unzip -o -d ~/.cuckoocwd/signatures/cuckoo signatures.zip &>/dev/null
echo -e "\n### Building documentation ###"
cd docs
pip install -r requirements.txt
mkdocs build
cp -R site ../web/cuckoo/web/static/docs
cuckoo web djangocommand collectstatic --noinput
echo -e "\n### Generating Nginx configuration ###"
cuckoo web generateconfig --nginx > /home/$username/cuckoo3/cuckoo-web.conf
echo -e "\n### Migrating databases ###"
cuckoomigrate database all

# ===== FIX: Node info dump path =====
echo -e "\\n### Fixing node info dump path ###"
NODE_DIR="~/.cuckoocwd/operational"
mkdir -p "\$NODE_DIR"
touch "\$NODE_DIR/node_info.json"
chmod 666 "\$NODE_DIR/node_info.json"

# Patch cuckoo.yaml with node config
if ! grep -q "info_dump_path" ~/.cuckoocwd/conf/cuckoo.yaml; then
    echo -e "\\nnode:\\n  info_dump_path: \$NODE_DIR/node_info.json" >> ~/.cuckoocwd/conf/cuckoo.yaml
    echo "Added node config to cuckoo.yaml"
else
    echo "Node config already exists"
fi
EOF
}

### Download images ###

download_images_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Downloading images ###"
cd /home/$username/vmcloak
source venv/bin/activate
[ ! -s /home/$username/win10x64.iso ] && vmcloak isodownload --win10x64 --download-to /home/$username/win10x64.iso

EOF
}

### Create VMs ###

create_vms_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Activating Python venv for VMCloak ###"
cd /home/$username/vmcloak
source venv/bin/activate
echo -e "\n### Creating qcow2 image ###"
vmcloak --debug init --win10x64 --hddsize 128 --cpus 2 --ramsize 4096 --network 192.168.30.0/24 --vm qemu --vrde --vrde-port 1 --ip 192.168.30.2 --iso-mount /mnt/win10x64 win10base br0
echo -e "\n### Installing software on VM ###"
vmcloak --debug install win10base --recommended
echo -e "\n### Generating snapshots ###"
vmcloak --debug snapshot --count 3 win10base win10_ 192.168.30.10
EOF
}

### Configure VMs for Cuckoo ###

configure_vms_for() {
    local username="$1"
    cat << EOF
echo -e "\n### Importing VMs to Cuckoo ###"
cd ~/cuckoo3
source venv/bin/activate
cuckoo machine import qemu /home/$username/.vmcloak/vms/qemu
echo -e "\n### Deleting example configurations ###"
cuckoo machine delete qemu example1
EOF
}

### Run as Cuckoo user ###

run_cuckoo_for() {
    local username="$1"
    cat << EOF
cd /home/$username/cuckoo3
source venv/bin/activate
cuckoo
EOF
}

############################
##### Helper functions #####
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
        echo "User $username already exists."
        mkdir -p /home/$username && chown -R $username:$username /home/$username
    else
        sudo useradd -m -s /bin/bash "$username"
        echo "$username:$password" | chpasswd
        echo "User $username has been created with the specified password."
    fi
}

run_as_cuckoo() {
    local username="$1"
    local commands="$2"
    su - "$username" -c "$commands"
}

########################################
##### Confirmations and user setup #####
########################################

generate_section_header "User options"

echo -e "${RED}NOTE!${NC} Using default settings: Creating user '$C_USER' with automated setup."

# Use environment variables or defaults
create_cuckoo_user="y"
username="$C_USER"
password="$C_PASS"

# Create the user immediately
create_user "$username" "$password"

generate_section_header "VM options"
create_cuckoo_vms="$CREATE_VMS"
echo "VM creation is set to: $create_cuckoo_vms"

generate_section_header "Web options"
echo "Cuckoo static root is set to: $STATIC_ROOT"
cuckoo_web_static_root="$STATIC_ROOT"

#######################################
##### Install system dependencies #####
#######################################

generate_section_header "Installing system dependencies"

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
        nginx

###########################################
##### Install latest supported Python #####
###########################################

generate_section_header "Installing latest supported Python version"
    add-apt-repository -y ppa:deadsnakes/ppa
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $LATEST_SUPPORTED_PYTHON_VERSION \
        $LATEST_SUPPORTED_PYTHON_VERSION-dev \
        $LATEST_SUPPORTED_PYTHON_VERSION-venv

##############################
##### Installing VMCloak #####
##############################

generate_section_header "Installing VMCloak"
run_as_cuckoo "$username" "$(install_vmcloak_with "$LATEST_SUPPORTED_PYTHON_VERSION")"

##############################
##### Installing Cuckoo3 #####
##############################

generate_section_header "Installing Cuckoo3"
run_as_cuckoo "$username" "$(install_cuckoo_with "$LATEST_SUPPORTED_PYTHON_VERSION")"

#####################################
##### Cuckoo user configuration #####
#####################################

generate_section_header "Configuring user $username"

echo -e "\n### Adding cuckoo user to kvm group ###"
sudo adduser $username kvm && sudo chmod 666 /dev/kvm

echo -e "\n### Configuring tcpdump for $username ###"
sudo groupadd pcap
sudo adduser $username pcap
sudo chgrp pcap /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump

echo -e "\n### Adding Cuckoo permission to tcpdump profile in apparmor ###"
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
      addresses: [192.168.30.1/24]
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0
EOF

sudo chmod 600 $NETPLAN_FILE
sudo chown root:root $NETPLAN_FILE

sudo netplan apply
echo "Bridge br0 created and persisted via Netplan"

######################
##### Create VMs #####
######################

if [[ $create_cuckoo_vms == "y" ]]; then
    generate_section_header "Creating VMs with VMCloak"
    # ------------------------------
    # ----- Downloading images -----
    # ------------------------------

    echo -e "\n### Downloading images for VMCloak ###"

    run_as_cuckoo "$username" "$(download_images_for "$username")"

    # ---------------------------------
    # ----- VMCloak configuration -----
    # ---------------------------------

    echo -e "\n### Enabling interface and mounting image ###"

    sudo /home/$username/vmcloak/bin/vmcloak-qemubridge br0 192.168.30.1/24 && \
    sudo mkdir -p /etc/qemu/ && echo "allow br0" | sudo tee /etc/qemu/bridge.conf && \
    sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper && \
    sudo mkdir -p /mnt/win10x64 && sudo mount -o loop,ro /home/$username/win10x64.iso /mnt/win10x64

    # ------------------------
    # ----- Creating VMs -----
    # ------------------------

    echo -e "\n### Creating VM-s and snapshots ###"

    run_as_cuckoo "$username" "$(create_vms_for "$username")"
fi

#########################
##### Cuckoo3 setup #####
#########################

generate_section_header "Configuring Cuckoo3"

run_as_cuckoo "$username" "$(configure_vms_for "$username")"

#######################
###### Cuckoo Web #####
#######################

generate_section_header "Setting up Cuckoo3 Web"


echo -e "\n### Configuring Web ###"
sudo sed -i 's/allowed_subnets: 127.0.0.0\/8,10.0.0.0\/8/allowed_subnets: 127.0.0.0\/8,10.0.0.0\/8,192.168.68.0\/24/g' /home/$username/.cuckoocwd/conf/web/web.yaml
sudo sed -i "s|# STATIC_ROOT = \"\"|STATIC_ROOT = \"$cuckoo_web_static_root\"|g" /home/$username/.cuckoocwd/web/web_local_settings.py

echo -e "\n### Creating static root ###"
sudo mkdir -p $cuckoo_web_static_root
sudo chown -R $username:$username $cuckoo_web_static_root
sudo adduser www-data "$username"
run_as_cuckoo "$username" "$(configure_cuckoo_for "$username")"
sudo mkdir -p "/home/$username/.cuckoocwd/operational"
sudo touch "/home/$username/.cuckoocwd/operational/node_info.json"
sudo chown $username:$username "/home/$username/.cuckoocwd/operational/node_info.json"

sudo rm /etc/nginx/sites-enabled/cuckoo-web.conf 2&>/dev/null
sudo rm /etc/nginx/sites-enabled/default 2&>/dev/null

echo -e "\n### Creating ASGI service###"

sudo cat <<EOF > /etc/systemd/system/cuckoo-web.service
[Unit]
Description=Daphne ASGI Server
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

echo -e "\n### Enabling and starting ASGI service ###"
sudo systemctl enable cuckoo-web.service && \
sudo systemctl start cuckoo-web.service

echo -e "\n### Creating Nginx configuration ###"

sudo cat <<EOF > /etc/nginx/sites-available/cuckoo-web.conf
# This is a basic NGINX configuration generated by Cuckoo. It is
# recommended to review it and change it where needed. This configuration
# is meant to be used together with the generated uWSGI configuration.
upstream cuckoo_web {
    server 127.0.0.1:9090;
}

server {
    listen 80;

    # Directly serve the static files for Cuckoo web. Copy
    # (and update these after Cuckoo updates) these by running:
    # 'cuckoo web djangocommand collectstatic'. The path after alias should
    # be the same path as STATIC_ROOT. These files can be cached. Be sure
    # to clear the cache after any updates.
    location /static {
        alias $cuckoo_web_static_root;
    }

    # Pass any non-static requests to the Cuckoo web wsgi application run
    # by uwsgi. It is not recommended to cache paths here, this can cause
    # the UI to no longer reflect the correct state of analyses and tasks.
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

echo -e "\n### Restarting Nginx ###"

sudo systemctl restart nginx cuckoo-web.service

###############################
##### Cuckoo3 Web API DB ######
###############################

generate_section_header "Migrating Cuckoo3 web API database"

su - "$username" -c '
cd ~/cuckoo3
source venv/bin/activate
cuckoo api djangocommand migrate
'
##############################
##### Cuckoo3 API token ######
##############################

generate_section_header "Creating Cuckoo3 API token"

API_KEY=$(su - "$username" -c '
cd ~/cuckoo3
source venv/bin/activate

EXISTING=$(cuckoo api token --list 2>/dev/null | grep "sandbox-api" || true)
if [ -z "$EXISTING" ]; then
    cuckoo api token --create sandbox-api >/dev/null 2>&1
fi

cuckoo api token --list 2>/dev/null | awk -F"|" '\''/sandbox-api/ {gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6}'\''
')

echo "Cuckoo API key: $API_KEY"

echo "$API_KEY" > "$(pwd)/cuckoo_api_key.txt"
echo "API key written to $(pwd)/cuckoo_api_key.txt"

############################
##### Cuckoo3 API svc #####
############################

generate_section_header "Setting up Cuckoo3 API service"

echo -e "\n### Creating Cuckoo API service ###"

sudo cat <<EOF > /etc/systemd/system/cuckoo-api.service
[Unit]
Description=Cuckoo3 API (Django dev server)
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

echo -e "\n### Enabling and starting Cuckoo API service ###"
sudo systemctl daemon-reload
sudo systemctl enable cuckoo-api.service
sudo systemctl start cuckoo-api.service

###############################
##### Cuckoo3 core daemon #####
###############################

generate_section_header "Setting up Cuckoo3 core service"

echo -e "\n### Creating Cuckoo core service ###"

sudo cat <<EOF > /etc/systemd/system/cuckoo.service
[Unit]
Description=Cuckoo3 main engine
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

echo -e "\n### Enabling and starting Cuckoo core service ###"
sudo systemctl daemon-reload
sudo systemctl enable cuckoo.service
sudo systemctl start cuckoo.service



#################################
##### Create helper scripts #####
#################################

generate_section_header "Creating helper scripts under $(pwd)"

mkdir -p /home/cuckoo/script
touch "$(pwd)/script/helper_script.sh" && chmod u+x "$(pwd)/script/helper_script.sh"
cat <<EOT > "$(pwd)/script/helper_script.sh"
echo -e "\n### Bringing up network bridge ###"
sudo /home/$username/vmcloak/bin/vmcloak-qemubridge br0 192.168.30.1/24
echo -e "\n### Mounting ISO ###"
sudo mount -o loop,ro /home/$username/win10x64.iso /mnt/win10x64
EOT



######################
##### Run Cuckoo #####
######################

#generate_section_header "Running cuckoo in debug mode"
#run_as_cuckoo "$username" "$(run_cuckoo_for "$username")"

# End of script

# Apply network isolation on the Cuckoo VM
echo "Applying network isolation..."

# Reset
iptables -F
iptables -X

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
