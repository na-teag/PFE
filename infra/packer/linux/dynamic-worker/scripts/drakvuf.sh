#!/bin/bash
set -eux

apt install -y \
  libboost-all-dev \
  libglib2.0-dev \
  libjson-c-dev

git clone https://github.com/tklengyel/drakvuf.git /opt/drakvuf
cd /opt/drakvuf
mkdir build && cd build
cmake -DENABLE_KVM=ON ..
make -j$(nproc)
make install
