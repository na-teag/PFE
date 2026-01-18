## INFORMATIONS – Documentation technique

Ce document contient l’ensemble des informations techniques détaillées du projet.

## Installation individuelle des composants

Cette section décrit l’installation manuelle des principaux outils utilisés par le projet.
À noter que dans un usage standard, ces étapes sont automatisées par le script setup.sh.

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


Installer Packer :
```bash
sudo snap install packer --classic
```

## Commandes utiles Terraform et Kubernetes
Utiliser terraform sans `sudo` : ```bash sudo usermod -aG libvirt $USER``` puis redémarrer

Tester la configuration terraform sans l'appliquer : ```bash terraform plan ```

Appliquer la config terraform : ```bash terraform apply```

Pour effacer tout ce qui a été créé par terraform avant de relancer une config : ```bash terraform destroy```

Supprimer une ressource spécifique : ```bash terraform destroy -target=libvirt_domain.k3s_master```

Appliquer la config avec kubectl : ```bash kubectl apply -k k3s/```


### Contrôle des VMs


Démarrer une VM : ```bash virsh start k3s-master```

Se connecter à la console : ```bash virsh console k3s-master```

Vérifier l'état des VMs : ```bash virsh list --all``` et ```bashvirsh dominfo k3s-master```

Arrêter une VM : ```bash virsh shutdown k3s-master```

Redémarrer une VM : ```bash virsh reboot k3s-master```

Forcer l'arrêt : ```bash virsh destroy k3s-master```

Afficher les disques attachés : ```bash virsh domblklist k3s-master```


Faire un snapshot : ```bash virsh snapshot-create-as k3s-master snapshot1 "snapshot avant test"```

Restaurer un snapshot : ```bash virsh snapshot-revert k3s-master snapshot1```

Supprimer un snapshot : ```bash virsh snapshot-delete k3s-master snapshot1```

### Cloud-init

Vous pouvez tester que l'exécution cloud-init s'est déroulée correctement en exécutant dans la VM :
```bash
cloud-init status
sudo cloud-init schema --system
```

### ArgoCD

Depuis la machine hôte, la commande suivante permet d’obtenir automatiquement :

- l’URL d’accès à ArgoCD
- l’identifiant administrateur
- le mot de passe initial
```bash
ssh k3s@192.168.122.2 'echo "service ArgoCD : https://$(hostname -I | awk "{print \$1}"):$(kubectl get svc argocd-server -n argocd -o jsonpath="{.spec.ports[?(@.port==443)].nodePort}")"; echo "id : admin"; echo "pwd : $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"'
```

## Packer Images

Création d’une golden image Windows 10 pour l’analyse dynamique.

Modifier le champ output_directory dans le fichier suivant afin de disposer d’au moins 35 Go d’espace disque : 'infra/packer/packer-windows/win10_22h2.pkr.hcl' <br>

Commandes :
```bash
packer init win10_22h2.pkr.hcl
packer build win10_22h2.pkr.hcl
```

## Docker Images
Build des images Docker

Se placer dans le dossier du service concerné (`api`, `sandbox-controller/cuckoo`, `worker-static` ou `worker-dynamic`), et incrémenter la version de l'image ici et dans le fichier YAML associé :
```bash
docker build -t dockerhubmalware/malware-<nom_du_service>:vx.y.z .
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
```

### Mettre à jour la clé VirusTotal

```bash
ssh k3s@192.168.122.2 "kubectl patch secret vt-credentials -n malware-analysis \
  --type='merge' \
  -p='{\"stringData\":{\"VIRUSTOTAL_API_KEY\":\"replace_by_key\"}}' \
  && kubectl delete pod -n malware-analysis -l app=worker-static \
  && echo ok"
```

## Cuckoo3

### supprimer les fichiers cuckoo :

```bash
sudo systemctl stop cuckoo-api.service
sudo systemctl stop cuckoo-web.service
sudo systemctl stop cuckoo.service
sudo umount /mnt/win10x64
sudo rm -rf /home/cuckoo/
sudo gpasswd -d www-data cuckoo
sudo deluser cuckoo
sudo delgroup cuckoo
sudo rm /opt/cuckoo3/.installed
```

### Service web

https://localhost:9090

### Service API

https://localhost:8080


## Tests et validations des services
Les services s’exécutent exclusivement dans le cluster Kubernetes.

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
  -F "file=@sample.exe" \
  -F "sandbox_os=windows"
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

À noter que le rapport correspond à une synthèse des résultats statiques et dynamiques, tandis que le résultat brut contient l’ensemble des données collectées.

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

Pour toutes les commandes précédentes, il est également possible de voir les résultats directement sur l'interface web de l'API depuis cette url : http://<API_IP>:8000/.
Pour voir la documentation Swagger, il faut la consulter à cette url : http://<API_IP>:8000/docs.


### Vérification et gestion de Redis

Redis est utilisé comme file de jobs et stockage temporaire des résultats d’analyse.

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

À noter que les jobs sont supprimés automatiquement au bout de 7 jours.
