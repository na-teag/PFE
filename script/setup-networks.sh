XML_PATH=".default-network.xml"
XML_NAT_PATH=".default-nat-network.xml"

# vérifier que le réseau default existe bien, le créer si non
if ! virsh net-info default &>/dev/null; then
  echo -e "\n########################################\n### Installation du réseau 'default' ###\n########################################"
  cat > "$XML_PATH" <<'EOF'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:58:e6:ee'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.10' end='192.168.122.254'/>
      <host mac='52:54:00:00:00:03' name='cuckoo' ip='192.168.122.3'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_PATH"
fi
# démarrer le réseau default
virsh net-start default &>/dev/null || true
virsh net-autostart default

# Vérifier que virbr0 existe
if ! ip -d link show virbr0 2>/dev/null | grep -q "bridge"; then
  echo -e "\n\nerreur: le bridge virbr0 n'existe pas" 1>&2
  exit 1
fi









# Détruire et recréer proprement à chaque fois pour éviter les états incohérents
sudo virsh net-destroy analysis 2>/dev/null || true
sudo virsh net-undefine analysis 2>/dev/null || true

cat <<NETEOF > /tmp/analysis-net.xml
<network>
  <name>analysis</name>
  <bridge name="virbr1" stp="on" delay="0"/>
  <ip address="192.168.40.1" netmask="255.255.255.0"/>
</network>
NETEOF

sudo virsh net-define /tmp/analysis-net.xml
sudo virsh net-start analysis
sudo virsh net-autostart analysis

# Vérification que virbr1 est bien monté
if ! ip link show virbr1 &>/dev/null; then
    echo "ERREUR: virbr1 n'est pas monté après création du réseau analysis"
    exit 1
fi







# vérifier que le réseau default-nat existe bien, le créer si non
if ! virsh net-info default-nat &>/dev/null; then
  echo -e "\n########################################\n### Installation du réseau 'default-nat' ###\n########################################"
  cat > "$XML_NAT_PATH" <<'EOF'
<network>
  <name>default-nat</name>
  <forward mode='nat'/>
  <bridge name='virbr2' stp='on' delay='0'/>
  <mac address='52:54:00:58:f7:ff'/>
  <ip address='192.168.123.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.123.10' end='192.168.123.254'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-define "$XML_NAT_PATH"
fi
# démarrer le réseau
virsh net-start default-nat &>/dev/null || true
virsh net-autostart default-nat

# Vérifier que virbr2 existe
if ! ip -d link show virbr2 2>/dev/null | grep -q "bridge"; then
  echo -e "\n\nerreur: le bridge virbr2 n'existe pas" 1>&2
  exit 1
fi