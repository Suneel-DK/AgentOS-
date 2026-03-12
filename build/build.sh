#!/bin/bash
# AgentOS - ISO Builder
# Builds a bootable AgentOS ISO from Ubuntu Server 22.04 base.
# Run this on an Ubuntu/Debian machine with sudo.
# Output: AgentOS-<version>.iso

set -e  # Exit on any error
set -u  # Exit on undefined variable

# ── Config ────────────────────────────────────────────
AGENTOS_VERSION="0.1.0"
UBUNTU_VERSION="22.04.5"
UBUNTU_ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_URL="https://releases.ubuntu.com/22.04/${UBUNTU_ISO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-workspace"
OUTPUT_ISO="${SCRIPT_DIR}/AgentOS-${AGENTOS_VERSION}.iso"

# ── Helpers ───────────────────────────────────────────
header() {
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════════"
}

die() {
    echo ""
    echo "❌ ERROR: $1"
    echo "   Stopping build."
    exit 1
}

# ── Preflight Checks ─────────────────────────────────
preflight_checks() {
    header "🔍 Preflight Checks"

    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root. Try: sudo bash build.sh"
    fi

    local required_files=(
        "${REPO_ROOT}/scripts/first-boot.sh"
        "${REPO_ROOT}/scripts/detect-gpu.sh"
        "${REPO_ROOT}/scripts/install-ai-stack.sh"
        "${REPO_ROOT}/config/packages.list"
        "${REPO_ROOT}/dashboard/index.html"
        "${SCRIPT_DIR}/preseed.cfg"
        "${SCRIPT_DIR}/grub.cfg"
    )

    for f in "${required_files[@]}"; do
        if [ ! -f "${f}" ]; then
            die "Required file missing: ${f}"
        fi
    done

    echo "✅ All required source files present"
}

# ── Install Build Tools ──────────────────────────────
install_build_deps() {
    header "📦 Installing Build Tools"

    apt-get update -q
    apt-get install -y \
        xorriso \
        p7zip-full \
        grub-pc-bin \
        wget \
        curl \
        ca-certificates

    echo "✅ Build tools ready"
}

# ── Download Base ISO ────────────────────────────────
download_base_iso() {
    header "📥 Base ISO"

    if [ -f "${SCRIPT_DIR}/${UBUNTU_ISO}" ]; then
        echo "✅ Base ISO already exists, skipping download"
        return
    fi

    echo "⬇️  Downloading Ubuntu Server ${UBUNTU_VERSION}..."
    echo "    This is ~1.5GB — may take a while..."
    wget --progress=bar:force -O "${SCRIPT_DIR}/${UBUNTU_ISO}" "${UBUNTU_URL}" \
        || die "Download failed. Check your internet connection."

    echo "✅ Base ISO downloaded: ${UBUNTU_ISO}"
}

