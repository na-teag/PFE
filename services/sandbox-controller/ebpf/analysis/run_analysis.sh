#!/bin/bash
set -euo pipefail

########################
# CONFIGURATION
########################
VM_NAME="sandbox-ebpf"
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

########################
# CHECKS
########################
if [[ -z "${SAMPLE:-}" || ! -f "$SAMPLE" ]]; then
  echo "Usage: $0 <sample.sh> [<job_id>]"
  exit 1
fi

mkdir -p "$OUT_DIR"

########################
# REVERT SNAPSHOT
########################
virsh shutdown "$VM_NAME"
while [ "$(virsh domstate "$VM_NAME")" != "shut off" ]; do
    sleep 1
done
virsh snapshot-revert "$VM_NAME" clean-install # in case the last analysis failed before the final revert to clean installation
virsh start "$VM_NAME"

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
# REVERT SNAPSHOT
########################
virsh shutdown "$VM_NAME"
while [ "$(virsh domstate "$VM_NAME")" != "shut off" ]; do
    sleep 1
done

virsh snapshot-revert "$VM_NAME" clean-install
virsh start "$VM_NAME"

########################
# DONE
########################
echo "[+] Analysis complete"
echo "[+] Logs     : $OUT_DIR/ebpf.log"
echo "[+] Report   : $OUT_DIR/report.json"
