#!/bin/bash
set -eux

apt install -y \
  libvirt-dev \
  libglib2.0-dev \
  libjson-c-dev \
  libtool \
  autoconf \
  automake

git clone https://github.com/libvmi/libvmi.git /opt/libvmi
cd /opt/libvmi
git submodule update --init --recursive
autoreconf -vif
./configure --enable-kvm
make -j$(nproc)
make install
ldconfig
