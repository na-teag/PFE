#!/bin/bash
set -euo pipefail

########################
# CONFIGURATION
########################
VM_NAME="sandbox-ebpf"
VM_USER="analyst"

SSH_KEY="$HOME/.ssh/sandbox_key"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS_DIR="$PROJECT_DIR/logs"

SAMPLE="$1"
TIMESTAMP="$(date +"%Y-%m-%d_%H-%M-%S")"
OUT_DIR="$LOGS_DIR/$TIMESTAMP"

REMOTE_SAMPLE="/tmp/$(basename "$SAMPLE")"
REMOTE_LOG="/tmp/ebpf.log"
REMOTE_COLLECTOR="/opt/ebpf/ebpf_collector.bt"

########################
# CHECKS
########################
if [[ -z "${SAMPLE:-}" || ! -f "$SAMPLE" ]]; then
  echo "Usage: $0 <sample.sh>"
  exit 1
fi

mkdir -p "$OUT_DIR"

########################
# GET VM IP
########################
VM_IP=$(virsh domifaddr "$VM_NAME" | awk '/ipv4/ {print $4}' | cut -d/ -f1)

if [[ -z "$VM_IP" ]]; then
  echo "[-] Unable to get VM IP"
  exit 1
fi

echo "[+] VM IP: $VM_IP"
echo "[+] Output dir: $OUT_DIR"

#######################
# COPY COLLECTOR
#######################
echo "[+] Copying collector to VM"
ssh $SSH_OPTS "$VM_USER@$VM_IP" "sudo mkdir -p /opt/ebpf && sudo chown analyst:analyst /opt/ebpf"
scp $SSH_OPTS "ebpf_collector.bt" "$VM_USER@$VM_IP:$REMOTE_COLLECTOR"

########################
# COPY SAMPLE
########################
echo "[+] Copying sample to VM"
scp $SSH_OPTS "$SAMPLE" "$VM_USER@$VM_IP:$REMOTE_SAMPLE"

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
python3 build_report.py "$OUT_DIR/ebpf.log" > "$OUT_DIR/report.json"

########################
# DONE
########################
echo "[+] Analysis complete"
echo "[+] Logs     : $OUT_DIR/ebpf.log"
echo "[+] Report   : $OUT_DIR/report.json"
