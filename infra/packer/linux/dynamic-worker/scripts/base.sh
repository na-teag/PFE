#!/bin/bash
set -eux

apt update
apt upgrade -y

apt install -y \
  build-essential \
  git \
  curl \
  wget \
  cmake \
  python3 \
  python3-pip \
  linux-headers-$(uname -r)
