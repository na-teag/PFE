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

## Utile
utiliser terraform sans `sudo` : `sudo usermod -aG libvirt $USER` et redémarrer<br>
tester la config terraform sans l'appliquer : `terraform plan` <br>
appliquer la config terraform : `terraform apply` <br>
Pour effacer tout ce qui a été créé par terraform avant de relancer une config : `terraform destroy` <br>
supprimer une ressource spécifique : `terraform destroy -target=libvirt_domain.k3s_master`

appliquer la config avec kubectl : `kubectl apply -k k3s/`
<br>

démarrer une VM : `virsh start k3s-master` <br>
se connecter à la console : `virsh console k3s-master` <br>
vérifier l'état des VMs : `virsh list --all ` et `virsh dominfo k3s-master`<br>
arreter une VM : `virsh shutdown k3s-master` <br>
redémarrer une VM : `virsh reboot k3s-master` <br>
forcer l'arret : `virsh destroy k3s-master` <br>
afficher les disques attachés : `virsh domblklist k3s-master` <br>


faire un snapshot : `virsh snapshot-create-as k3s-master snapshot1 "snapshot avant test"` <br>
restaurer un snapshot : `virsh snapshot-revert k3s-master snapshot1` <br>
supprimer un snapshot : `virsh snapshot-delete k3s-master snapshot1`

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

# Lancer le script setup.sh pour créer le fichier .env situé à la racine du projet pour initialiser les variables d'environnement
# Un lien symbolique est également créé dans le dossier k3s pour permettre à Kustomize et aux fichiers YAML d'y accéder.
./setup.sh
# Entrer la clé Virus Total API quand c'est demandé
```

## Tests 
Les services de l’infrastructure (API, sandbox, workers) tournent dans le cluster Kubernetes et ne sont pas exposés sur localhost par défaut.

Vérifier la sandbox-controller
```bash
# Trouver l'adresse IP de la sandbox
kubectl get svc -n malware-analysis sandbox-controller

# Vérifier son statut
curl http://<SANDBOX-IP>:9000/health 
```

Vérifier l'API
```bash
# Trouver l'adresse IP de l'api
kubectl get svc -n malware-analysis api

# Vérifier son statut
curl http://<API-IP>:8000/health
```

Envoi d'un fichier à analyser
```bash
curl -X POST http://<API_IP>:8000/api/submit \
-F "file=@sample.exe"
```

Vérifier le retour des résultats d'un job précis en format JSON
```bash
curl http://<API_IP>:8000/api/result/<job_id>

# Télécharger le fichier d'analyse en JSON
curl -O -J http://<API_IP>:8000/api/result/<job_id>/download
```

Obtenir le rapport d'un job précis en format JSON
```bash
curl http://<API_IP>:8000/api/report/<job_id>

# Télécharger le rapport d'analyse en JSON
curl -O -J http://<API_IP>:8000/api/report/<job_id>/download
```

A noter que le rapport est un résumé du résultat d'un job.

Télécharger le rapport d'un job précis en format pdf
```bash
curl -O -J http://<API_IP>:8000/api/report/<job_id>/pdf
```

Vérifier la liste de toutes les analyses (jobs) avec leurs statuts
```bash
curl http://<API_IP>:8000/api/jobs
```

Supprimer complètement le job
```bash
curl -X DELETE http://<API_IP>:8000/api/jobs/<job_id>
```

Pour les commandes /health, /api/result/<job_id>, /api/result/<job_id>/download, /api/report/<job_id>, /api/result/<job_id>/download et /api/report/<job_id>/pdf et /api/jobs, il est également possible de voir les résultats directement sur l'interface web de l'API.

Vérifier Redis en live (adapter le nom du pod)
```bash
kubectl -n malware-analysis exec -it redis-xxx -- redis-cli

# Gestion des jobs dans Redis

# Pour lister tous les jobs :
KEYS job:*

# Pour supprimer un job précis : 
DEL job:<job_id>

# Pour supprimer uniquement l'analyse statique d'un job précis
DEL result_static:<job_id>

# Pour supprimer uniquement l'analyse dynamique d'un job précis
DEL result_dynamic:<job_id>
```

A noter que les jobs sont supprimés automatiquement au bout de 7 jours.

### info

Ce projet utilise des règles yara sous licence GPL-2.0 : [rules](https://github.com/Yara-Rules/rules)