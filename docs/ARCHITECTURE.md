## Diagramme structurel

```mermaid
flowchart LR
    
subgraph HOST
    subgraph R1["réseau 192.168.100.0/24 (isolé)"]
        VM1[VM inetsim]
        VM2[VM linux / windows 10/11]
    end

    subgraph R2[réseau 192.168.122.0/24]
        subgraph VM3[VM k3s]
            subgraph C[cluster argocd]
                P1[api]
                P2[worker static]
                P3[worker dynamic]
                P4[sandbox]
            end
        end
    end
    
end
```
<hr>

## Workflow

```mermaid
flowchart TD    
    USER-->|curl -X POST http://API_IP:8000/api/submit -F ''file=@sample.exe''|API
    API --> redis
    redis --> worker1[worker static]
    redis --> worker2[worker dynamic]
    worker2 --> worker3[worker sandbox]
    worker1 --> VT[VirusTotal]
    VT --> worker1
    worker3 -->|KVM| VM[VM sandbox]
    drakvuf --- VM
    drakvuf --> worker3
    worker1 --> redis2
    worker3 --> redis2[redis]
    USER <-->|curl http://API_IP:8000/api/result/JOB_ID| redis2
    click VT "https://virustotal.com" "VirusTotal" _blank
    click drakvuf "https://drakvuf.com/" "drakvuf" _blank
    click redis " https://redis.io/" "redis" _blank
    click redis2 " https://redis.io/" "redis" _blank
   
```
<br>
<hr>

## Installation worflow

```mermaid
flowchart TD 
    USER --> setup[setup.sh]
    setup --> Drakvuf
    setup --> Terraform
    Terraform --> VMs
    Terraform --> networks
    subgraph networks
        subgraph VMs
            Inetsim
            k3s
        end
    end
    k3s --> Argocd[Argo CD]
    subgraph services
        API
        worker1[worker static]
        worker2[worker dynamic]
        worker3[worker sandbox]
    end
    Argocd --> services
    
    click Drakvuf "https://drakvuf.com/" "Drakvuf" _blank
    click Terraform "https://.terraform.io/" "Terraform" _blank
    click Argocd "https://argo-cd.readthedocs.io" "Argo CD" _blank
    click Inetsim "https://inetsim.org/" "INetSim" _blank
```
<br>
<hr>


### tree
. <br>
├── docs <br>
│      ├── ARCHITECTURE.md <br>
│      └── SANDBOX.md <br>
├── infra <br>
│      ├── agocd <br>
│      │      └── malware-analysis-app.yaml <br>
│      └── terraform <br>
│           ├── network-external.tf <br>
│           ├── network-sandbox.tf <br>
│           ├── outputs.tf <br>
│           ├── pool.tf <br>
│           ├── provider.tf <br>
│           ├── terraform.tfstate <br>
│           ├── terraform.tfstate.backup <br>
│           ├── variables.tf <br>
│           ├── vm-inetsim.tf <br>
│           ├── vm-inetsim.yaml <br>
│           ├── vm-k3s.tf <br>
│           └── vm-k3s.yaml <br>
├── k3s <br>
│      ├── api-deployment.yaml <br>
│      ├── configmap-yara.yaml <br>
│      ├── kustomization.yaml <br>
│      ├── namespace.yaml <br>
│      ├── pvc.yaml <br>
│      ├── redis.yaml <br>
│      ├── sandbox-controller-deployment.yaml <br>
│      ├── secrets.yaml <br>
│      ├── services.yaml <br>
│      ├── worker-dynamic-deployment.yaml <br>
│      └── worker-static-deployment.yaml <br>
├── README.md <br>
├── script <br>
│      ├── sandbox-firewall.sh <br>
│      └──  setup-env.sh <br>
├── services <br>
│      ├── api <br>
│      │      ├── Dockerfile <br>
│      │      ├── main.py <br>
│      │      └── requirements.txt <br>
│      ├── sandbox <br>
│      │      └── controller <br>
│      │           ├── Dockerfile <br>
│      │           ├── main.py <br>
│      │           └── requirements.txt <br>
│      ├── worker-dynamic <br>
│      │      ├── Dockerfile <br>
│      │      ├── main.py <br>
│      │      └── requirements.txt <br>
│      └── worker-static <br>
│           ├── Dockerfile <br>
│           ├── main.py <br>
│           └── requirements.txt <br>
├── setup.sh <br>
├── .env.example <br>
├── .gitignore <br>
└── yara-rules <br>
       ├── index.yar <br>
       ├── ... <br>
       ... <br>
