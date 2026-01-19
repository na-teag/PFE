## Diagramme structurel

```mermaid
flowchart LR
    
subgraph HOST
    subgraph R3[réseau 192.168.30.0/24]
        subgraph Cuckoo3
            VM1[sandbox windows 10]
            VM2[sandbox windows 10]
            VM3[sandbox windows 10]
        end
    end

    subgraph R2[réseau 192.168.122.0/24]
        VM4[sandbox linux]
        subgraph VM5[VM k3s]
            subgraph C[cluster malware-analysis]
                P1[api]
                P2[worker static]
                P3[worker dynamic]
                P4[sandbox controller]
            end
        end
    end

    click Cuckoo3 "https://github.com/cert-ee/cuckoo3" "Cuckoo3" _blank
end
```
<hr>

## Workflow

```mermaid
flowchart TD    
    USER-->|curl -X POST http://API_IP:8000/api/submit -F ''file=@sample.exe'' -F ''sandbox_os=windows''|API
    API --> redis
    API --> worker1[worker static]
    API --> worker2[worker dynamic]
    worker2 --> controller[sandbox controller windows]
    worker2 --> controllerlinux[sandbox controller linux]
    worker1 <--> VT[VirusTotal]
    controller --> cuckoo[API Cuckoo3]
    controllerlinux -->|start| sandboxebpf[sandbox linux]
    controllerlinux <-->|get result| sandboxebpf
    cuckoo -->|start| sandbox[sandbox windows 10]
    cuckoo <-->|get result| sandbox
    controller <-->|get result| cuckoo
    worker1 --> redis
    controller --> redis
    USER <-->|curl http://API_IP:8000/api/result/JOB_ID| API
    API <-->|get result| redis
    click VT "https://virustotal.com" "VirusTotal" _blank
    click redis " https://redis.io/" "redis" _blank
    click redis2 " https://redis.io/" "redis" _blank
   
```
<br>
<hr>

## Installation worflow

```mermaid
flowchart TD 
    USER --> setup[setup.sh]
    setup --> Cuckoo3
    setup --> Terraform["virt-install"]
    subgraph network
        subgraph VMs
            subgraph k3s
                subgraph services
                    API
                    worker1[worker static]
                    worker2[worker dynamic]
                    worker3[worker sandbox]
                end
                Argocd[Argo CD] --> services
            end
        end
    end
    Terraform --> network
    
    click Cuckoo3 "https://github.com/cert-ee/cuckoo3" "Cuckoo3" _blank
    click Terraform "https://.terraform.io/" "Terraform" _blank
    click Argocd "https://argo-cd.readthedocs.io" "Argo CD" _blank
```