# ── Build AgentOS ISO ────────────────────────────────
# Uses extract-then-repack approach with xorriso -as mkisofs.
# This correctly preserves Ubuntu 22.04's hybrid BIOS+EFI boot setup,
# which the simpler graft mode (-boot_image any keep) does NOT reliably do.
build_agentos_iso() {
    header "💉 Building AgentOS ISO"

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"

    # ── Step 1: Extract ISO filesystem ────────────────
    echo "📂 Extracting Ubuntu ISO (this takes ~1 min)..."
    7z x "${SCRIPT_DIR}/${UBUNTU_ISO}" -o"${WORK_DIR}" -y > /dev/null \
        || die "Failed to extract Ubuntu ISO. Is p7zip-full installed?"
    echo "   Extracted to ${WORK_DIR}"

    # ── Step 2: Read EFI partition info from original ISO ──
    # Ubuntu 22.04 ISOs have an EFI partition appended after the ISO filesystem.
    # It is NOT a regular file — we must extract it with dd using its sector offset.
    echo "📐 Reading boot layout from original ISO..."
    local efi_start efi_size_sectors report interval_line
    report=$(xorriso -return_with SORRY 0 \
        -indev "${SCRIPT_DIR}/${UBUNTU_ISO}" \
        -report_system_area as_mkisofs 2>/dev/null || true)

    # Interval line looks like:
    #   -e '--interval:appended_partition_2_start_1040737s_size_10072d:all::'
    # Ubuntu 22.04 uses 'd' (2048-byte ISO blocks) for size, not 's' (512-byte sectors)
    interval_line=$(echo "${report}" | grep "interval:appended_partition_2" || true)

    if [ -n "${interval_line}" ]; then
        efi_start=$(echo "${interval_line}" | sed 's/.*start_\([0-9]*\)s_size.*/\1/')
        local efi_size_num efi_unit
        efi_size_num=$(echo "${interval_line}" | sed 's/.*_size_\([0-9]*\)[a-z]:all.*/\1/')
        efi_unit=$(echo "${interval_line}"     | sed 's/.*_size_[0-9]*\([a-z]\):all.*/\1/')
        if [ "${efi_unit}" = "d" ]; then
            efi_size_sectors=$((efi_size_num * 4))   # 2048-byte blocks → 512-byte sectors
        else
            efi_size_sectors=${efi_size_num}
        fi
        echo "   EFI partition: start=${efi_start}s  size=${efi_size_num}${efi_unit} → ${efi_size_sectors} sectors"
    else
        echo "   ⚠  Could not detect EFI layout — using Ubuntu 22.04 defaults"
        efi_start=2049
        efi_size_sectors=8192
    fi

    # ── Step 3: Extract the EFI partition image ────────
    echo "💾 Extracting EFI partition image..."
    mkdir -p "${WORK_DIR}/boot/grub"
    dd if="${SCRIPT_DIR}/${UBUNTU_ISO}" \
        bs=512 skip="${efi_start}" count="${efi_size_sectors}" \
        of="${WORK_DIR}/boot/grub/efi.img" 2>/dev/null \
        || die "Failed to extract EFI partition from ISO"
    echo "   EFI image saved ($(du -k "${WORK_DIR}/boot/grub/efi.img" | cut -f1) KB)"

    # ── Step 4: Find critical boot files ──────────────
    # 7z may extract with uppercase or different case depending on ISO flags.
    # Find the actual paths dynamically rather than assuming case.
    echo "🔍 Locating boot files in extracted ISO..."
    local boot_hybrid eltorito grub_cfg_dest

    # boot_hybrid.img comes from grub-pc-bin (not present in extracted ISO filesystem)
    local boot_hybrid eltorito grub_cfg_dest
    boot_hybrid="/usr/lib/grub/i386-pc/boot_hybrid.img"
    [ -f "${boot_hybrid}" ] || die "boot_hybrid.img not found at ${boot_hybrid} — is grub-pc-bin installed?"

    eltorito=$(find "${WORK_DIR}" -iname "eltorito.img" -path "*/i386*" 2>/dev/null | head -1)
    grub_cfg_dest=$(find "${WORK_DIR}" -iname "grub.cfg" -path "*/boot/grub/*" 2>/dev/null | head -1)

    [ -n "${eltorito}"      ] || die "eltorito.img not found in extracted ISO"
    [ -n "${grub_cfg_dest}" ] || die "grub.cfg not found in extracted ISO"

    # eltorito path must be relative to WORK_DIR for xorriso (which runs with cd WORK_DIR)
    local eltorito_rel
    eltorito_rel="${eltorito#${WORK_DIR}/}"

    echo "   boot_hybrid : ${boot_hybrid}"
    echo "   eltorito    : ${eltorito_rel}"
    echo "   grub.cfg    : ${grub_cfg_dest#${WORK_DIR}/}"

    # ── Step 5: Inject AgentOS files ──────────────────
    echo "📁 Injecting AgentOS files..."

    mkdir -p "${WORK_DIR}/agentos"
    cp -r "${REPO_ROOT}/scripts"   "${WORK_DIR}/agentos/scripts"
    cp -r "${REPO_ROOT}/config"    "${WORK_DIR}/agentos/config"
    cp -r "${REPO_ROOT}/dashboard" "${WORK_DIR}/agentos/dashboard"
    cp -r "${REPO_ROOT}/agents"    "${WORK_DIR}/agentos/agents"
    chmod +x "${WORK_DIR}/agentos/scripts/"*.sh

    mkdir -p "${WORK_DIR}/autoinstall"
    cp "${SCRIPT_DIR}/preseed.cfg" "${WORK_DIR}/autoinstall/user-data"
    touch "${WORK_DIR}/autoinstall/meta-data"

    # Replace GRUB config with our AgentOS boot menu (at actual found path)
    cp "${SCRIPT_DIR}/grub.cfg" "${grub_cfg_dest}"

    echo "   AgentOS files injected"

    # ── Step 6: Rebuild bootable ISO ──────────────────
    # Uses Ubuntu's documented method for custom 22.04 ISOs.
    # --grub2-mbr:           BIOS bootstrap code (from Ubuntu's grub)
    # -b eltorito.img:       El-Torito BIOS boot entry
    # -append_partition efi: EFI boot partition
    # -e interval:...:       El-Torito EFI boot entry
    echo "🔨 Building bootable ISO..."
    rm -f "${OUTPUT_ISO}"

    cd "${WORK_DIR}"
    xorriso -as mkisofs \
        -r \
        -V "AGENTOS_0_1_0" \
        --grub2-mbr "${boot_hybrid}" \
        --protective-msdos-label \
        -partition_cyl_align off \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "boot/grub/efi.img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c "/boot.catalog" \
        -b "/${eltorito_rel}" \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e "--interval:appended_partition_2_start_${efi_start}s_size_${efi_size_sectors}s:all::" \
        -no-emul-boot \
        -boot-load-size "${efi_size_sectors}" \
        -o "${OUTPUT_ISO}" \
        . \
        || die "ISO build failed. Check xorriso output above."

    cd "${SCRIPT_DIR}"
    echo "✅ ISO built: ${OUTPUT_ISO}"
}

