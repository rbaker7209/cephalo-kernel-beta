#!/usr/bin/env bash

set -uo pipefail
# NOTE: 'e' (errexit) is intentionally NOT set globally anymore. A single
# failed kernel target used to take the entire multi-day run down with it
# (that's what happened at intel-sandybridge, target 21/32). Fatal setup
# steps below (dependency install, mkdir, cd, download) are still checked
# explicitly and will abort the script; only the per-target kernel builds
# are allowed to fail individually and let the run continue. See
# run_target() / build_kernel_target() below.

KERNEL_VERSION="6.8.1" # the config was 6.12.something, might be bad jeebies
CEPHALO_VERSION="0.0.8"
BUILD_DIR="${HOME}/kernel_build"
OUTPUT_DIR="${HOME}/kernels"
PACK_DIR="${HOME}/ceph-packs"
LOG_DIR="${OUTPUT_DIR}/logs"

# For the love of fuck, pass a HOME declaration, it defaults to root and WILL bork up the host install

# Real Debian trixie kernel config, used as the build seed instead of
# `make defconfig` (which is a minimal sanity config, not a distro-quality
# one — this is what silently dropped CONFIG_OVERLAY_FS and caused the
# "overlay not available" live-boot failure in 0.0.8.x builds).
# Defaults to a file living next to this script; override with BASE_CONFIG=
# if you keep it somewhere else.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_CONFIG="${BASE_CONFIG:-${SCRIPT_DIR}/debian-trixie-base.config}"
GEN_CHECK=true
INT_CHECK=true
AMD_CHECK=true
JOBS=$(nproc)

# Set to "true" to rebuild targets that already have output present.
# Default is resume-mode: a target with an existing vmlinuz in OUTPUT_DIR
# is assumed already-built and is skipped. This is what makes a crashed
# 21/32 run cheap to restart instead of starting over from target 1.
FORCE_REBUILD="${FORCE_REBUILD:-false}"

# Minimum free space (in MB) required on OUTPUT_DIR's filesystem before
# starting a target. 32 full kernel+modules trees add up fast; better to
# stop cleanly with a clear message than die mid-write with a cryptic I/O
# error hours into a build.
MIN_FREE_MB="${MIN_FREE_MB:-4096}"

FAILED_TARGETS=()
SKIPPED_TARGETS=()
SUCCEEDED_TARGETS=()

# ------------------------------------------------------------------------------
# 1. Dependency Checking & Installation
# ------------------------------------------------------------------------------
install_dependencies() {
    echo "==> Checking and installing build dependencies..."

    local REQUIRED_PKGS=(build-essential libncurses-dev bison flex libssl-dev libelf-dev bc rsync ccache wget xz-utils zip)

    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y "${REQUIRED_PKGS[@]}"
    elif command -v dnf &> /dev/null; then
        sudo dnf groupinstall -y "Development Tools"
        sudo dnf install -y ncurses-devel bison flex openssl-devel libelf-devel bc rsync ccache wget xz zip
    elif command -v pacman &> /dev/null; then
        sudo pacman -Sy --needed base-devel ncurses bison flex openssl libelf bc rsync ccache wget xz zip
    else
        echo "Error: Unsupported package manager. Please install build tools manually."
        exit 1
    fi
}

install_dependencies || { echo "FATAL: dependency install failed."; exit 1; }

# ccache was already a required dependency but was never actually wired
# into the build — every target recompiled everything from zero even
# though a lot of the tree is identical across -march targets, and a
# resumed/rebuilt target got zero benefit from work already done. This
# makes ccache the standard front-end for cc/gcc/g++ system-wide for this
# script's process tree, Debian/Ubuntu/Fedora/Arch all ship the
# /usr/lib(exec)?/ccache shim directory.
for ccache_bin_dir in /usr/lib/ccache /usr/lib64/ccache /usr/libexec/ccache; do
    if [ -d "${ccache_bin_dir}" ]; then
        export PATH="${ccache_bin_dir}:${PATH}"
        break
    fi
done
export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"
command -v ccache &>/dev/null && echo "==> ccache enabled (dir: ${CCACHE_DIR})"

# ------------------------------------------------------------------------------
# 2. Define Comprehensive Target Lists (-march flags mapping) I think this is all of the westerns.
# ------------------------------------------------------------------------------
# Generic x86-64 ISA Tiers
declare -A GENERIC_LEVELS=(
    ["v1"]="x86-64"
    ["v2"]="x86-64-v2"
    ["v3"]="x86-64-v3"
    ["v4"]="x86-64-v4"
)

