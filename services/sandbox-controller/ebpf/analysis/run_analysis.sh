#!/bin/bash
set -euo pipefail

########################
# CHECKS
########################
if [[ -z "${1:-}" || ! -f "$1" ]]; then
  echo "Usage: $0 <sample.sh> [<job_id>]"
  exit 1
fi

trap cleanup_vm EXIT INT TERM

########################
# CONFIGURATION
########################
GOLDEN_VM="sandbox-ebpf"
VM_NAME="${GOLDEN_VM}_TMP"
VM_USER="analyst"

SSH_KEY="$HOME/.ssh/kvm/id_ed25519"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/UserKnownHostsFile"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS_DIR="$PROJECT_DIR/logs"

SAMPLE="$1"
SANDBOX_JOB_ID="${2:-unknown}"
OUT_DIR="$LOGS_DIR/$SANDBOX_JOB_ID"

REMOTE_SAMPLE="/tmp/$(basename "$SAMPLE")"
REMOTE_LOG="/tmp/ebpf.log"
REMOTE_COLLECTOR="/opt/ebpf/ebpf_collector.bt"

mkdir -p "$OUT_DIR"

########################
# REVERT VM
########################
cleanup_vm() {
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        if [[ "$(virsh domstate "$VM_NAME")" != "shut off" ]]; then
            virsh destroy "$VM_NAME"
        fi
        virsh undefine "$VM_NAME" --remove-all-storage
    fi
}

if virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "[WARN] VM $VM_NAME still exists, destroying..."
    cleanup_vm
fi

if [[ "$(virsh domstate "$GOLDEN_VM")" != "shut off" ]]; then
    echo "[FATAL] Golden VM $GOLDEN_VM have been started, may be compromised"
    exit 1
fi

virt-clone \
  --original "$GOLDEN_VM" \
  --name "$VM_NAME" \
  --auto-clone
virsh start "$VM_NAME"
while [ "$(virsh domstate "$VM_NAME")" != "running" ]; do
    sleep 1
done


########################
# GET VM IP
########################
wait_for_vm_ip() {
    local VM="$1"
    local timeout=120
    local elapsed=0
    local ip=""

    while (( elapsed < timeout )); do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)
        if [[ -n "$ip" ]]; then
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    echo "[ERROR] Timeout waiting for IP for VM $VM" >&2
    return 1
}
wait_for_vm_ip $VM_NAME

VM_IP=$(virsh domifaddr "$VM_NAME" | awk '/ipv4/ {print $4}' | cut -d/ -f1)

echo "[+] VM IP: $VM_IP"
echo "[+] Output dir: $OUT_DIR"

#######################
# COPY COLLECTOR
#######################
echo "[+] Copying collector to VM"
ssh $SSH_OPTS "$VM_USER@$VM_IP" "sudo mkdir -p /opt/ebpf && sudo chown analyst:analyst /opt/ebpf"
scp $SSH_OPTS "$PROJECT_DIR/ebpf_collector.bt" "$VM_USER@$VM_IP:$REMOTE_COLLECTOR"

########################
# COPY SAMPLE
########################
echo "[+] Copying sample to VM"
scp $SSH_OPTS "$SAMPLE" "$VM_USER@$VM_IP:$REMOTE_SAMPLE"
rm -f $SAMPLE

########################
# RUN SAMPLE UNDER eBPF
########################
echo "[+] Running sample under eBPF"
ssh $SSH_OPTS "$VM_USER@$VM_IP" "
  sudo bpftrace /opt/ebpf/ebpf_collector.bt \
    -c '/bin/bash $REMOTE_SAMPLE' \
    > $REMOTE_LOG
"

########################
# FETCH LOGS
########################
echo "[+] Fetching eBPF logs"
scp $SSH_OPTS "$VM_USER@$VM_IP:$REMOTE_LOG" "$OUT_DIR/ebpf.log"

########################
# ANALYSIS
########################
echo "[+] Running analysis"
python3 "$PROJECT_DIR/build_report.py" "$OUT_DIR/ebpf.log" > "$OUT_DIR/report.json"



########################
# DONE
########################
echo "[+] Analysis complete"
echo "[+] Logs     : $OUT_DIR/ebpf.log"
echo "[+] Report   : $OUT_DIR/report.json"

# trap will delete $VM_NAME