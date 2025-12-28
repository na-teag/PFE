#!/bin/bash
set -eux

cat <<'EOF' >/usr/local/bin/autorun.sh
#!/bin/bash

SAMPLE=/opt/sample/malware.bin
RESULTS=/opt/results

mkdir -p $RESULTS

drakvuf \
  -d malware_vm \
  -o json \
  > $RESULTS/output.json

shutdown now
EOF

chmod +x /usr/local/bin/autorun.sh
