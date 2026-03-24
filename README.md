# PFE



```mermaid
flowchart TB
    USER -->|1. Upload sample| BLOB[Azure Blob Storage]
    BLOB -->|2. Event Grid| FUNC[Azure Function]

        subgraph HOST[Linux Host]
            CUCKOO[Cuckoo3]
            WINVM[Windows Guest VM]
        end
        
        subgraph LINVM[Linux VM]
            QUARANTINE[Quarantine]
            INETSIM[INetSim]
        end
    FUNC -->|3. Provision & Start Task| HOST
    QUARANTINE -->|4. Pull Sample| BLOB
    QUARANTINE -->|5. Send sample| CUCKOO
    CUCKOO -->|6. Exec sample| WINVM
    WINVM <-->|7. Network traffic| INETSIM
    CUCKOO -->|8. Generate report| BLOB
    HOST -->|9. Send logs| MONITOR[Azure Monitor]

```


## Sequence Diagram

```mermaid
%%{init: {'theme': 'light'}}%%
sequenceDiagram
    actor User
    participant API
    participant Redis
    participant Static Worker
    participant Sandbox Controller
    participant KVM/Cuckoo

    
    rect rgb(240, 240, 245)
        Note over User,KVM/Cuckoo: Phase 1 — Soumission
        User->>API: POST /analyze (fichier)
        API->>Redis: LPUSH job_queue_static + job_queue_sandbox
        API-->>User: 202 Accepted + job_id
    end

    
    rect rgb(235, 248, 242)
        Note over User,KVM/Cuckoo: Phase 2 — Analyse statique (async)
        Static Worker->>Redis: BRPOP job_queue_static
        Static Worker->>Static Worker: Scan YARA + VirusTotal
        alt success
            Static Worker->>Redis: SET result:static:{id}
        else échec scan
            Static Worker->>Redis: SET result:static:{id} error
        end
    end

    rect rgb(242, 238, 252)
        Note over User,KVM/Cuckoo: Phase 3 — Analyse dynamique (async, parallèle)
        Sandbox Controller->>Redis: BRPOP job_queue_sandbox
        Sandbox Controller->>KVM/Cuckoo: Provisionner VM (Win/Linux)
        KVM/Cuckoo->>KVM/Cuckoo: Exécution du malware
        KVM/Cuckoo-->>Sandbox Controller: Logs
        Sandbox Controller->>Redis: SET result:dynamic:{id}
        Sandbox Controller->>KVM/Cuckoo: Destruction/Snapshot Revert VM
    end

    
    rect rgb(255, 248, 220)
        Note over User,KVM/Cuckoo: Phase 4 — Rapport final
        User->>API: GET /report/{id}
        API->>Redis: MGET result:static:{id} + result:dynamic:{id}
        Redis-->>API: Données brutes JSON
        API-->>User: Rapport agrégé (JSON/PDF)
    end


```

## Threat modeling diagram 

<img width="799" height="796" alt="image" src="https://github.com/user-attachments/assets/5220ace9-e904-4f33-8c97-3b7aba1291b2" />


# Projet d'analyse de malware

## Présentation

Ce projet est une plateforme distribuée d’analyse de malwares reposant sur Kubernetes.
Elle permet de soumettre un fichier, d’effectuer une analyse statique et dynamique, puis de générer un rapport en JSON et en PDF.

### Composants principaux
- API FastAPI : soumission, orchestration, résultats, UI
- Workers statiques : analyse VirusTotal / YARA
- Workers dynamiques : analyse en sandbox Windows et Linux
- Sandbox-controller : gestion des VM d’analyses
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

- déploie une VM avec k3s et une VM avec ebpf via libvirt/virt-install

- installe et configure [Cuckoo3 Sandbox](https://github.com/cert-ee/cuckoo3)

- déploie les services Kubernetes

- initialise les secrets (VirusTotal, Cuckoo API)

- ouvre automatiquement l’interface web

Pré-requis :

- environnement Linux

- virtualisation activée (KVM / libvirt)

- ~40Go de disponible (le script vous avertira au préalable s'il manque de la place)

- accès sudo

### Limitations

- Le projet a été conçu pour utiliser terraform, mais suite à beaucoup de difficultés (erreur de provider en tout genre, documentation incomplète, erreur de création de réseau, VM non bootable, pas d'accès console, ...), Terraform a été abandonné au profit de commandes virt-install.
- Le projet prévoyait initialement d'utiliser [Drakvuf](https://drakvuf.com/) en tant que sandbox, mais suite à des difficultés d'installation/utilisation due à la contrainte de ne pas pouvoir utiliser [Xen](https://xenproject.org/), nous avons choisi d'utiliser Cuckoo3 et une VM configurée manuellement pour les analyses sur Linux.
- Le projet actuel ne permet pas de traiter plusieurs analyses simultanément, bien qu'un système de queue soit en place.
- Les analyses se font seulement sur Windows 10 (car cuckoo3 ne prend pas encore en charge windows 11) ou sur Ubuntu 22.04 (facile à changer dans le fichier [install-vm-k3s.sh](/script/install-vm-k3s.sh), l.79. Les arguments `os-variant` dans le même fichier l.91 et dans [build_vm.sh](/infra/packer/linux/dynamic-worker/build_vm.sh) l.19 seraient aussi à changer).

### Accès à l’interface

Par défaut, les services sont exposés via la VM k3s connectée au réseau libvirt via l'interface vribr0.

- Interface web API : http://192.168.122.2:8000/

- Documentation Swagger : http://192.168.122.2:8000/docs

L’interface web permet de soumettre des fichiers, de suivre les analyses et de consulter les rapports directement depuis le navigateur.
La VM k3s utilise l'adresse IP statique 192.168.122.2 configurée via cloud-init. 
Cette configuration garantit un accès stable et reproductible aux services, indépendamment de la machine hôte ou des redémarrages.

### Documentation complète

Toutes les informations détaillées (infrastructure, VM, Packer, Docker, tests, dépannage) sont disponibles dans le dossier /doc :
- [INFORMATIONS.md](/docs/INFORMATIONS.md)
- [ARCHITECTURE.md](/docs/ARCHITECTURE.md)

### Licence et règles YARA

Ce projet utilise des règles yara sous licence GPL-2.0 : [rules](https://github.com/Yara-Rules/rules)
