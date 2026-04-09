#!/bin/bash

set -e

# Vérifier root
if [ "$EUID" -ne 0 ]; then
  echo "Ce script doit être exécuté en root."
  exit 1
fi

# TODO nécessite une interaction, à remplacer par un hash fixé ?
echo "Génération du hash GRUB (entre ton mot de passe):"
HASH=$(grub-mkpasswd-pbkdf2 | sed -n 's/^.*grub.pbkdf2/grub.pbkdf2/p')

if [ -z "$HASH" ]; then
  echo "Erreur: impossible de récupérer le hash."
  exit 1
fi

echo -e "Hash généré.\n"

# Sauvegardes
cp /etc/grub.d/40_custom /etc/grub.d/40_custom.bak
cp /etc/grub.d/10_linux /etc/grub.d/10_linux.bak

echo -e "Sauvegardes créées.\n"

# Modifier /etc/grub.d/40_custom
cat <<EOF >> /etc/grub.d/40_custom

set superusers="root"
password_pbkdf2 root $HASH
EOF

echo -e "/etc/grub.d/40_custom modifié.\n"

# Modifier /etc/grub.d/10_linux
sed -i 's|CLASS="--class gnu-linux --class gnu --class os"|CLASS="--class gnu-linux --class gnu --class os --unrestricted"|' /etc/grub.d/10_linux

echo -e "/etc/grub.d/10_linux modifié.\n"




# Options à ajouter dans GRUB_CMDLINE_LINUX_DEFAULT dans /etc/default/grub
OPTS=(
  "iommu=force"
  "l1tf=full,force"
  "page_poison=on"
  "pti=on"
  "slab_nomerge=yes"
  "slub_debug=FZP"
  "spec_store_bypass_disable=seccomp"
  "spectre_v2=on"
  "mds=full,nosmt"
  "mce=0"
  "page_alloc.shuffle=1"
  "rng_core.default_quality=500"
  "security=yama"
  "ipv6.disable=1"
)
FILE="/etc/default/grub"
# Backup
cp "$FILE" "${FILE}.bak"
CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$FILE" | cut -d'"' -f2)
# ajouter les nouveaux et enlever les doublons
for opt in "${OPTS[@]}"; do
  if ! echo "$CURRENT" | grep -qw "$opt"; then
    CURRENT="$CURRENT $opt"
  fi
done
# enlever espaces
CURRENT=$(echo "$CURRENT" | xargs)
# remplacer
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$FILE"; then
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT\"|" "$FILE"
else
  # ajouter
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT\"" >> "$FILE"
fi





cat > "/etc/sysctl.d/99-PFE-kernel-hardening.conf" <<'EOF'
# Restreint l'accès au buffer dmesg (équivalent à
# CONFIG_SECURITY_DMESG_RESTRICT=y)
kernel.dmesg_restrict =1
# Cache les adresses noyau dans /proc et les différentes autres interfaces ,
# y compris aux utilisateurs privilégiés
kernel.kptr_restrict =2
# Spécifie explicitement l'espace d'identifiants de processus supporté par le
# noyau , 65 536 étant une valeur donnée à titre d'exemple
kernel.pid_max =65536
# Restreint l'utilisation du sous -système perf
kernel.perf_cpu_time_max_percent =1
kernel.perf_event_max_sample_rate =1
# Interdit l'accès non privilégié à l'appel système perf_event_open (). Avec une
# valeur plus grande que 2, on impose la possession de CAP_SYS_ADMIN , pour pouvoir
# recueillir les évènements perf.
kernel.perf_event_paranoid =2
# Active l'ASLR
kernel.randomize_va_space =2
# Désactive les combinaisons de touches magiques (Magic System Request Key)
kernel.sysrq =0
# Restreint l'usage du BPF noyau aux utilisateurs privilégiés
kernel.unprivileged_bpf_disabled =1
# Arrête complètement le système en cas de comportement inattendu du noyau Linux
kernel.panic_on_oops =1
# Interdit le chargement des modules noyau (sauf ceux déjà chargés à ce point)
kernel.modules_disabled =1

kernel.yama.ptrace_scope = 2

# NOTES : les modules à charger aux démarrage sont à mettre dans /etc/modules-load.d/modules.conf
EOF