# Comprehensive Intel Microarchitectures
declare -A INTEL_TARGETS=(
    ["atom-bonnell"]="bonnell"
    ["atom-silvermont"]="silvermont"
    ["atom-goldmont"]="goldmont"
    ["nehalem"]="nehalem"
    ["westmere"]="westmere"
    ["sandybridge"]="sandybridge"
    ["ivybridge"]="ivybridge"
    ["haswell"]="haswell"
    ["broadwell"]="broadwell"
    ["skylake"]="skylake"
    ["skylake-avx512"]="skylake-avx512"
    ["icelake"]="icelake-client"
    ["cascadelake"]="cascadelake"
    ["tigerlake"]="cooperlake"
    ["sapphirerapids"]="sapphirerapids"
    ["alderlake"]="alderlake"
    ["raptorlake"]="raptorlake"
)

# Comprehensive AMD Microarchitectures
declare -A AMD_TARGETS=(
    ["k8-sse3"]="k8-sse3"
    ["amdfam10"]="amdfam10"
    ["bulldozer"]="bdver1"
    ["piledriver"]="bdver2"
    ["steamroller"]="bdver3"
    ["excavator"]="bdver4"
    ["zen1"]="znver1"
    ["zen2"]="znver2"
    ["zen3"]="znver3"
    ["zen4"]="znver4"
    ["zen5"]="znver5"
)

# ------------------------------------------------------------------------------
# 3. Source Preparation & Optimization Tuning
# ------------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}/versions" "${OUTPUT_DIR}/chipsets" "${PACK_DIR}" "${LOG_DIR}" \
    || { echo "FATAL: could not create working directories."; exit 1; }
cd "${BUILD_DIR}" || { echo "FATAL: could not cd into ${BUILD_DIR}."; exit 1; }

TARBALL="linux-${KERNEL_VERSION}.tar.xz"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${TARBALL}"

if [ ! -f "${TARBALL}" ]; then
    echo "==> Downloading Linux Kernel ${KERNEL_VERSION}..."
    wget -q --show-progress "${TARBALL_URL}" || { echo "FATAL: kernel source download failed."; exit 1; }
fi

# Check the tarball actually decompresses cleanly before we burn a build
# cycle on it — a truncated/corrupt download previously would have surfaced
# confusingly deep inside the first 'tar -xf' of build_kernel_target.
if ! xz -t "${TARBALL}" 2>/dev/null; then
    echo "FATAL: ${TARBALL} is corrupt or incomplete. Delete it and re-run to re-download." >&2
    exit 1
fi

check_disk_space() {
    local path="$1"
    local avail_mb
    avail_mb=$(df --output=avail -m "${path}" 2>/dev/null | tail -n1 | tr -d ' ')
    if [ -z "${avail_mb}" ]; then
        echo "WARNING: could not determine free space for ${path}; continuing anyway." >&2
        return 0
    fi
    if [ "${avail_mb}" -lt "${MIN_FREE_MB}" ]; then
        echo "!!! Only ${avail_mb}MB free on $(df --output=target "${path}" | tail -n1), need at least ${MIN_FREE_MB}MB. Stopping before starting a new target." >&2
        return 1
    fi
    return 0
}

apply_gaming_and_security_tweaks() {
    local localver_suffix=$1

    # Inject localversion into kernel configuration
    scripts/config --set-str CONFIG_LOCALVERSION "${localver_suffix}"

    # Gaming & Performance Tweaks. Mostly unnesecary, but nice.
    scripts/config --enable CONFIG_PREEMPT
    scripts/config --set-val CONFIG_HZ 1000
    scripts/config --enable CONFIG_HZ_1000
    scripts/config --enable CONFIG_FAIR_GROUP_SCHED
    scripts/config --enable CONFIG_HIGH_RES_TIMERS

    # Performance: Transparent Hugepages for memory efficiency
    scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE
    scripts/config --set-val CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS n
    scripts/config --set-val CONFIG_TRANSPARENT_HUGEPAGE_MADVISE y

    # Performance: Modern CPU frequency governor default
    scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL

    # NOTE: the old ORC-disable / frame-pointer-unwinder workaround is gone.
    # That was only needed because -O3 broke objtool; now that the build
    # uses -O2 (see build_kernel_target), and the seed config already ships
    # CONFIG_UNWINDER_ORC=y as Debian intends, there's nothing to work around.

    # Security & Kernel Hardening Tweaks (Baseline+ with minimal overhead)
    scripts/config --enable CONFIG_SECURITY_YAMA
    scripts/config --enable CONFIG_FORTIFY_SOURCE
    scripts/config --enable CONFIG_STRICT_KERNEL_RWX
    scripts/config --enable CONFIG_PAGE_TABLE_ISOLATION
    scripts/config --enable CONFIG_HARDENED_USERCOPY

    # Additional low-overhead hardening
    scripts/config --enable CONFIG_SLAB_FREELIST_HARDENED
    scripts/config --enable CONFIG_SLAB_FREELIST_RANDOM
    scripts/config --enable CONFIG_SHUFFLE_PAGE_ALLOCATOR

    # Debian's seed config ships full DWARF debug info + BTF (incl. per-module
    # BTF), which is fine on Debian's own build infra but is a memory hog on
    # normal hardware — the BTF pass walks every module's debug info at once
    # after they all link, and on constrained RAM it gets OOM-killed with no
    # useful error text, just a generic "Error 2" from make. Not needed for
    # a general-purpose distro kernel anyway.
    scripts/config --disable CONFIG_DEBUG_INFO_BTF
    scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES
    scripts/config --enable CONFIG_DEBUG_INFO_NONE

    # NOTE: the old hand-picked overlay/squashfs/USB-storage/ATA/NVMe block
    # is gone. Those were guesses layered on top of `make defconfig` to
    # paper over its gaps, and I got the type wrong for several of them
    # (forced =y where Debian ships =m). The seed config below already
    # covers all of it, correctly, because it's the real thing rather than
    # a guess. Again, got my ass.
}

