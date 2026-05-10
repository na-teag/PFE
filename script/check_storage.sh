#!/bin/bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "Illegal number of parameters"
    exit 1
fi

ORANGE='\033[33m'
RESET='\033[0m'

declare -A VMS=(
    ["k3s"]="$1"
    ["download"]="$2"
    ["inetsim"]="$3"
    ["cuckoo"]="$4"
    ["image linux"]="$5"
)
IMG_DIR="$6"

REQ_GB=0
echo -e "\n\n\n--- Vérification de l'espace disque ---"

if [[ ! -d "$IMG_DIR" ]]; then
    echo "Dossier inexistant: $IMG_DIR"
    exit 1
fi

for role in "${!VMS[@]}"; do
    FILE="$IMG_DIR/${VMS[$role]}"
    if [[ ! -s "$FILE" ]]; then
        # On définit ici le poids estimé par type de VM
        case $role in
            "cuckoo") weight=20 ;;
            "k3s") weight=6 ;;
            "inetsim"|"download") weight=2 ;;
            "image linux") weight=1 ;;
            *) weight=0 ;;
        esac
        REQ_GB=$((REQ_GB + weight))
        echo "Prévu : $role (${VMS[$role]}) -> +${weight}G"
    else
        echo "Existant : $role (${VMS[$role]}) -> 0G"
    fi
done

FREE_BLOCKS=$(df -PB1 "$IMG_DIR" | tail -1 | awk '{print $4}')
FREE_GB=$(( FREE_BLOCKS / 1024 / 1024 / 1024 ))

if (( FREE_GB < REQ_GB )); then
    echo -e "\n${ORANGE}[!] Espace insuffisant sur $IMG_DIR${RESET}"
    echo -e "Besoin estimé : ${REQ_GB}G"
    echo -e "Disponible     : ${FREE_GB}G"

    echo -ne "\nContinuer malgré tout ? (o/N) : "
    read -r ANSWER
    case "$ANSWER" in
        [oOyY]|[oO][uU][iI]|[yY][eE][sS])
            echo "Poursuite de l'installation..."
            ;;
        *)
            echo "Arrêt."
            exit 1
            ;;
    esac
else
    echo -e "\n[OK] Espace suffisant (${FREE_GB}G disponibles pour ${REQ_GB}G requis).\n\n\n\n\n"
fi