cat > "/etc/sysctl.d/99-PFE-network-security.conf" <<'EOF'
# Atténuation de l'effet de dispersion du JIT noyau au coût d'un compromis sur
# les performances associées.
net.core.bpf_jit_harden =2
# Pas de routage entre les interfaces. Cette option est spéciale et peut
# entrainer des modifications d'autres options. En plaçant cette option au plus
# tôt , on s'assure que la configuration des options suivantes ne change pas.
net.ipv4.ip_forward =0
# Considère comme invalides les paquets reçus de l'extérieur ayant comme source
# le réseau 127/8.
net.ipv4.conf.all.accept_local =0
# Refuse la réception de paquet ICMP redirect. Le paramétrage suggéré de cette
# option est à considérer fortement dans le cas de routeurs qui ne doivent pas
# dépendre d'un élément extérieur pour déterminer le calcul d'une route. Même
# pour le cas de machines non -routeurs , ce paramétrage prémunit contre les
# détournements de trafic avec des paquets de type ICMP redirect.
net.ipv4.conf.all.accept_redirects =0
net.ipv4.conf.default.accept_redirects =0
net.ipv4.conf.all.secure_redirects =0
net.ipv4.conf.default.secure_redirects =0
net.ipv4.conf.all.shared_media =0
net.ipv4.conf.default.shared_media =0
# Refuse les informations d'en -têtes de source routing fournies par le paquet
# pour déterminer sa route.
net.ipv4.conf.all.accept_source_route =0
net.ipv4.conf.default.accept_source_route =0
# Empêche le noyau Linux de gérer la table ARP globalement. Par défaut , il peut
# répondre à une requête ARP d'une interface X avec les informations d'une
# interface Y. Ce comportement est problématique pour les routeurs et les
# équipements d'un système en haute disponibilité (VRRP ...).
net.ipv4.conf.all.arp_filter =1
# Ne répond aux sollicitations ARP que si l'adresse source et destination sont sur
# le même réseau et sur l'interface sur laquelle le paquet a été reçu. Il est à
# noter que la configuration de cette option est à étudier selon le cas d'usage.
net.ipv4.conf.all.arp_ignore =2
# Refuse le routage de paquet dont l'adresse source ou destination est celle de la
# boucle locale. Cela interdit l'émission de paquet ayant comme source 127/8.
net.ipv4.conf.all.route_localnet =0
# Ignore les sollicitations de type gratuitous ARP. Cette configuration est
# efficace contre les attaques de type ARP poisoning mais ne s'applique qu 'en
# association avec un ou plusieurs proxy ARP maîtrisés. Elle peut également être
# problématique sur un réseau avec des équipements en haute disponibilité (VRRP ...)
net.ipv4.conf.all.drop_gratuitous_arp =1
# Vérifie que l'adresse source des paquets reçus sur une interface donnée aurait
# bien été contactée via cette même interface. À défaut , le paquet est ignoré.
# Selon l'usage , la valeur 1 peut permettre d'accroître la vérification à
# l'ensemble des interfaces , lorsque l'équipement est un routeur dont le calcul de
# routes est dynamique. Le lecteur intéressé est renvoyé à la RFC3704 pour tout
# complément concernant cette fonctionnalité.
net.ipv4.conf.default.rp_filter =1
net.ipv4.conf.all.rp_filter =1
# Cette option ne doit être mise à 1 que dans le cas d'un routeur , car pour ces
# équipements l'envoi de ICMP redirect est un comportement normal. Un équipement
# terminal n'a pas de raison de recevoir un flux dont il n'est pas destinataire et
# donc d'émettre un paquet ICMP redirect.
net.ipv4.conf.default.send_redirects =0
net.ipv4.conf.all.send_redirects =0
# Ignorer les réponses non conformes à la RFC 1122
net.ipv4.icmp_ignore_bogus_error_responses =1
# Augmenter la plage pour les ports éphémères
net.ipv4.ip_local_port_range =32768 65535
# RFC 1337
net.ipv4.tcp_rfc1337 =1
# Utilise les SYN cookies. Cette option permet la prévention d'attaque de
# type SYN flood.
net.ipv4.tcp_syncookies =1

net.ipv6.conf.default.disable_ipv6 =1
net.ipv6.conf.all.disable_ipv6 =1
EOF




cat > "/etc/sysctl.d/99-PFE-filesystem-hardening.conf" <<'EOF'
# Désactive la création de coredump pour les exécutables setuid
# Notez qu 'il est possible de désactiver tous les coredumps avec la
# configuration CONFIG_COREDUMP=n
fs.suid_dumpable = 0
# Disponible à partir de la version 4.19 du noyau Linux , permet d'interdire
# l'ouverture des FIFOS et des fichiers "réguliers" qui ne sont pas la propriété
# de l'utilisateur dans les dossiers sticky en écriture pour tout le monde.
fs.protected_fifos =2
fs.protected_regular =2
# Restreint la création de liens symboliques à des fichiers dont l'utilisateur
# est propriétaire. Cette option fait partie des mécanismes de prévention contre
# les vulnérabilités de la famille Time of Check - Time of Use (Time of Check -
# Time of Use)
fs.protected_symlinks =1
# Restreint la création de liens durs à des fichiers dont l'utilisateur est
# propriétaire. Ce sysctl fait partie des mécanismes de prévention contre les
# vulnérabilités Time of Check - Time of Use , mais aussi contre la possibilité de
# conserver des accès à des fichiers obsolètes
fs.protected_hardinks =1
EOF




cat > "/etc/profile.d/auto-logout.sh" <<'EOF'
TMOUT=600
readonly TMOUT
export TMOUT
EOF


if grep -qE "^[#]*\s*ClientAliveInterval\b" /etc/ssh/sshd_config; then
  sed -i -E "s|^[#]*\s*ClientAliveInterval\b.*|ClientAliveInterval 300|" /etc/ssh/sshd_config
else
  echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
fi

if grep -qE "^[#]*\s*ClientAliveCountMax\b" /etc/ssh/sshd_config; then
  sed -i -E "s|^[#]*\s*ClientAliveCountMax\b.*|ClientAliveCountMax 0|" /etc/ssh/sshd_config
else
  echo "ClientAliveCountMax 0" >> /etc/ssh/sshd_config
fi





# Appliquer la configuration
echo -e "Mise à jour de GRUB...\n"
update-grub

echo -e "\nTerminé."

# TODO redémarrer