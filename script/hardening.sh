#!/bin/bash

set -euo pipefail

# Vérifier root
if [ "$EUID" -ne 0 ]; then
  echo "Ce script doit être exécuté en root."
  exit 1
fi

#echo "Génération du hash GRUB (entrez votre mot de passe):"
#HASH=$(grub-mkpasswd-pbkdf2 | sed -n 's/^.*grub.pbkdf2/grub.pbkdf2/p')
# TODO (IRL) changer le mdp
HASH="grub.pbkdf2.sha512.10000.0528AAA1E3D1F8CDFAA83D0E460FF8611FF7F63471EF0B2B06998791EDA07BB46773EFB83A565367317C7ABF4D6292F2F3E5D0B4D990C79DD634630F649B512E.AAC30A012B6EC0EB882F4C54BA8387D539B0D12D523C1F380DDEC6E7DD06E1C40861D669611A147B91FDFA451EB4C8280D06DDCC884FBCCA7DE94F92EC2E668F"

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


# ajouter les modules à charger pour la VM, uniquement si le fichier n'est pas déjà rempli
if ! grep -qv '^\s*\(#\|$\)' /etc/modules-load.d/modules.conf; then
  lsmod | cut -d" " -f1 | tail -n +2 >> /etc/modules-load.d/modules.conf
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


kernel.yama.ptrace_scope = 2

# NOTES : les modules à charger aux démarrage sont à mettre dans /etc/modules-load.d/modules.conf
kernel.modules_disabled =1
EOF
sysctl -p /etc/sysctl.d/99-PFE-kernel-hardening.conf



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
sysctl -p /etc/sysctl.d/99-PFE-network-security.conf




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
fs.protected_hardlinks =1
EOF
sysctl -p /etc/sysctl.d/99-PFE-filesystem-hardening.conf





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

if grep -qE "^[#]*\s*PasswordAuthentication\b" /etc/ssh/sshd_config; then
  sed -i -E "s|^[#]*\s*PasswordAuthentication\b.*|PasswordAuthentication no|" /etc/ssh/sshd_config
else
  echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

if grep -qE "^[#]*\s*PermitEmptyPasswords\b" /etc/ssh/sshd_config; then
  sed -i -E "s|^[#]*\s*PermitEmptyPasswords\b.*|PermitEmptyPasswords no|" /etc/ssh/sshd_config
else
  echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
fi



cat > "/etc/profile.d/umask.sh" <<'EOF'
umask 077
EOF


echo "UMASK=027" > "/etc/default/login"
sed -i 's/^\(session[[:space:]]\+optional[[:space:]]\+pam_umask\.so\).*/\1 umask=0027/' /etc/pam.d/common-session



# TODO lister les commandes (avec leurs arguments) nécessitants sudo pour les autoriser explicitement et refuser le reste (R40-R43)