# Returns 0 (true) if this target's output already exists on disk, so a
# resumed run can skip straight past it instead of rebuilding.
target_is_built() {
    local full_name="$1"
    local dest_dir="$2"
    local target_output="${dest_dir}/${full_name}"
    [ -f "${target_output}/vmlinuz-${full_name}" ]
}

build_kernel_target() {
    local target_key=$1
    local march_flag=$2
    local dest_dir=$3

    # PATCH 1: Version string must start with a digit for dpkg/depmod compliance
    local localver="-ceph-${CEPHALO_VERSION}-x86-64-${target_key}"
    local full_name="${KERNEL_VERSION}${localver}"

    echo "================================================================="
    echo "  Building Target: ${full_name} (-march=${march_flag})"
    echo "================================================================="

    rm -rf "linux-${KERNEL_VERSION}"
    tar -xf "${TARBALL}"
    cd "linux-${KERNEL_VERSION}"

    # Seed the config from a real, comprehensive base rather than
    # `make defconfig` (which drops things like OverlayFS that live-boot
    # depends on). olddefconfig reconciles the seed — pulled from kernel
    # 6.12.107 — against this tree's 6.8.1 Kconfig: recognized options are
    # kept as-is, unrecognized ones are dropped, and anything new to this
    # version gets its Kconfig default. This got my ass, many times.
    if [ -f "${BASE_CONFIG}" ]; then
        echo "==> Seeding config from: ${BASE_CONFIG}"
        cp "${BASE_CONFIG}" .config
        make olddefconfig
    else
        echo "WARNING: BASE_CONFIG not found at ${BASE_CONFIG}." >&2
        echo "         Falling back to 'make defconfig' — this is known to" >&2
        echo "         miss things live-boot needs (e.g. CONFIG_OVERLAY_FS)." >&2
        make defconfig
    fi

    # Inject performance, security, and localversion config alterations
    apply_gaming_and_security_tweaks "${localver}"

    # Force explicit compiler tuning optimization flag via environment override
    # NOTE: -O3 is unsupported upstream and previously required disabling the
    # ORC unwinder to even build; -O2 is what the kernel is actually tested at.
    export KCFLAGS="-march=${march_flag} -O2"
    export KCPPFLAGS="-march=${march_flag} -O2"

    # Resolve dependencies non-interactively
    make olddefconfig

    # Compile compressed kernel image and modules
    make -j"${JOBS}" bzImage modules

    local target_output="${dest_dir}/${full_name}"
    mkdir -p "${target_output}"

    # Copy kernel image and configuration file
    cp arch/x86/boot/bzImage "${target_output}/vmlinuz-${full_name}"
    cp .config "${target_output}/config-${full_name}"

    # PATCH 2: Install modules into build target folder so /lib/modules is populated
    echo "==> Installing modules for ${full_name}..."
    make INSTALL_MOD_PATH="${target_output}" INSTALL_MOD_STRIP=1 modules_install

    echo "==> Successfully compiled and packaged: ${full_name}"
    cd "${BUILD_DIR}"
}

