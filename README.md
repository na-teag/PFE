# projet-analyse-malware

## Installation

Installation de k3s : `curl -sfL https://get.k3s.io | sh -`

Installation de kubectl : `curl -LO https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl`

Après avoir installé k3s et kubectl : 

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

Installer Terraform :

```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

Installer KVM :
```bash
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst
sudo systemctl enable --now libvirtd 
```
Vérifier que le programme fonctionne correctement : `virsh list`

## Utile

Pour effacer tout ce qui a été créé par terraform avant de relancer une config : `terraform destroy` <br>
supprimer une ressource spécifique : `terraform destroy -target=libvirt_domain.k3s_master`

appliquer la config avec kubectl : `kubectl apply -k k3s/`

## Docker Images
Build des images Docker

Se placer dans le dossier du service concerné (api, sandbox-controller, worker-static ou worker-dynamic), et incrémenter la version de l'image ici et dans le fichier YAML associé :
```bash
docker build -t <dockerhub_nom_organisation>/malware-<nom_du_service>:vx.y.z .
```

Exemple pour le service api:
```bash 
docker build -t dockerhubmalware/malware-api:v1.0.0 .
```

Push des images sur Docker Hub
```bash
docker push dockerhubmalware/malware-<nom_du_service>:vx.y.z 
```

Rebuild après modification du code

À chaque modification du code ou du Dockerfile, à la racine de chaque service :
```bash
# rebuild
docker build -t dockerhubmalware/malware-<nom_du_service>:vx.y.z .

# push
docker push dockerhubmalware/malware-<nom_du_service>:vx.y.z
```
Ne pas oublier d'incrémenter la version également dans le fichier YAML du déploiement Kubernetes

Puis redémarrer les pods Kubernetes :
```bash
kubectl -n malware-analysis rollout restart deployment <nom_du_service>
```

Commandes utiles : 
```bash
# Voir les pods
kubectl get pods -n malware-analysis

# Voir les services
kubectl get svc -n malware-analysis 

# Appliquer les constantes du .env pour les services :
kubectl -n malware-analysis create secret generic vt-credentials \
  --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Tests 
Envoi d'un fichier à analyser
```bash
curl -X POST http://<API_IP>:8000/api/submit \
-F "file=@sample.exe"
```

Vérifier le retour des résultats
```bash
curl http://<API_IP>:8000/api/result/<job_id>
```

Vérifier Redis en live (adapter le nom du pod)
```bash
kubectl -n malware-analysis exec -it redis-xxx -- redis-cli
```

### info

Ce projet utilise des règles yara sous licence GPL-2.0 : [rules](https://github.com/Yara-Rules/rules)