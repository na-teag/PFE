# On crée le fichier .env dans k3s et on crée le secret Kubernetes

K3S_DIR="k3s"
ENV_FILE=".env"
SYMLINK_ENV="$K3S_DIR/.env"
NAMESPACE="malware-analysis"
SECRET_NAME="vt-credentials"

# Si .env existe déjà, on demande la confirmation
if [ -f "$ENV_FILE" ]; then
  read -p "$ENV_FILE existe déjà. Voulez-vous l'écraser ? [y/N] " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      echo "Écrasement de $ENV_FILE..."
      ;;
    *)
      echo "Abandon. $ENV_FILE n'a pas été modifié."
      exit 0
      ;;
  esac
fi

# On demande la clé VirusTotal à l'utilisateur
read -s -p "Entrez votre clé VirusTotal API : " VT_KEY
echo

# On crée le fichier .env directement
cat > "$ENV_FILE" <<EOF
REDIS_URL=redis://redis:6379
RESULTS_PATH=/data/results
SANDBOX_URL=http://sandbox-controller:9000
VIRUSTOTAL_API_KEY=$VT_KEY
YARA_DIR_PATH=/yara-rules
EOF

echo "$ENV_FILE créé avec succès dans $(pwd)"


# On crée le symlink dans le dossier k3s
if [ -L "$SYMLINK_ENV" ] || [ -f "$SYMLINK_ENV" ]; then
    rm -f "$SYMLINK_ENV"
fi
ln -s "$ENV_FILE" "$SYMLINK_ENV"
echo "Symlink créé dans le dossier $K3S_DIR du projet : $SYMLINK_ENV -> $ENV_FILE"

# On crée le secret Kubernetes à partir du .env
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret Kubernetes '$SECRET_NAME' mis à jour dans le namespace '$NAMESPACE'."