apt install apparmor-utils -y
aa-enforce /etc/apparmor.d/*

# TODO lister les répertoires des services spécifiques aux VMs et vérifier que les permissions sont restrictives (R50)

rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server

apt purge snapd multipath-tools -y

systemctl disable --now cloud-config.service
systemctl disable --now cloud-final.service
systemctl disable --now cloud-init-local.service
systemctl disable --now cloud-init.service
#systemctl disable --now apport.service
#systemctl disable --now serial-getty@ttyS0.service


cat > "/etc/pam.d/passwd" <<'EOF'
#
# The PAM configuration file for the Shadow `passwd' service
#

@include common-password

# Au moins 12 caractères de 3 classes différentes parmi les majuscules ,
# les minuscules , les chiffres et les autres en interdisant la répétition
# d'un caractère
password required pam_pwquality.so minlen =12 minclass =3 \
dcredit =0 ucredit =0 lcredit =0 \
ocredit =0 maxrepeat =1
EOF


echo -e "\n\n# Blocage du compte pendant 5 min après 3 échecs\nauth required pam_faillock.so deny=3 unlock_time =300" >> /etc/pam.d/login
echo -e "\n\n# Blocage du compte pendant 5 min après 3 échecs\nauth required pam_faillock.so deny=3 unlock_time =300" >> /etc/pam.d/sshd


echo -e "\n\npassword required pam_unix.so obscure yescrypt rounds =11" >> /etc/pam.d/common-password



# Appliquer la configuration grub
echo -e "Mise à jour de GRUB...\n"
update-grub



apt install auditd audispd-plugins -y
chattr -a /var/log/audit/audit.log 2>/dev/null
systemctl enable --now auditd


cat > "/etc/audit/auditd.conf" <<'EOF'
#
# This file controls the configuration of the audit daemon
#

local_events = yes
write_logs = yes
log_file = /var/log/audit/audit.log
log_group = adm
log_format = RAW
flush = INCREMENTAL_ASYNC
freq = 50
max_log_file = 10
num_logs = 5
priority_boost = 4
name_format = NONE
##name = mydomain
max_log_file_action = ROTATE
space_left = 75
space_left_action = SYSLOG
verify_email = yes
action_mail_acct = root
admin_space_left = 50
admin_space_left_action = HALT
disk_full_action = HALT
disk_error_action = HALT
use_libwrap = yes
##tcp_listen_port = 60
tcp_listen_queue = 5
tcp_max_per_addr = 1
##tcp_client_ports = 1024-65535
tcp_client_max_idle = 0
transport = TCP
krb5_principal = auditd
##krb5_key_file = /etc/audit/audit.key
distribute_network = no
q_depth = 1200
overflow_action = SYSLOG
max_restarts = 10
plugin_dir = /etc/audit/plugins.d
end_of_event_timeout = 2
EOF

systemctl restart auditd
chattr +a /var/log/audit/audit.log



cat > "/etc/audit/audit.rules" <<'EOF'
# Exécution de insmod , rmmod et modprobe
-w /sbin/insmod -p x
-w /sbin/modprobe -p x
-w /sbin/rmmod -p x
# Sur les distributions GNU/Linux récentes , insmod , rmmod et modprobe sont
# des liens symboliques de kmod
-w /bin/kmod -p x
# Journaliser les modifications dans /etc/
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/ -p wa -k etc_changes
# sudo échoué
-a always,exit -F arch=b64 -F path=/usr/bin/sudo -F success=0 -k sudo_failed
# Surveillance de montage/démontage
-a exit ,always -S mount -S umount2
# Appels de syscalls x86 suspects
-a exit ,always -S ioperm -S modify_ldt
# Appels de syscalls qui doivent être rares et surveillés de près
-a exit ,always -S get_kernel_syms -S ptrace
-a exit ,always -S prctl
# Rajout du monitoring pour la création ou suppression de fichiers
# Ces règles peuvent avoir des conséquences importantes sur les
# performances du système
# -a exit ,always -F arch=b64 -S unlink -S rmdir -S rename
-a exit ,always -F arch=b64 -S creat -S open -S openat -F exit=-EACCES
-a exit ,always -F arch=b64 -S truncate -S ftruncate -F exit=-EACCES
# Rajout du monitoring pour le chargement , le changement et
# le déchargement de module noyau
-a exit ,always -F arch=b64 -S init_module -S delete_module
-a exit ,always -F arch=b64 -S finit_module
# Verrouillage de la configuration de auditd
-e 2
EOF

chmod 750 /sbin/auditctl




apt install fail2ban -y
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
awk '
BEGIN {replace=0}
/^\[sshd\]/ {
    print "[sshd]\nenabled = true\nignoreip = 127.0.0.1\nbantime = 180\nmaxretry = 3\nport    = ssh\nlogpath = %(sshd_log)s\nbackend = %(sshd_backend)s\n\n"
    replace=1
    next
}
/^\[/ {
    replace=0
}
!replace
' /etc/fail2ban/jail.local > /tmp/jail.local && mv /tmp/jail.local /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl start fail2ban





echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections
echo "postfix postfix/mailname string localhost" | debconf-set-selections
apt install -y aide aide-common --no-install-recommends
apt autoremove -y

while IFS= read -r line; do
  grep -qxF "$line" /etc/aide/aide.conf || echo "$line" >> /etc/aide/aide.conf
done << 'EOF'
!/tmp
!/var/tmp
!/run/containerd
!/run/systemd/transient
!/var/lib/rancher/k3s/agent/containerd
EOF

rm -rf /var/lib/aide/aide.db
aideinit -y
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
#aide --config=/etc/aide/aide.conf --update
#mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
# TODO (IRL) générer la clé privée sur un serveur externe et signer la base dessus, récupérer la clé publique en local.
rm -rf ~/.gnupg
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "AIDE_signing_key" rsa4096 sign 0
rm -rf /var/lib/aide/aide.db.sig
gpg --detach-sign /var/lib/aide/aide.db
#aide --config=/etc/aide/aide.conf --check # commande pour comparer les BDD
#gpg --verify /var/lib/aide/aide.db.sig /var/lib/aide/aide.db # commande pour vérifier l'authenticité de la BDD
# TODO (IRL) organiser une exécution periodique et centraliser les données?/résultats





#Defaults    noexec,requiretty,use_pty,umask=0027
cat > "/etc/sudoers.d/hardening" <<'EOF'
# Hardening sudo par défaut
Defaults    noexec,requiretty,use_pty,umask=0027
Defaults    ignore_dot,env_reset
EOF


echo -e "\nTerminé."

reboot