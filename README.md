# Projet d'analyse de malware

## Présentation

Ce projet est une plateforme distribuée d’analyse de malwares reposant sur Kubernetes.
Elle permet de soumettre un fichier, d’effectuer une analyse statique et dynamique, puis de générer un rapport en JSON et en PDF.

### Composants principaux
- API FastAPI : soumission, orchestration, résultats, UI
- Workers statiques : analyse VirusTotal / YARA
- Workers dynamiques : analyse en sandbox Windows et Linux
- Sandbox-controller : gestion des VM d’analyse
- Redis : file de jobs et stockage des résultats
- Kubernetes (k3s) : orchestration

### Installation et déploiement automatisé du projet :
```bash
git clone https://github.com/na-teag/projet-analyse-malware.git
cd projet-analyse-malware
./setup.sh
```

Le script setup.sh :

- installe les dépendances nécessaires (Terraform, Firefox si absent)

- déploie une VM k3s via libvirt/virt-install

- installe et configure Cuckoo Sandbox

- déploie les services Kubernetes

- initialise les secrets (VirusTotal, Cuckoo API)

- ouvre automatiquement l’interface web

Pré-requis :

- environnement Linux

- virtualisation activée (KVM / libvirt)

- ~40Go de disponible (le script vous avertira au préalable s'il manque de la place)

- accès sudo

### Limitations

Le projet a été conçu pour utiliser terraform, mais suite à beaucoup de difficultés (erreur de provider en tout genre, doc incomplète, erreur de création de réseau, VM non bootable, ...), Terraform a été abandonné au profit de commandes virt-install.

### Accès à l’interface

Par défaut, les services sont exposés via la VM k3s connecté au réseau libvirt via l'interface vribr0.

- Interface web API : http://192.168.122.2:8000/

- Documentation Swagger : http://192.168.122.2:8000/docs

L’interface web permet de soumettre des fichiers, de suivre les analyses et de consulter les rapports directement depuis le navigateur.
La VM k3s utilise l'adresse IP statique 192.168.122.2 configurée via cloud-init. 
Cette configuration garantit un accès stable et reproductible aux services, indépendamment de la machine hôte ou des redémarrages.

### Documentation complète

Toutes les informations détaillées (infrastructure, VM, Packer, Docker, tests, dépannage) sont disponibles dans le dossier /doc et les fichiers INFORMATIONS.md et ARCHITECTURE.md.

### License et règles YARA

Ce projet utilise des règles yara sous licence GPL-2.0 : [rules](https://github.com/Yara-Rules/rules)
