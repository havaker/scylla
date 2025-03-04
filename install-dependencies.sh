#!/bin/bash -e
#
# This file is open source software, licensed to you under the terms
# of the Apache License, Version 2.0 (the "License").  See the NOTICE file
# distributed with this work for additional information regarding copyright
# ownership.  You may not use this file except in compliance with the License.
#
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

# os-release may be missing in container environment by default.
if [ -f "/etc/os-release" ]; then
    . /etc/os-release
elif [ -f "/etc/arch-release" ]; then
    export ID=arch
else
    echo "/etc/os-release missing."
    exit 1
fi

debian_base_packages=(
    clang
    gdb
    liblua5.3-dev
    python3-aiohttp
    python3-pyparsing
    python3-colorama
    python3-tabulate
    libsnappy-dev
    libjsoncpp-dev
    rapidjson-dev
    scylla-libthrift010-dev
    scylla-antlr35-c++-dev
    thrift-compiler
    git
    pigz
    libunistring-dev
    libzstd-dev
)

fedora_packages=(
    clang
    gdb
    lua-devel
    yaml-cpp-devel
    thrift-devel
    antlr3-tool
    antlr3-C++-devel
    jsoncpp-devel
    rapidjson-devel
    snappy-devel
    systemd-devel
    git
    python
    sudo
    java-1.8.0-openjdk-headless
    java-1.8.0-openjdk-devel
    ant
    ant-junit
    maven
    patchelf
    python3
    python3-aiohttp
    python3-pip
    python3-magic
    python3-colorama
    python3-tabulate
    python3-boto3
    python3-pytest
    python3-pytest-asyncio
    python3-redis
    dnf-utils
    pigz
    net-tools
    tar
    gzip
    gawk
    util-linux
    ethtool
    hwloc
    glibc-langpack-en
    xxhash-devel
    makeself
    libzstd-static libzstd-devel
    rpm-build
    devscripts
    debhelper
    fakeroot
    file
    dpkg-dev
    curl
    rust
    cargo
)

# lld is not available on s390x, see
# https://src.fedoraproject.org/rpms/lld/c/aa6e69df60747496f8f22121ae8cc605c9d3498a?branch=rawhide
if [ "$(uname -m)" != "s390x" ]; then
    fedora_packages+=(lld)
fi

fedora_python3_packages=(
    python3-pyyaml
    python3-urwid
    python3-pyparsing
    python3-requests
    python3-pyudev
    python3-setuptools
    python3-psutil
    python3-distro
    python3-click
    python3-six
)

pip_packages=(
    scylla-driver
    geomet
    traceback-with-variables
    scylla-api-client
)

centos_packages=(
    gdb
    yaml-cpp-devel
    thrift-devel
    scylla-antlr35-tool
    scylla-antlr35-C++-devel
    jsoncpp-devel snappy-devel
    rapidjson-devel
    scylla-boost163-static
    scylla-python34-pyparsing20
    systemd-devel
    pigz
)

# 1) glibc 2.30-3 has sys/sdt.h (systemtap include)
#    some old containers may contain glibc older,
#    so enforce update on that one.
# 2) if problems with signatures, ensure having fresh
#    archlinux-keyring: pacman -Sy archlinux-keyring && pacman -Syyu
# 3) aur installations require having sudo and being
#    a sudoer. makepkg does not work otherwise.
#
# aur: antlr3, antlr3-cpp-headers-git
arch_packages=(
    gdb
    base-devel
    filesystem
    git
    glibc
    jsoncpp
    lua
    python-pyparsing
    python3
    rapidjson
    snappy
    thrift
)

NODE_EXPORTER_VERSION=1.0.1
declare -A NODE_EXPORTER_CHECKSUM=(
    ["x86_64"]=3369b76cd2b0ba678b6d618deab320e565c3d93ccb5c2a0d5db51a53857768ae
    ["aarch64"]=017514906922fcc4b7d727655690787faed0562bc7a17aa9f72b0651cb1b47fb
    ["s390x"]=2f22d1ce18969017fb32dbd285a264adf3da6252eec05f03f105cf638ec0bb06
)
declare -A NODE_EXPORTER_ARCH=(
    ["x86_64"]=amd64
    ["aarch64"]=arm64
    ["s390x"]=s390x
)
NODE_EXPORTER_DIR=/opt/scylladb/dependencies

