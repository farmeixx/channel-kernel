#!/bin/bash
#
# build.sh - channel kernel build
#
# Builds the Motorola sdm632 "channel" kernel for the lineage-17.1 branch
# with llvm clang. The final artifact is Image.gz-dtb: the compressed
# kernel image with the channel device tree binary appended by
# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE.
#
# Toolchain follows the official Droidspaces 4.9 kernel guide:
#   https://github.com/ravindu644/Android-Kernel-Tutorials
# Kernel 4.9 predates LLVM=1, so clang compiles the C code while a real
# GCC cross compiler (Linaro 7.5 aarch64) still drives as/linking.
#
set -euo pipefail

# ---------------------------------------------------------------------------
#  SETTINGS - the part you may need to touch
# ---------------------------------------------------------------------------
DEFCONFIG="channel_defconfig"
KERNEL_IMAGE="Image.gz-dtb"

KERNEL_URL="https://github.com/farmeixx/android_kernel_motorola_sdm632.git"
KERNEL_BRANCH="lineage-17.1"

CLANG_URL="https://github.com/ravindu644/proton-12.git"
GCC_URL="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/linaro-aarch64-7.5.tar.xz"

export KBUILD_BUILD_USER="@farmeixx"
export KBUILD_BUILD_HOST="channel-kernel"

# ---------------------------------------------------------------------------
#  PATHS - everything happens under this checkout; toolchains land in ~
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${ROOT}/kernel-source"
OUT="${ROOT}/output"
TOOLCHAINS="${HOME}/toolchains"
CLANG_DIR="${TOOLCHAINS}/proton-12"
GCC_DIR="${TOOLCHAINS}/linaro-aarch64-7.5"

cd "${ROOT}"

# helpers: one-line logger and abort, used across every section below
info(){ echo -e "\n[INFO]: $*\n"; }
die(){  echo -e "\n[ERROR]: $*\n" >&2; exit 1; }

# ---------------------------------------------------------------------------
#  DEPENDENCIES - system packages the 4.9 Kbuild needs (host tools)
# ---------------------------------------------------------------------------
DEB_PKGS=(build-essential bc bison flex pkg-config git curl tar xz-utils
          zip unzip cpio rsync kmod perl python3 python-is-python3
          libssl-dev libelf-dev pahole libncurses-dev zlib1g-dev libyaml-dev
          lz4 zstd device-tree-compiler)

install_deps(){
    info "Installing kernel build dependencies"
    sudo apt-get update
    sudo apt-get install -y "${DEB_PKGS[@]}" || die "apt-get failed"
}

# ---------------------------------------------------------------------------
#  SOURCES - clone the kernel tree, defconfig and flags live on that branch
# ---------------------------------------------------------------------------
clone_kernel(){
    [ -d "${KERNEL_DIR}" ] && { info "kernel source already present"; return 0; }
    info "Cloning ${KERNEL_URL} (${KERNEL_BRANCH}, depth=1)"
    git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_URL}" "${KERNEL_DIR}" \
        || { rm -rf "${KERNEL_DIR}"; die "kernel clone failed"; }
}

# ---------------------------------------------------------------------------
#  TOOLCHAINS - download once or reuse; clang compiles, gcc links/assembles
# ---------------------------------------------------------------------------
fetch_toolchains(){
    if [ ! -x "${CLANG_DIR}/bin/clang" ]; then
        info "Fetching Proton Clang 12"
        git clone --depth=1 "${CLANG_URL}" "${CLANG_DIR}" \
            || { rm -rf "${CLANG_DIR}"; die "clang fetch failed"; }
    fi
    if [ ! -x "${GCC_DIR}/bin/aarch64-linux-gnu-ld" ]; then
        info "Fetching Linaro GCC 7.5 aarch64 cross toolchain"
        mkdir -p "${GCC_DIR}"
        curl -fsSL --retry 3 -o /tmp/linaro.tar.xz "${GCC_URL}" || die "gcc download failed"
        tar -xf /tmp/linaro.tar.xz -C "${GCC_DIR}" --strip-components=1
        rm -f /tmp/linaro.tar.xz
    fi
    export PATH="${CLANG_DIR}/bin:${GCC_DIR}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CLANG_DIR}/lib:${CLANG_DIR}/lib64:${LD_LIBRARY_PATH:-}"
}

# ---------------------------------------------------------------------------
#  BUILD OPTIONS - the fixed make arguments for this arm64/4.9 tree
# ---------------------------------------------------------------------------
BUILD_OPTIONS=(
    -j"$(nproc)"
    ARCH=arm64
    CC=clang
    CROSS_COMPILE=aarch64-linux-gnu-
    CLANG_TRIPLE=aarch64-linux-gnu-
)

# ---------------------------------------------------------------------------
#  RUN - defconfig, build the image, collect the artifact
# ---------------------------------------------------------------------------
install_deps
clone_kernel
fetch_toolchains

cd "${KERNEL_DIR}"
info "Configuring ${DEFCONFIG}"
make "${BUILD_OPTIONS[@]}" "O=${KERNEL_DIR}/out" "${DEFCONFIG}" || die "defconfig failed"

info "Building ${KERNEL_IMAGE}"
make "${BUILD_OPTIONS[@]}" "O=${KERNEL_DIR}/out" "${KERNEL_IMAGE}" || die "kernel build failed"

# final artifact: Image.gz-dtb (kernel image that already carries the dtb)
mkdir -p "${OUT}"
cp "out/arch/arm64/boot/${KERNEL_IMAGE}" "${OUT}/"

# informational only: shows the Droidspaces flags as resolved by the build
info "Droidspaces flags resolved in out/.config:"
grep -E '^CONFIG_(SYSVIPC|POSIX_MQUEUE|NAMESPACES|IPC_NS|PID_NS|UTS_NS|USER_NS|MEMCG|MEMCG_SWAP|CGROUP_DEVICE|CGROUP_PIDS|CGROUP_NET_PRIO|DEVTMPFS|OVERLAY_FS|VETH|NF_TABLES|XT_MATCH_ADDRTYPE|IP6_NF_NAT|MACVLAN|IP_SET|XT_SET)=y' "out/.config" || true

info "Done -> ${OUT}/${KERNEL_IMAGE}"
