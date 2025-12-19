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

## Docker Images
Build des images Docker

Se placer dans le dossier du service concerné (api, sandbox-controller, worker-static ou worker-dynamic) :
```bash
docker build -t <dockerhub_username>/malware-<nom_du_service>:latest .
```

Exemple pour le service api:
```bash 
docker build -t jteam0/malware-api:latest .
```

Push des images sur Docker Hub
```bash
docker push jteam0/malware-<nom_du_service>:latest
```

Rebuild après modification du code

À chaque modification du code ou du Dockerfile, à la racine de chaque service :
```bash
# rebuild
docker build -t jteam0/malware-<nom_du_service>:latest .

# push
docker push jteam0/malware-<nom_du_service>:latest
```

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