# ── Validate Output ──────────────────────────────────
validate_iso() {
    header "🔎 Validating Output ISO"

    if [ ! -f "${OUTPUT_ISO}" ]; then
        die "Output ISO not found: ${OUTPUT_ISO}"
    fi

    local size_mb
    size_mb=$(du -m "${OUTPUT_ISO}" | cut -f1)

    if [ "${size_mb}" -lt 100 ]; then
        die "Output ISO is suspiciously small (${size_mb}MB). Something went wrong."
    fi

    echo "   File: ${OUTPUT_ISO}"
    echo "   Size: ${size_mb}MB"

    echo "🔍 Checking AgentOS files are present in ISO..."

    xorriso -return_with SORRY 0 -indev "${OUTPUT_ISO}" -ls /agentos/scripts/ 2>/dev/null \
        | grep -q "first-boot.sh" \
        || die "first-boot.sh not found in ISO"

    xorriso -return_with SORRY 0 -indev "${OUTPUT_ISO}" -ls /autoinstall/ 2>/dev/null \
        | grep -q "user-data" \
        || die "autoinstall/user-data not found in ISO"

    xorriso -return_with SORRY 0 -indev "${OUTPUT_ISO}" -ls /boot/grub/ 2>/dev/null \
        | grep -q "grub.cfg" \
        || die "grub.cfg not found in ISO"

    echo "✅ ISO is valid — all AgentOS files confirmed present"
}

# ── Cleanup ──────────────────────────────────────────
cleanup() {
    header "🧹 Cleanup"
    rm -rf "${WORK_DIR}"
    echo "✅ Done"
}

# ── Main ─────────────────────────────────────────────
main() {
    echo ""
    echo "  ██████╗ ██╗   ██╗██╗██╗     ██████╗ "
    echo "  ██╔══██╗██║   ██║██║██║     ██╔══██╗"
    echo "  ██████╔╝██║   ██║██║██║     ██║  ██║"
    echo "  ██╔══██╗██║   ██║██║██║     ██║  ██║"
    echo "  ██████╔╝╚██████╔╝██║███████╗██████╔╝"
    echo "  ╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝ "
    echo ""
    echo "  ISO Builder v${AGENTOS_VERSION}"
    echo ""

    preflight_checks
    install_build_deps
    download_base_iso
    build_agentos_iso
    validate_iso
    cleanup

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ✅  AgentOS ${AGENTOS_VERSION} ISO is READY!         ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                              ║"
    echo "║  File: AgentOS-${AGENTOS_VERSION}.iso               ║"
    echo "║                                              ║"
    echo "║  Next steps:                                 ║"
    echo "║  1. Flash to USB with Balena Etcher          ║"
    echo "║  2. Boot your machine from USB               ║"
    echo "║  3. AgentOS installs itself automatically    ║"
    echo "║  4. Visit http://<machine-ip>:3000           ║"
    echo "║                                              ║"
    echo "║  Test in VM:                                 ║"
    echo "║  Attach ISO → Boot Order: Optical first      ║"
    echo "║  EFI disabled → Start VM                     ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

main "$@"