node_exporter_filename() {
    echo "node_exporter-$NODE_EXPORTER_VERSION.linux-${NODE_EXPORTER_ARCH["$(arch)"]}.tar.gz"
}

node_exporter_fullpath() {
    echo "$NODE_EXPORTER_DIR/$(node_exporter_filename)"
}

node_exporter_checksum() {
    sha256sum "$(node_exporter_fullpath)" | while read -r sum _; do [[ "$sum" == "${NODE_EXPORTER_CHECKSUM["$(arch)"]}" ]]; done
}

node_exporter_url() {
    echo "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/$(node_exporter_filename)"
}

WASMTIME_VERSION=0.29.0
WASMTIME_DIR=/opt/scylladb/dependencies
declare -A WASMTIME_CHECKSUM=(
    ["x86_64"]=e94a9a768270e86e7f7eac1a68575bb1f287702822e83b14c3b04bf7e865a84c
    ["aarch64"]=36a257aef36f5a0cabc8ce414e31ccede9c16ca996d6b07cb440a32aaa263164
)

wasmtime_filename() {
    echo "wasmtime-v$WASMTIME_VERSION-$(arch)-linux-c-api.tar.xz"
}

wasmtime_fullpath() {
    echo "$WASMTIME_DIR/$(wasmtime_filename)"
}

wasmtime_checksum() {
    sha256sum "$(wasmtime_fullpath)" | while read -r sum _; do [[ "$sum" == "${WASMTIME_CHECKSUM["$(arch)"]}" ]]; done
}

wasmtime_url() {
    echo "https://github.com/bytecodealliance/wasmtime/releases/download/v$WASMTIME_VERSION/$(wasmtime_filename)"
}

print_usage() {
    echo "Usage: install-dependencies.sh [OPTION]..."
    echo ""
    echo "  --print-python3-runtime-packages Print required python3 packages for Scylla"
    echo "  --print-pip-runtime-packages Print required pip packages for Scylla"
    echo "  --print-node-exporter-filename Print node_exporter filename"
    exit 1
}

PRINT_PYTHON3=false
PRINT_PIP=false
PRINT_NODE_EXPORTER=false
while [ $# -gt 0 ]; do
    case "$1" in
        "--print-python3-runtime-packages")
            PRINT_PYTHON3=true
            shift 1
            ;;
        "--print-pip-runtime-packages")
            PRINT_PIP=true
            shift 1
            ;;
        "--print-node-exporter-filename")
            PRINT_NODE_EXPORTER=true
            shift 1
            ;;
         *)
            print_usage
            ;;
    esac
done

if $PRINT_PYTHON3; then
    if [ "$ID" != "fedora" ]; then
        echo "Unsupported Distribution: $ID"
        exit 1
    fi
    echo "${fedora_python3_packages[@]}"
    exit 0
fi

if $PRINT_PIP; then
    echo "${pip_packages[@]}"
    exit 0
fi

if $PRINT_NODE_EXPORTER; then
    node_exporter_fullpath
    exit 0
fi

./seastar/install-dependencies.sh
./tools/jmx/install-dependencies.sh
./tools/java/install-dependencies.sh

if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
    apt-get -y install "${debian_base_packages[@]}"
    if [ "$VERSION_ID" = "8" ]; then
        apt-get -y install libsystemd-dev scylla-antlr35 libyaml-cpp-dev
    elif [ "$VERSION_ID" = "14.04" ]; then
        apt-get -y install scylla-antlr35 libyaml-cpp-dev
    elif [ "$VERSION_ID" = "9" ]; then
        apt-get -y install libsystemd-dev antlr3 scylla-libyaml-cpp05-dev
    else
        apt-get -y install libsystemd-dev antlr3 libyaml-cpp-dev
    fi
    echo -e "Configure example:\n\t./configure.py --enable-dpdk --mode=release --static-thrift --static-boost --static-yaml-cpp --compiler=/opt/scylladb/bin/g++-7 --cflags=\"-I/opt/scylladb/include -L/opt/scylladb/lib/x86-linux-gnu/\" --ldflags=\"-Wl,-rpath=/opt/scylladb/lib\""
