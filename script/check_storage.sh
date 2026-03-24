#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Illegal number of parameters"
    exit 1
fi

ORANGE='\033[33m'
RESET='\033[0m'

K3S="$1"
PACKER="${2}.qcow2"

K3S_PATH="/var/lib/libvirt/images/$K3S"
PACKER_PATH="/var/lib/libvirt/images/$PACKER"
CUCKOO_FLAG="/opt/cuckoo3/.installed"


REQ_VAR=0
REQ_HOME=0
WARNING="0"

# /var/lib requirements
[[ ! -f "$K3S_PATH" ]] && REQ_VAR=$((REQ_VAR + 10))
[[ ! -f "$PACKER_PATH" ]] && REQ_VAR=$((REQ_VAR + 10))

# /home requirements
[[ ! -f "$CUCKOO_FLAG" ]] && REQ_HOME=20

# filesystem
FS_VAR=$(df --output=source "/var/lib" | tail -1)
FS_HOME=$(df --output=source "/home" | tail -1)
FREE_VAR=$(df -BG --output=avail "/var/lib" | tail -1 | tr -d 'G')
FREE_HOME=$(df -BG --output=avail "/home" | tail -1 | tr -d 'G')

if [[ "$FS_VAR" == "$FS_HOME" ]]; then
    TOTAL_REQ=$((REQ_VAR + REQ_HOME))
    if (( FREE_VAR < TOTAL_REQ )); then
        echo -e "${ORANGE}Espace disque insuffisant : ${TOTAL_REQ}G nécessaires, ${FREE_VAR} disponibles${RESET}"
        WARNING="1"
    fi
else
    if (( FREE_VAR < REQ_VAR )); then
        echo -e "${ORANGE}Espace disque insuffisant : /var/lib n'a pas assez d'espace, ${REQ_VAR}G nécessaires, ${FREE_VAR} disponibles${RESET}"
        WARNING="1"
    fi

    if (( FREE_HOME < REQ_HOME )); then
        echo -e "${ORANGE}Espace disque insuffisant : /home n'a pas assez d'espace, ${REQ_HOME}G nécessaires, ${FREE_HOME} disponibles${RESET}"
        WARNING="1"
    fi
fi

if [ $WARNING = "1" ]; then
    echo
    echo "Voulez vous continuer malgré tout ? (oui/non)"
    read -r ANSWER
    case "$ANSWER" in
            oui|OUI|o|y|yes|YES|O|Y) ;;
            *) exit 1 ;;
    esac
fi