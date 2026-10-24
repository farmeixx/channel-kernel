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
ARM32_DIR="${TOOLCHAINS}/arm32_gnueabihf"

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
          lz4 zstd device-tree-compiler
          gcc-arm-linux-gnueabihf)

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
    # arm32 toolchain for the compat vDSO: clang resolves its external
    # assembler and linker through the --prefix directory, and the plain
    # "as"/"ld" names found there win over the triple-prefixed ones. The
    # apt armhf toolchain installs alongside the x86 host binutils in
    # /usr/bin, so the host as/ld would shadow the arm32 ones. A private
    # directory with symlinks removes that clash: the tree then derives
    # --prefix from CROSS_COMPILE_ARM32 and always hits arm32 tools.
    if [ ! -x "${ARM32_DIR}/arm-linux-gnueabihf-as" ]; then
        info "Setting up the arm32 compat vDSO toolchain"
        command -v arm-linux-gnueabihf-as >/dev/null \
            || die "arm32 toolchain missing (gcc-arm-linux-gnueabihf)"
        mkdir -p "${ARM32_DIR}"
        for t in as ld ar nm objcopy objdump readelf strip gcc; do
            if command -v "arm-linux-gnueabihf-${t}" >/dev/null 2>&1; then
                ln -sf "$(command -v "arm-linux-gnueabihf-${t}")" \
                    "${ARM32_DIR}/arm-linux-gnueabihf-${t}"
            fi
        done
        ln -sf "$(command -v arm-linux-gnueabihf-as)" "${ARM32_DIR}/as"
        ln -sf "$(command -v arm-linux-gnueabihf-ld)" "${ARM32_DIR}/ld"
    fi
    # host tools (fixdep etc.) are linked by the system gcc, whose ld is
    # resolved through PATH. Keep /usr/bin ahead so the host link does not
    # pick the 2021-era unprefixed ld bundled with proton clang, which
    # cannot read the RELR sections of modern glibc. The Linaro dir comes
    # BEFORE proton so that the tree's toolchain auto-detection
    # (which $(CROSS_COMPILE)elfedit) lands on the real aarch64 GNU
    # assembler for -no-integrated-as instead of proton's x86-only one.
    export PATH="/usr/bin:${GCC_DIR}/bin:${CLANG_DIR}/bin:${PATH}"
    # no LD_LIBRARY_PATH on purpose: proton clang is self-contained and
    # exporting its lib dir globally would shadow the system libraries
    # used by /usr/bin/ld (it loaded the old proton libctf and crashed
    # with an ABI version mismatch instead)
}

# ---------------------------------------------------------------------------
#  PATCHES - Droidspaces Step 3 (non-GKI), applied at build time so the
#  kernel repository history stays untouched. Source of truth:
#  https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md
# ---------------------------------------------------------------------------
DROIDSPACES_PATCHES="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI"
PATCH_DIR="${ROOT}/patches"

apply_droidspaces_patches(){
    info "Applying Droidspaces non-GKI patches (build-time only)"
    mkdir -p "${PATCH_DIR}"

    # fix 1: avoid kernel panic in xt_qtaguid (unsafe dev_get_stats usage
    # on inactive interfaces). Attempted only when the module actually
    # exists in the tree; this Motorola sdm632 tree ships quota2 instead
    # of xt_qtaguid, so the target file is normally absent and the fix
    # is skipped as not applicable
    local p1="${PATCH_DIR}/01.fix_kernel_panic_in_xt_qtaguid.patch"
    if [ -f "${KERNEL_DIR}/net/netfilter/xt_qtaguid.c" ]; then
        curl -fsSL --retry 3 -o "${p1}" \
            "${DROIDSPACES_PATCHES}/01.fix_kernel_panic_in_xt_qtaguid.patch" \
            || { rm -f "${p1}"; die "failed to download fix 1 (xt_qtaguid)"; }
        ( cd "${KERNEL_DIR}" && git apply "${p1}" ) \
            || { rm -f "${p1}"; die "fix 1 (xt_qtaguid) does not apply"; }
        info "xt_qtaguid panic fix applied"
    else
        info "xt_qtaguid is not present in this tree (quota2 is used) -> fix 1 skipped"
    fi

    # fix 2: restore cgroup file prefix handling (needed by Droidspaces/LXC:
    # when cgroupfs is mounted with noprefix, control files regain their
    # <subsys>.<name> aliases). The upstream patch targets
    # kernel/cgroup/cgroup.c while this Motorola tree keeps the code
    # flattened in kernel/cgroup.c, so the path inside the patch is
    # adjusted before applying
    local p2="${PATCH_DIR}/02.fix_restore_cgroup_file_prefix_handling.patch"
    curl -fsSL --retry 3 -o "${p2}" \
        "${DROIDSPACES_PATCHES}/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" \
        || { rm -f "${p2}"; die "failed to download fix 2 (cgroup prefix)"; }
    sed -i 's#kernel/cgroup/cgroup.c#kernel/cgroup.c#g' "${p2}"
    if grep -q "kernfs_create_link(cgrp->kn, name, kn)" "${KERNEL_DIR}/kernel/cgroup.c"; then
        info "cgroup prefix fix already present -> skipped"
    else
        ( cd "${KERNEL_DIR}" && git apply "${p2}" ) \
            || { rm -f "${p2}"; die "fix 2 (cgroup prefix) does not apply"; }
        info "cgroup file prefix fix applied"
    fi

    rm -f "${PATCH_DIR}"/0*.patch
}

# ---------------------------------------------------------------------------
#  BUILD OPTIONS - the fixed make arguments for this arm64/4.9 tree
# ---------------------------------------------------------------------------
BUILD_OPTIONS=(
    -j"$(nproc)"
    ARCH=arm64
    # full path so the runner's own /usr/bin/clang never shadows proton,
    # no matter how PATH is ordered for the host tools
    CC="${CLANG_DIR}/bin/clang"
    CROSS_COMPILE=aarch64-linux-gnu-
    CLANG_TRIPLE=aarch64-linux-gnu-
    # the Motorola arm64 Makefile demands an arm32 cross prefix for the
    # compat vDSO (CONFIG_COMPAT_VDSO in the channel defconfig). An
    # absolute path to the private arm32 dir keeps the tree from deriving
    # its assembler --prefix from /usr/bin, where the x86 host tools would
    # win; the symlinks point to the real apt arm32 toolchain
    CROSS_COMPILE_ARM32="${ARM32_DIR}/arm-linux-gnueabihf-"
)

# ---------------------------------------------------------------------------
#  RUN - defconfig, build the image, collect the artifact
# ---------------------------------------------------------------------------
install_deps
clone_kernel
apply_droidspaces_patches
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