elif [ "$ID" = "fedora" ]; then
    if rpm -q --quiet yum-utils; then
        echo
        echo "This script will install dnf-utils package, witch will conflict with currently installed package: yum-utils"
        echo "Please remove the package and try to run this script again."
        exit 1
    fi
    dnf install -y "${fedora_packages[@]}" "${fedora_python3_packages[@]}"
    pip3 install "geomet<0.3,>=0.1"
    # Disable C extensions
    pip3 install scylla-driver --install-option="--no-murmur3" --install-option="--no-libev" --install-option="--no-cython"
    pip3 install traceback-with-variables
    pip3 install scylla-api-client

    cargo install cxxbridge-cmd --root /usr/local
    if [ -f "$(node_exporter_fullpath)" ] && node_exporter_checksum; then
        echo "$(node_exporter_filename) already exists, skipping download"
    else
        mkdir -p "$NODE_EXPORTER_DIR"
        curl -fSL -o "$(node_exporter_fullpath)" "$(node_exporter_url)"
        if ! node_exporter_checksum; then
            echo "$(node_exporter_filename) download failed"
            exit 1
        fi
    fi
    if [ -f "$(wasmtime_fullpath)" ] && wasmtime_checksum; then
        echo "$(wasmtime_filename) already exists, skipping download"
    else
        mkdir -p "$WASMTIME_DIR"
        if curl --retry 5 -fSL -o "$(wasmtime_fullpath)" "$(wasmtime_url)"; then
            if ! wasmtime_checksum; then
                echo "$(wasmtime_filename) download failed, skipping"
            else
                ( cd $WASMTIME_DIR; tar xvf $(wasmtime_filename) )
                wasmtime_unpacked=$(basename $(wasmtime_filename) .tar.xz)
                cp $WASMTIME_DIR/$wasmtime_unpacked/lib/libwasmtime.a /usr/lib64/
                cp -r $WASMTIME_DIR/$wasmtime_unpacked/include/was{m.h,i.h,mtime,mtime.h} /usr/local/include/
            fi
        else
            echo "$(wasmtime_url) is unreachable, skipping"
        fi
    fi
elif [ "$ID" = "centos" ]; then
    dnf install -y "${centos_packages[@]}"
    echo -e "Configure example:\n\tpython3.4 ./configure.py --enable-dpdk --mode=release --static-boost --compiler=/opt/scylladb/bin/g++-7.3 --python python3.4 --ldflag=-Wl,-rpath=/opt/scylladb/lib64 --cflags=-I/opt/scylladb/include --with-antlr3=/opt/scylladb/bin/antlr3"
elif [ "$ID" == "arch" ]; then
    # main
    if [ "$EUID" -eq "0" ]; then
        pacman -Sy --needed --noconfirm "${arch_packages[@]}"
    else
        echo "scylla: You now ran $0 as non-root. Run it again as root to execute the pacman part of the installation." 1>&2
    fi

    # aur
    if [ ! -x /usr/bin/antlr3 ]; then
        echo "Installing aur/antlr3..."
        if (( EUID == 0 )); then
            echo "You now ran $0 as root. This can only update dependencies with pacman. Please run again it as non-root to complete the AUR part of the installation." 1>&2
            exit 1
        fi
        TEMP=$(mktemp -d)
        pushd "$TEMP" > /dev/null || exit 1
        git clone --depth 1 https://aur.archlinux.org/antlr3.git
        cd antlr3 || exit 1
        makepkg -si
        popd > /dev/null || exit 1
    fi
    if [ ! -f /usr/include/antlr3.hpp ]; then
        echo "Installing aur/antlr3-cpp-headers-git..."
        if (( EUID == 0 )); then
            echo "You now ran $0 as root. This can only update dependencies with pacman. Please run again it as non-root to complete the AUR part of the installation." 1>&2
            exit 1
        fi
        TEMP=$(mktemp -d)
        pushd "$TEMP" > /dev/null || exit 1
        git clone --depth 1 https://aur.archlinux.org/antlr3-cpp-headers-git.git
        cd antlr3-cpp-headers-git || exit 1
        makepkg -si
        popd > /dev/null || exit 1
    fi
    echo -e "Configure example:\n\t./configure.py\n\tninja release"
fi
