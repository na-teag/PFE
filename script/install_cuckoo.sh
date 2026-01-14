#!/bin/bash
set -e
cd "$(dirname "$0")/.."

# Only install once
if [ -f /opt/cuckoo3/.installed ]; then
  echo -e "\n\nCuckoo3 already installed, skipping."
  exit 0
fi

sudo bash infra/cuckoo3/install.sh
sudo touch /opt/cuckoo3/.installed