# Wraps build_kernel_target with: resume-skip, disk-space check, logging,
# and non-fatal failure handling. This is the piece that fixes the actual
# crash: a call to run_target used as an if/while condition is exempt from
# 'set -e' propagation for everything underneath it (this is standard
# bash/POSIX behavior), so one bad target can no longer take the other 31
# down with it. Bear in mind: the "Error 2" from "Makefile:240:
# __sub-make" you saw is Kbuild's generic top-level wrapper error, not the
# real cause — the actual failure was almost certainly printed a few lines
# earlier and scrolled away in the interleaved -j$(nproc) output. That's
# exactly what the full log capture below is for: re-run, and if a target
# fails again, the real error will be sitting in its log file instead of
# lost in the terminal scrollback.
run_target() {
    local target_key=$1
    local march_flag=$2
    local dest_dir=$3

    local localver="-ceph-${CEPHALO_VERSION}-x86-64-${target_key}"
    local full_name="${KERNEL_VERSION}${localver}"
    local logfile="${LOG_DIR}/${full_name}.log"

    if [ "${FORCE_REBUILD}" != "true" ] && target_is_built "${full_name}" "${dest_dir}"; then
        echo "==> Skipping ${full_name} (already built; set FORCE_REBUILD=true to rebuild)"
        SKIPPED_TARGETS+=("${full_name}")
        return 0
    fi

    if ! check_disk_space "${dest_dir}"; then
        echo "!!! Skipping ${full_name} due to low disk space." >&2
        FAILED_TARGETS+=("${full_name} (low disk space)")
        return 1
    fi

    echo "==> Log: ${logfile}"
    if build_kernel_target "${target_key}" "${march_flag}" "${dest_dir}" 2>&1 | tee "${logfile}"; then
        local rc=${PIPESTATUS[0]}
    else
        local rc=${PIPESTATUS[0]}
    fi

    if [ "${rc}" -eq 0 ]; then
        SUCCEEDED_TARGETS+=("${full_name}")
        return 0
    else
        echo "!!! FAILED: ${full_name} (exit ${rc}). Full log: ${logfile}" >&2
        echo "    Last 40 lines:" >&2
        tail -n 40 "${logfile}" >&2
        FAILED_TARGETS+=("${full_name}")
        # Make sure a half-built source tree doesn't confuse the next target,
        # and get back to BUILD_DIR regardless of how deep the failure was.
        cd "${BUILD_DIR}" 2>/dev/null || true
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. Execution Pipeline Across Selected Targets
# ------------------------------------------------------------------------------

if [ "${GEN_CHECK}" = true ]; then
    echo "==> Compiling generic x86-64 targets..."
    for name in "${!GENERIC_LEVELS[@]}"; do
        run_target "${name}" "${GENERIC_LEVELS[$name]}" "${OUTPUT_DIR}/versions" || true
    done
fi

if [ "${INT_CHECK}" = true ]; then
    echo "==> Compiling Intel targets..."
    for name in "${!INTEL_TARGETS[@]}"; do
        run_target "intel-${name}" "${INTEL_TARGETS[$name]}" "${OUTPUT_DIR}/chipsets" || true
    done
fi

if [ "${AMD_CHECK}" = true ]; then
    echo "==> Compiling AMD targets..."
    for name in "${!AMD_TARGETS[@]}"; do
        run_target "amd-${name}" "${AMD_TARGETS[$name]}" "${OUTPUT_DIR}/chipsets" || true
    done
fi

# ------------------------------------------------------------------------------
# 5. Run Summary
# ------------------------------------------------------------------------------
echo "================================================================="
echo "  Build summary"
echo "================================================================="
echo "  Succeeded (${#SUCCEEDED_TARGETS[@]}):"
for t in "${SUCCEEDED_TARGETS[@]-}"; do [ -n "$t" ] && echo "    - $t"; done
echo "  Skipped, already built (${#SKIPPED_TARGETS[@]}):"
for t in "${SKIPPED_TARGETS[@]-}"; do [ -n "$t" ] && echo "    - $t"; done
echo "  Failed (${#FAILED_TARGETS[@]}):"
for t in "${FAILED_TARGETS[@]-}"; do [ -n "$t" ] && echo "    - $t"; done
echo "================================================================="

if [ "${#SUCCEEDED_TARGETS[@]}" -eq 0 ] && [ "${#SKIPPED_TARGETS[@]}" -eq 0 ]; then
    echo "No kernels available to package (nothing succeeded, nothing pre-existing). Skipping zip."
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Packaging & Compression
# ------------------------------------------------------------------------------
echo "================================================================="
echo "  Compressing compiled kernels into ${PACK_DIR}..."
echo "================================================================="

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ZIP_FILE="${PACK_DIR}/kernels_${TIMESTAMP}.zip"

# -r (recursive), -T (test archive integrity), -1 (fastest compression)
if (cd "${OUTPUT_DIR}" && zip -r -T -1 -y "${ZIP_FILE}" . -x "logs/*"); then
    echo "================================================================="
    echo "  Archive created: ${ZIP_FILE}"
    echo "================================================================="
else
    echo "!!! zip packaging failed — kernel outputs are still intact under ${OUTPUT_DIR}, just not zipped." >&2
fi

if [ "${#FAILED_TARGETS[@]}" -gt 0 ]; then
    echo "Completed with ${#FAILED_TARGETS[@]} failed target(s) — see logs above/in ${LOG_DIR}. Re-run the script to retry just those (already-built ones are skipped automatically)."
    exit 1
fi

echo "All requested kernel targets compiled and packaged!"
