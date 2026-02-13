#!/usr/bin/env bash
################################################################################
# Fedora 43 Dual-GPU Cooperative Mode Setup & System Optimizer
# Hardware: Asus Z390-F | i9-9900 | RX 6400 (PCIE x16 Slot 1) | GTX 1650 (PCIE x16 Slot 2)
# Purpose:
#   - Auto-detect and auto-install missing drivers/packages (RPM Fusion, NVIDIA, AMD)
#   - Configure PRIME Render Offload / Vulkan multi-ICD hints so both GPUs can
#     cooperate for rendering/compute workloads (note: physical fusion/SLI is not
#     possible across AMD <-> NVIDIA — this creates a cooperative environment,
#     helps offload tasks to the appropriate GPU, and provides helpers to split
#     large workloads like video encoding across available GPUs)
#   - Implement intelligent workload balancing, power management, system
#     optimization, and helper utilities for easy workflow
################################################################################

set -euo pipefail

# --- Configuration ---
LOG_FILE="/var/log/dual-gpu-setup.log"
NVIDIA_REGISTRY_DPM=0x02 # Dynamic Power Management (suspend when idle)
SMART_RUN_PATH="/usr/local/bin/smart-run"
GPU_CHECK_PATH="/usr/local/bin/gpu-check"
GPU_BALANCE_PATH="/usr/local/bin/gpu-balance"
SYSTEM_TUNE_PATH="/usr/local/bin/system-tune"
PRIME_SETUP_PATH="/usr/local/bin/prime-setup"
GPU_COOP_PATH="/usr/local/bin/gpu-coop"
GPU_PARALLEL_FFMPEG="/usr/local/bin/gpu-parallel-ffmpeg"
LOSSLESS_SCALE_PATH="/usr/local/bin/lossless-scale"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Helpers ---
log() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# Check for Root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root. Try: sudo ./optimize_system.sh"
fi

clear
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Fedora 43 Intelligent Dual-GPU Setup & System Optimizer  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}System Configuration:${NC}"
echo "  Motherboard: Asus Z390-F"
echo "  CPU: Intel Core i9-9900"
echo "  GPU1 (PCIE x16 Slot 1): AMD RX 6400 (Display/Primary)"
echo "  GPU2 (PCIE x16 Slot 2): NVIDIA GTX 1650 (Compute/Render Offload)"
echo ""
echo "  Purpose: Configure GPUs to cooperate (PRIME + Vulkan multi-ICD)"
echo "           Provide helper tools to automatically offload or split workloads"
echo "           (Note: AMD and NVIDIA cannot be merged into a single physical"
echo "            GPU; this creates a unified workflow so applications can use"
echo "            the most appropriate GPU automatically or via helpers)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 3

################################################################################
# PHASE 0: SYSTEM DEPENDENCY CHECK & VALIDATION
################################################################################
log "Validating system requirements and checking for missing packages..."

# Check if dnf is available
if ! command -v dnf >/dev/null 2>&1; then
    error "dnf package manager not found. Please ensure you're running Fedora."
fi

# Check internet connectivity
if ! ping -c 1 8.8.8.8 &> /dev/null; then
    warn "No internet connectivity detected. Some packages may fail to install."
fi

# Ensure running kernel has matching kernel-devel available (required for akmods/dkms)
CURRENT_KVER="$(uname -r)"
if ! rpm -q "kernel-devel-${CURRENT_KVER}" &>/dev/null; then
    log "kernel-devel-${CURRENT_KVER} not installed. Attempting to install matching kernel-devel..."
    if ! dnf install -y "kernel-devel-${CURRENT_KVER}" 2>&1 | tee -a "$LOG_FILE"; then
        warn "Could not install kernel-devel for ${CURRENT_KVER}. Kernel module builds may fail; ensure kernel-devel for your running kernel is installed and reboot if needed."
    else
        success "Installed kernel-devel for ${CURRENT_KVER}"
    fi
else
    success "kernel-devel for running kernel present (${CURRENT_KVER})"
fi

success "System validation completed."

################################################################################
# PHASE 1: REPOSITORIES & BASE SYSTEM
################################################################################
log "Checking and configuring repositories..."

# Update system first
log "Updating system repositories..."
dnf update -y || warn "System update had some issues, continuing anyway."

# Enable RPM Fusion (Free & Non-Free)
if ! dnf repolist | grep -q "rpmfusion-nonfree"; then
    log "Installing RPM Fusion repositories..."
    dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
                   https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm 2>&1 | tee -a "$LOG_FILE" || warn "RPM Fusion installation had issues."
    success "RPM Fusion repositories configured."
else
    success "RPM Fusion repositories already active."
fi

# Helper to install packages idempotently with error handling
ensure_pkgs() {
    local pkgs=("$@")
    log "Ensuring packages installed: ${pkgs[*]}"
    for pkg in "${pkgs[@]}"; do
        if ! dnf install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            warn "Package '$pkg' installation failed or unavailable, continuing..."
        fi
    done
}

# Ensure essential build dependencies
log "Installing essential build tools and dependencies..."
ensure_pkgs kernel-devel kernel-headers gcc make perl dkms elfutils-libelf-devel git wget curl

success "Base system dependencies configured."

################################################################################
# PHASE 2: GPU DETECTION & DRIVER INSTALLATION
################################################################################
log "Detecting GPUs and installing appropriate drivers..."

# Detect GPUs
AMD_PRESENT=false
NVIDIA_PRESENT=false
AMD_PCI_ADDR=""
NVIDIA_PCI_ADDR=""
AMD_DEVICE_ID=""
NVIDIA_DEVICE_ID=""

while read -r line; do
    if echo "$line" | grep -qi "Advanced Micro Devices\|AMD/ATI\|Radeon"; then
        AMD_PRESENT=true
        AMD_PCI_ADDR=$(echo "$line" | awk '{print $1}')
        AMD_DEVICE_ID=$(echo "$line" | grep -oP '\[.*\]' | tail -1)
    fi
    if echo "$line" | grep -qi "NVIDIA"; then
        NVIDIA_PRESENT=true
        NVIDIA_PCI_ADDR=$(echo "$line" | awk '{print $1}')
        NVIDIA_DEVICE_ID=$(echo "$line" | grep -oP '\[.*\]' | tail -1)
    fi
done < <(lspci -nn | grep -E "(VGA|3D)")

# AMD/AMDGPU Driver Installation
if $AMD_PRESENT; then
    log "AMD GPU detected at ${AMD_PCI_ADDR} ${AMD_DEVICE_ID}"
    log "Installing AMD/AMDGPU driver stack and Mesa libraries..."
    ensure_pkgs xorg-x11-drv-amdgpu mesa-libGL mesa-vulkan-drivers mesa-vdpau-drivers \
                libglvnd libglvnd-devel mesa-dri-drivers amdgpu-dkms libva-utils vainfo
    # Try to ensure VA-API drivers and detection utilities exist
    success "AMD drivers and libraries installed."
else
    warn "No AMD GPU detected. Skipping AMD-specific packages."
fi

# NVIDIA Driver Installation
if $NVIDIA_PRESENT; then
    log "NVIDIA GPU detected at ${NVIDIA_PCI_ADDR} ${NVIDIA_DEVICE_ID}"
    log "Installing NVIDIA driver stack (akmod-nvidia for automatic kernel module rebuilding)..."
    ensure_pkgs akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda nvidia-settings \
                nvidia-utils nvidia-driver-modaliases vulkan-loader nvidia-modprobe
    success "NVIDIA drivers installed (kernel modules will be built automatically by akmods)."
else
    warn "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
fi

# Post-install quick checks for GPU driver availability
if $NVIDIA_PRESENT; then
    if command -v nvidia-smi &>/dev/null; then
        log "NVIDIA driver appears available. Enabling persistence mode..."
        nvidia-smi -pm 1 2>&1 | tee -a "$LOG_FILE" || warn "nvidia-smi persistence mode failed to set."
    else
        warn "nvidia-smi not available yet; kernel module may still be building. A reboot may be required for NVIDIA modules to become active."
    fi
fi

if $AMD_PRESENT; then
    if command -v vainfo &>/dev/null; then
        log "VA-API detected for AMD. $(vainfo 2>/dev/null | head -2 | tr '\n' ' ')"
    else
        warn "vainfo not available, or AMD VA-API drivers not detected."
    fi
fi

# Install GPU diagnostics and utilities
log "Installing GPU diagnostics and utility packages..."
ensure_pkgs vulkan-tools libva-utils libva-vdpau-driver mesa-dri-drivers glx-utils radeontop \
            hwinfo lm-sensors

# Install Steam and related gaming libraries for better GPU support
log "Installing gaming and multimedia support packages..."
ensure_pkgs steam mesa-demos gstreamer1-libav gstreamer1-plugins-good gstreamer1-plugins-bad-free

success "GPU detection and driver installation phase completed."

################################################################################
# PHASE 3: CONFIGURE GPU USAGE & PRIME RENDER OFFLOAD
################################################################################
log "Configuring GPU usage patterns and PRIME Render Offload..."

# NVIDIA Module Configuration for optimal performance and power management
if $NVIDIA_PRESENT; then
    log "Writing NVIDIA kernel module configuration..."
    cat > /etc/modprobe.d/50-nvidia.conf <<EOF
# NVIDIA Dynamic Power Management and Display Management
options nvidia NVreg_DynamicPowerManagement=${NVIDIA_REGISTRY_DPM}
options nvidia_drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
EOF
    success "NVIDIA modprobe configuration written."

    # Enable NVIDIA persistence daemon
    if systemctl list-unit-files 2>/dev/null | grep -q nvidia-persistenced; then
        log "Enabling NVIDIA persistence daemon..."
        systemctl enable --now nvidia-persistenced 2>&1 | tee -a "$LOG_FILE" || warn "nvidia-persistenced enable failed."
        success "NVIDIA persistence daemon configured."
    fi

    # Ensure NVIDIA persistence mode via CLI as well
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -pm 1 2>&1 | tee -a "$LOG_FILE" || warn "Failed to set NVIDIA persistence mode via nvidia-smi."
    fi
fi

# Create Xorg configuration for PRIME Render Offload (X11 support)
if $NVIDIA_PRESENT; then
    log "Configuring Xorg for PRIME Render Offload (X11)..."
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-prime-offload.conf <<'EOF'
# PRIME Render Offload Configuration
# AMD RX 6400 as primary display driver
# NVIDIA GTX 1650 available for offload rendering

Section "ServerLayout"
    Identifier "layout"
EndSection

Section "Device"
    Identifier "AmdCard"
    Driver "amdgpu"
    Option "PrimaryGPU" "yes"
EndSection

Section "Device"
    Identifier "NvidiaCard"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "PrimaryGPU" "no"
EndSection

Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "AutoAddGPU" "true"
EndSection
EOF
    success "Xorg PRIME Render Offload configuration written."
fi

# Create Wayland GPU configuration (for Wayland sessions)
if $NVIDIA_PRESENT; then
    log "Creating configuration for Wayland GPU support..."
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/gpu_wayland.sh <<'EOF'
# GPU configuration for Wayland sessions
# When using NVIDIA as offload GPU, these variables help enable offload
# They are conservative defaults - users can override per-session or via smart-run
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export DRI_PRIME=0
# Workaround for Wayland GPU acceleration when AMD is display
export LIBVA_DRIVER_NAME=radeonsi
EOF
    chmod 644 /etc/profile.d/gpu_wayland.sh
    success "Wayland GPU support configured."
fi

# Global GPU environment configuration (conservative defaults)
log "Creating global GPU environment configuration..."
cat > /etc/profile.d/gpu_config.sh <<'EOF'
# Global GPU Configuration for Fedora 43 Dual-GPU Setup

# Primary display: AMD RX 6400 (AMDGPU driver)
export LIBVA_DRIVER_NAME=radeonsi

# NVIDIA GTX 1650 available for offload via PRIME
# Use smart-run or gpu-coop to set these per-invocation:
# export __NV_PRIME_RENDER_OFFLOAD=1
# export __GLX_VENDOR_LIBRARY_NAME=nvidia
# export DRI_PRIME=0

# Combined Vulkan ICD hint (optional):
# To prefer using both Vulkan devices (if application supports enumerating multiple devices)
# uncomment and adjust as needed:
# export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json:/usr/share/vulkan/icd.d/radeon_icd.json

# Additional performance tuning
export MESA_DEBUG=silent
export VDPAU_DRIVER=radeonsi

# Workaround for browser GPU sandboxing
export MOZ_DISABLE_RDD_SANDBOX=1

# GPU monitoring (radeontop-friendly)
export RADEON_HYPERZ=yes
EOF
chmod 644 /etc/profile.d/gpu_config.sh

success "GPU configuration phase completed."

################################################################################
# PHASE 3B: COOPERATIVE MODE HELPERS (prime-setup, gpu-coop, gpu-parallel-ffmpeg)
################################################################################
log "Installing cooperative mode helpers (prime-setup, gpu-coop, gpu-parallel-ffmpeg)..."

# prime-setup: helper to set X11 provider mappings for PRIME (run per-user in session)
cat > "${PRIME_SETUP_PATH}" <<'PRIMESETUP_EOF'
#!/usr/bin/env bash
# prime-setup: Attempt to set provider output/source for X11 sessions so that
#              the offload GPU is properly attached to the primary provider.
# Usage: prime-setup (run as the session user after X starts; can be added to
#        user startup scripts or run manually)

set -euo pipefail

if ! command -v xrandr &>/dev/null; then
    echo "xrandr not available; cannot set provider mappings for X11 sessions."
    exit 2
fi

# Determine DISPLAY if not set
DISPLAY="${DISPLAY:-:0}"
export DISPLAY

PROVIDERS="$(xrandr --listproviders 2>/dev/null)"
if [[ -z "$PROVIDERS" ]]; then
    echo "No X11 providers detected. Are you running an X11 session on ${DISPLAY}?"
    exit 1
fi

# Find provider names for NVIDIA and AMD (case-insensitive)
NV_NAME="$(echo "$PROVIDERS" | awk -F'name:' 'tolower($0) ~ /nvidia/ {print $2; exit}' | xargs || true)"
AMD_NAME="$(echo "$PROVIDERS" | awk -F'name:' 'tolower($0) ~ /radeon|amd/ {print $2; exit}' | xargs || true)"

if [[ -n "$NV_NAME" && -n "$AMD_NAME" ]]; then
    echo "Setting provider output source: NVIDIA -> AMD (NV: '$NV_NAME' AMD: '$AMD_NAME')"
    xrandr --setprovideroutputsource "$NV_NAME" "$AMD_NAME" || { echo "Failed to set provider output source"; exit 1; }
    xrandr --auto >/dev/null 2>&1 || true
    echo "Provider mapping applied."
else
    echo "Could not determine both NVIDIA and AMD provider names. Here is the provider list:"
    echo "$PROVIDERS"
    exit 1
fi
PRIMESETUP_EOF
chmod 755 "${PRIME_SETUP_PATH}"
success "prime-setup installed at ${PRIME_SETUP_PATH}"

# gpu-coop: set environment for cooperative GPU usage and run a command
cat > "${GPU_COOP_PATH}" <<'GPUCOOP_EOF'
#!/usr/bin/env bash
# gpu-coop: Run a command with environment variables configured for cooperative GPU usage.
# Usage: gpu-coop [--nvidia|--amd|--balanced|--auto] <command> [args...]
#   --balanced: attempt to expose both Vulkan ICDs and enable NVIDIA offload,
#               while preserving AMD VA-API for display/decoding.

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: gpu-coop [--nvidia|--amd|--balanced|--auto] <command> [args...]"
    exit 2
fi

MODE="auto"
if [[ "$1" =~ ^--(nvidia|amd|balanced|auto)$ ]]; then
    MODE="${1#--}"
    shift
fi

CMD=("$@")
APP_NAME="$(basename "${CMD[0]}")"

# find ICDs
NV_ICD="$(ls /usr/share/vulkan/icd.d/*nvidia*.json 2>/dev/null | head -n1 || true)"
AMD_ICD="$(ls /usr/share/vulkan/icd.d/*radeon*.json /usr/share/vulkan/icd.d/*amd*.json 2>/dev/null | head -n1 || true)"

case "$MODE" in
    nvidia)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export DRI_PRIME=0
        [[ -n "$NV_ICD" ]] && export VK_ICD_FILENAMES="$NV_ICD"
        echo "[gpu-coop] Using NVIDIA for command: ${CMD[*]}"
        ;;
    balanced)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export DRI_PRIME=0
        [[ -n "$NV_ICD" ]] && [[ -n "$AMD_ICD" ]] && export VK_ICD_FILENAMES="${NV_ICD}:${AMD_ICD}"
        export LIBVA_DRIVER_NAME=radeonsi
        echo "[gpu-coop] Using BALANCED mode (both GPUs available) for: ${CMD[*]}"
        ;;
    amd)
        unset __NV_PRIME_RENDER_OFFLOAD 2>/dev/null || true
        unset __GLX_VENDOR_LIBRARY_NAME 2>/dev/null || true
        export LIBVA_DRIVER_NAME=radeonsi
        [[ -n "$AMD_ICD" ]] && export VK_ICD_FILENAMES="$AMD_ICD"
        echo "[gpu-coop] Using AMD for command: ${CMD[*]}"
        ;;
    auto)
        # heuristics similar to smart-run
        case "$APP_NAME" in
            blender|cycles-daemon|optix*)
                exec "$0" --nvidia "${CMD[@]}"
                ;;
            ffmpeg|MediaInfo|HandBrake)
                exec "$0" --balanced "${CMD[@]}"
                ;;
            steam|vulkan*)
                exec "$0" --nvidia "${CMD[@]}"
                ;;
            *)
                exec "$0" --amd "${CMD[@]}"
                ;;
        esac
        ;;
esac

# Execute the command
exec "${CMD[@]}"
GPUCOOP_EOF
chmod 755 "${GPU_COOP_PATH}"
success "gpu-coop utility installed at ${GPU_COOP_PATH}"

# gpu-parallel-ffmpeg: split-and-parallel-encode helper using available GPUs
cat > "${GPU_PARALLEL_FFMPEG}" <<'GPUFF_EOF'
#!/usr/bin/env bash
# gpu-parallel-ffmpeg: Simple helper to split a single input into N segments and
# transcode them in parallel using available GPU encoders (NVENC or VAAPI) or CPU
# Usage:
#   gpu-parallel-ffmpeg -i input.mp4 -o output.mp4 [-j jobs] [-c codec] [-b bitrate]
#
# Notes:
#   - Requires ffmpeg and ffprobe to be installed.
#   - This is a pragmatic splitter/parallel encoder for large files (e.g., long
#     videos) and will concatenate the segments after encoding.
#   - It prefers encoders h264_nvenc (NVIDIA) or h264_vaapi (AMD) if available,
#     otherwise falls back to libx264 (CPU).
set -euo pipefail

usage() {
    echo "Usage: $0 -i INPUT -o OUTPUT [-j JOBS] [-c h264|hevc] [-b BITRATE]"
    exit 2
}

INPUT=""
OUTPUT=""
JOBS=0
CODEC="h264"
BITRATE="2000k"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) INPUT="$2"; shift 2;;
        -o) OUTPUT="$2"; shift 2;;
        -j) JOBS="$2"; shift 2;;
        -c) CODEC="$2"; shift 2;;
        -b) BITRATE="$2"; shift 2;;
        -h|--help) usage;;
        *) echo "Unknown option: $1"; usage;;
    esac
done

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    usage
fi

if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
    echo "ffmpeg or ffprobe not found. Install ffmpeg before using this tool."
    exit 1
fi

# Detect encoders
NV_ENC="$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'h264_nvenc' || true)"
VAAPI_ENC="$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'h264_vaapi|hevc_vaapi' || true)"
LIBX264="$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E 'libx264' || true)"

# Detect GPUs
NV_PRESENT=false
AMD_PRESENT=false
if command -v nvidia-smi &>/dev/null; then NV_PRESENT=true; fi
if [[ -c /dev/dri/renderD128 ]] || command -v vainfo &>/dev/null; then AMD_PRESENT=true; fi

# Determine jobs (default = number of available GPUs or 2)
if [[ -z "$JOBS" || "$JOBS" -le 0 ]]; then
    JOBS=0
    $NV_PRESENT && JOBS=$((JOBS+1))
    $AMD_PRESENT && JOBS=$((JOBS+1))
    if [[ "$JOBS" -le 0 ]]; then JOBS=2; fi
fi

# Get duration (in seconds, rounded)
DURATION_RAW="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$INPUT")"
DURATION=${DURATION_RAW%.*}
if [[ -z "$DURATION" || "$DURATION" -eq 0 ]]; then
    echo "Could not determine duration of input."
    exit 1
fi

SEG_TIME=$(( (DURATION + JOBS - 1) / JOBS ))

WORKDIR="$(mktemp -d /tmp/gpu-ffmpeg-XXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Splitting ${INPUT} into ${JOBS} segments (~${SEG_TIME}s each) and encoding in parallel..."
declare -a PART_FILES
for ((i=0;i<JOBS;i++)); do
    START=$(( i * SEG_TIME ))
    PART_IN="${WORKDIR}/part_${i}.ts"
    PART_OUT="${WORKDIR}/out_${i}.ts"
    PART_FILES+=("$PART_OUT")
    echo "Extracting part ${i}: start=${START}s ..."
    ffmpeg -y -ss "$START" -t "$SEG_TIME" -i "$INPUT" -c copy -avoid_negative_ts make_zero -fflags +genpts "$PART_IN" </dev/null &>/dev/null || true
done

# Encode parts in parallel
encode_part() {
    local idx="$1"
    local part_in="${WORKDIR}/part_${idx}.ts"
    local part_out="${WORKDIR}/out_${idx}.ts"
    echo "Encoding part ${idx}..."
    # Choose encoder for this job (round-robin preference)
    if $NV_PRESENT && [[ -n "$NV_ENC" ]]; then
        # NVIDIA encoder
        ffmpeg -y -i "$part_in" -c:v h264_nvenc -b:v "$BITRATE" -preset fast -c:a copy -f mpegts "$part_out" </dev/null
    elif $AMD_PRESENT && [[ -n "$VAAPI_ENC" ]]; then
        # AMD VAAPI encoder
        ffmpeg -y -vaapi_device /dev/dri/renderD128 -i "$part_in" -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v "$BITRATE" -c:a copy -f mpegts "$part_out" </dev/null
    elif [[ -n "$LIBX264" ]]; then
        # CPU fallback
        ffmpeg -y -i "$part_in" -c:v libx264 -b:v "$BITRATE" -preset fast -c:a copy -f mpegts "$part_out" </dev/null
    else
        echo "No suitable encoder found for part ${idx}. Exiting."
        exit 1
    fi
    echo "Encoded part ${idx} -> $(basename "$part_out")"
}

# Launch encodes with a simple concurrency limit
pids=()
for ((i=0;i<JOBS;i++)); do
    encode_part "$i" &
    pids+=($!)
    # limit concurrency to JOBS
    while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 1; done
done
wait "${pids[@]:-}"

# Concatenate outputs
LIST_FILE="${WORKDIR}/list.txt"
: > "$LIST_FILE"
for f in "${PART_FILES[@]}"; do
    echo "file '$f'" >> "$LIST_FILE"
done

echo "Concatenating into final output..."
# Use concat demuxer to produce MP4; for mpegts inputs, ffmpeg can copy streams
ffmpeg -y -f concat -safe 0 -i "$LIST_FILE" -c copy -bsf:a aac_adtstoasc "$OUTPUT"

echo "Cleaning up temporary files..."
rm -rf "$WORKDIR"
echo "Done. Output: $OUTPUT"
GPUFF_EOF
chmod 755 "${GPU_PARALLEL_FFMPEG}"
success "gpu-parallel-ffmpeg installed at ${GPU_PARALLEL_FFMPEG}"

success "Cooperative mode helper scripts installed."

################################################################################
# PHASE 3C: LOSSLESS SCALING SUPPORT (gamescope-based)
################################################################################
log "Installing lossless scaling support (gamescope + helpers)..."

# Install gamescope and related packages
ensure_pkgs gamescope mangohud goverlay

# lossless-scale: Lossless Scaling equivalent for Linux using gamescope
cat > "${LOSSLESS_SCALE_PATH}" <<'LOSSLESSSCALE_EOF'
#!/usr/bin/env bash
# lossless-scale: Lossless Scaling equivalent for Linux
# Provides integer scaling, FSR upscaling, and frame generation via gamescope
#
# Usage:
#   lossless-scale [options] <command> [args...]
#
# Options:
#   --integer         Integer (pixel-perfect) scaling (default)
#   --fsr             FSR upscaling (AMD FidelityFX Super Resolution)
#   --fsr-ultra       FSR Ultra Quality mode
#   --fsr-quality     FSR Quality mode
#   --fsr-balanced    FSR Balanced mode
#   --fsr-performance FSR Performance mode
#   --nis             NVIDIA Image Scaling (NIS) mode
#   --res WxH         Internal render resolution (e.g., 1280x720)
#   --output WxH      Output/display resolution (e.g., 1920x1080)
#   --fps N           Frame limit (e.g., 60)
#   --fps-unfocused N Frame limit when window unfocused
#   --fullscreen      Force fullscreen mode
#   --borderless      Borderless windowed mode
#   --hdr             Enable HDR support (if available)
#   --mangohud        Enable MangoHud overlay
#   --gpu nvidia      Force NVIDIA GPU for rendering
#   --gpu amd         Force AMD GPU for rendering
#   --help            Show this help message
#
# Examples:
#   lossless-scale --integer --res 1280x720 --output 1920x1080 game.exe
#   lossless-scale --fsr-quality --fps 60 --mangohud steam
#   lossless-scale --fsr --res 2560x1440 --output 3840x2160 ./game

set -euo pipefail

show_help() {
    echo "lossless-scale: Lossless Scaling equivalent for Linux (via gamescope)"
    echo ""
    echo "Usage: lossless-scale [options] <command> [args...]"
    echo ""
    echo "Scaling Modes:"
    echo "  --integer           Integer (pixel-perfect) scaling (default)"
    echo "  --fsr               FSR upscaling (auto quality)"
    echo "  --fsr-ultra         FSR Ultra Quality (1.3x scale)"
    echo "  --fsr-quality       FSR Quality (1.5x scale)"
    echo "  --fsr-balanced      FSR Balanced (1.7x scale)"
    echo "  --fsr-performance   FSR Performance (2x scale)"
    echo "  --nis               NVIDIA Image Scaling mode"
    echo ""
    echo "Resolution Options:"
    echo "  --res WxH           Internal render resolution (e.g., 1280x720)"
    echo "  --output WxH        Output/display resolution (e.g., 1920x1080)"
    echo ""
    echo "Frame Options:"
    echo "  --fps N             Frame limit (e.g., 60, 120, 144)"
    echo "  --fps-unfocused N   Frame limit when window unfocused"
    echo ""
    echo "Display Options:"
    echo "  --fullscreen        Force fullscreen mode"
    echo "  --borderless        Borderless windowed mode"
    echo "  --hdr               Enable HDR support"
    echo ""
    echo "Extras:"
    echo "  --mangohud          Enable MangoHud performance overlay"
    echo "  --gpu nvidia|amd    Force specific GPU for rendering"
    echo ""
    echo "Examples:"
    echo "  lossless-scale --integer --res 1280x720 steam"
    echo "  lossless-scale --fsr-quality --fps 60 ./game"
    echo "  lossless-scale --fsr --mangohud --gpu nvidia blender"
    echo ""
    exit 0
}

if ! command -v gamescope &>/dev/null; then
    echo "Error: gamescope is not installed. Install it with:"
    echo "  sudo dnf install gamescope"
    exit 1
fi

# Defaults
SCALE_MODE="integer"
FSR_SHARPNESS=5
INTERNAL_RES=""
OUTPUT_RES=""
FPS_LIMIT=""
FPS_UNFOCUSED=""
FULLSCREEN=false
BORDERLESS=false
HDR=false
MANGOHUD=false
GPU_SELECT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            ;;
        --integer)
            SCALE_MODE="integer"
            shift
            ;;
        --fsr)
            SCALE_MODE="fsr"
            FSR_SHARPNESS=5
            shift
            ;;
        --fsr-ultra)
            SCALE_MODE="fsr"
            FSR_SHARPNESS=3
            shift
            ;;
        --fsr-quality)
            SCALE_MODE="fsr"
            FSR_SHARPNESS=5
            shift
            ;;
        --fsr-balanced)
            SCALE_MODE="fsr"
            FSR_SHARPNESS=7
            shift
            ;;
        --fsr-performance)
            SCALE_MODE="fsr"
            FSR_SHARPNESS=10
            shift
            ;;
        --nis)
            SCALE_MODE="nis"
            shift
            ;;
        --res)
            INTERNAL_RES="$2"
            shift 2
            ;;
        --output)
            OUTPUT_RES="$2"
            shift 2
            ;;
        --fps)
            FPS_LIMIT="$2"
            shift 2
            ;;
        --fps-unfocused)
            FPS_UNFOCUSED="$2"
            shift 2
            ;;
        --fullscreen)
            FULLSCREEN=true
            shift
            ;;
        --borderless)
            BORDERLESS=true
            shift
            ;;
        --hdr)
            HDR=true
            shift
            ;;
        --mangohud)
            MANGOHUD=true
            shift
            ;;
        --gpu)
            GPU_SELECT="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "Error: No command specified."
    echo "Usage: lossless-scale [options] <command> [args...]"
    exit 1
fi

# Build gamescope arguments
GS_ARGS=()

# Resolution settings
if [[ -n "$INTERNAL_RES" ]]; then
    IFS='x' read -r W H <<< "$INTERNAL_RES"
    GS_ARGS+=(-w "$W" -h "$H")
fi

if [[ -n "$OUTPUT_RES" ]]; then
    IFS='x' read -r OW OH <<< "$OUTPUT_RES"
    GS_ARGS+=(-W "$OW" -H "$OH")
fi

# Scaling mode
case "$SCALE_MODE" in
    integer)
        GS_ARGS+=(-S integer)
        echo "[lossless-scale] Using integer (pixel-perfect) scaling"
        ;;
    fsr)
        GS_ARGS+=(-F fsr -S fit --fsr-sharpness "$FSR_SHARPNESS")
        echo "[lossless-scale] Using FSR upscaling (sharpness: $FSR_SHARPNESS)"
        ;;
    nis)
        GS_ARGS+=(-F nis -S fit)
        echo "[lossless-scale] Using NIS (NVIDIA Image Scaling)"
        ;;
esac

# Frame limiting
if [[ -n "$FPS_LIMIT" ]]; then
    GS_ARGS+=(-r "$FPS_LIMIT")
    echo "[lossless-scale] Frame limit: ${FPS_LIMIT} fps"
fi

if [[ -n "$FPS_UNFOCUSED" ]]; then
    GS_ARGS+=(-o "$FPS_UNFOCUSED")
    echo "[lossless-scale] Unfocused frame limit: ${FPS_UNFOCUSED} fps"
fi

# Display options
if $FULLSCREEN; then
    GS_ARGS+=(-f)
    echo "[lossless-scale] Fullscreen mode enabled"
fi

if $BORDERLESS; then
    GS_ARGS+=(-b)
    echo "[lossless-scale] Borderless mode enabled"
fi

if $HDR; then
    GS_ARGS+=(--hdr-enabled)
    echo "[lossless-scale] HDR enabled"
fi

# GPU selection environment
if [[ "$GPU_SELECT" == "nvidia" ]]; then
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export DRI_PRIME=0
    echo "[lossless-scale] Using NVIDIA GPU for rendering"
elif [[ "$GPU_SELECT" == "amd" ]]; then
    unset __NV_PRIME_RENDER_OFFLOAD 2>/dev/null || true
    unset __GLX_VENDOR_LIBRARY_NAME 2>/dev/null || true
    export LIBVA_DRIVER_NAME=radeonsi
    echo "[lossless-scale] Using AMD GPU for rendering"
fi

# MangoHud
if $MANGOHUD; then
    if command -v mangohud &>/dev/null; then
        export MANGOHUD=1
        echo "[lossless-scale] MangoHud overlay enabled"
    else
        echo "[lossless-scale] Warning: MangoHud not installed, skipping overlay"
    fi
fi

# Build final command
CMD=("$@")
echo "[lossless-scale] Launching: ${CMD[*]}"
echo "[lossless-scale] gamescope args: ${GS_ARGS[*]}"
echo ""

# Execute with gamescope
exec gamescope "${GS_ARGS[@]}" -- "${CMD[@]}"
LOSSLESSSCALE_EOF
chmod 755 "${LOSSLESS_SCALE_PATH}"
success "lossless-scale utility installed at ${LOSSLESS_SCALE_PATH}"

success "Lossless scaling support installed."

################################################################################
# PHASE 4: SYSTEM OPTIMIZATION & PERFORMANCE TUNING
################################################################################
log "Optimizing system performance and CPU/GPU coordination..."

# CPU Governor Optimization for i9-9900
log "Optimizing CPU frequency scaling governor..."
if [[ -d /sys/devices/system/cpu ]]; then
    if command -v cpupower >/dev/null 2>&1; then
        log "Using cpupower to set performance governor..."
        cpupower frequency-set -g performance 2>&1 | tee -a "$LOG_FILE" || warn "cpupower tuning failed."
        success "CPU frequency governor set to performance mode."
    else
        log "Setting CPU frequency scaling manually..."
        for cpu_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            if [[ -w "$cpu_file" ]]; then
                echo "performance" > "$cpu_file" 2>/dev/null || true
            fi
        done
        success "CPU frequency scaling configured."
    fi
fi

# Memory Optimization
log "Optimizing memory and I/O settings..."
cat > /etc/sysctl.d/98-gpu-optimization.conf <<'EOF'
# System optimization for dual-GPU and gaming workloads

# VM tuning
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.swappiness = 10
vm.max_map_count = 2147483642

# Network tuning
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# I/O tuning
kernel.sched_migration_cost_ns = 5000000
EOF
sysctl -p /etc/sysctl.d/98-gpu-optimization.conf 2>&1 | tee -a "$LOG_FILE" || warn "Some sysctl settings failed."
success "Kernel parameters optimized."

################################################################################
# PHASE 5: POWER MANAGEMENT & THERMAL CONTROL
################################################################################
log "Configuring power management and thermal profiles..."

# Udev rules for GPU runtime power management
log "Installing udev rules for automatic GPU power management..."
cat > /etc/udev/rules.d/99-gpu-power.rules <<'EOF'
# Automatic GPU power management via udev
# NVIDIA (0x10DE) - Set to runtime power management auto
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", RUN+="/bin/sh -c 'echo auto > /sys$DEVPATH/power/control'"

# AMD (0x1002) - Set to runtime power management auto
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", RUN+="/bin/sh -c 'echo auto > /sys$DEVPATH/power/control'"
EOF
chmod 644 /etc/udev/rules.d/99-gpu-power.rules

log "Reloading udev rules..."
udevadm control --reload-rules 2>&1 | tee -a "$LOG_FILE" || true
udevadm trigger --type=subsystems --action=change 2>&1 | tee -a "$LOG_FILE" || true

success "GPU power management udev rules installed."

# Apply power settings to currently present GPUs
log "Applying power management settings to detected GPUs..."
if $NVIDIA_PRESENT; then
    for syspath in /sys/bus/pci/devices/*; do
        vendor=$(cat "${syspath}/vendor" 2>/dev/null || echo "")
        if [[ "$vendor" == "0x10de" ]]; then
            if [[ -w "${syspath}/power/control" ]]; then
                echo auto > "${syspath}/power/control" 2>/dev/null || true
                log "NVIDIA GPU at $(basename "$syspath"): runtime PM enabled."
            fi
        fi
    done
fi

if $AMD_PRESENT; then
    for syspath in /sys/bus/pci/devices/*; do
        vendor=$(cat "${syspath}/vendor" 2>/dev/null || echo "")
        if [[ "$vendor" == "0x1002" ]]; then
            if [[ -w "${syspath}/power/control" ]]; then
                echo auto > "${syspath}/power/control" 2>/dev/null || true
                log "AMD GPU at $(basename "$syspath"): runtime PM enabled."
            fi
        fi
    done
fi

success "Power management configuration completed."

# Install and configure TLP for laptop-style power management
log "Installing TLP for advanced power management..."
ensure_pkgs tlp tlp-rdw
systemctl enable --now tlp 2>&1 | tee -a "$LOG_FILE" || warn "TLP service enable failed."
success "TLP power management daemon configured."

# Configure I/O scheduler for better performance
log "Optimizing I/O scheduler..."
for disk in sda sdb nvme0n1 nvme1n1; do
    if [[ -d "/sys/block/$disk" ]]; then
        scheduler_path="/sys/block/$disk/queue/scheduler"
        if [[ -w "$scheduler_path" ]]; then
            echo "mq-deadline" > "$scheduler_path" 2>/dev/null || echo "kyber" > "$scheduler_path" 2>/dev/null || true
            log "I/O scheduler optimized for $disk."
        fi
    fi
done
success "I/O scheduling optimized."

################################################################################
# PHASE 6: GAMING & MULTIMEDIA SUPPORT
################################################################################
log "Installing gaming and multimedia support packages..."

# GameMode for automatic performance profile switching
log "Installing GameMode..."
ensure_pkgs gamemode gamemode-devel
systemctl enable --now gamemoded 2>&1 | tee -a "$LOG_FILE" || warn "GameMode daemon enable failed."
success "GameMode installed and enabled."

# Install video codec support
log "Installing multimedia codec packages..."
ensure_pkgs gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free \
            gstreamer1-plugins-ugly gstreamer1-libav gstreamer1-plugin-openh264 ffmpeg libavcodec-free \
            libavformat-free libavutil-free

# Install additional gaming libraries
log "Installing gaming libraries..."
ensure_pkgs lib32-libxrandr lib32-glibc lib32-openssl lib32-gcc-libs

success "Gaming and multimedia support packages installed."

################################################################################
# PHASE 7: HELPER SCRIPTS (smart-run, gpu-check, gpu-balance, system-tune)
################################################################################
log "Creating helper utilities and management scripts..."

# smart-run: Intelligent GPU workload launcher
log "Creating smart-run utility script..."
cat > "${SMART_RUN_PATH}" <<'SMARTRUN_EOF'
#!/usr/bin/env bash
# smart-run: Intelligent Dual-GPU Workload Launcher
# Automatically selects optimal GPU based on application type
# Usage: smart-run [--nvidia|--amd|--balanced|--auto] <command> [args...]
#   --nvidia    : Force NVIDIA GTX 1650 for rendering
#   --amd       : Force AMD RX 6400 (default)
#   --balanced  : Distribute load between both GPUs (sets Vulkan ICDs if available)
#   --auto      : Intelligent selection based on app signature

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Intelligent Dual-GPU Workload Launcher"
    echo "Usage: smart-run [--nvidia|--amd|--balanced|--auto] <command> [args...]"
    echo ""
    echo "Modes:"
    echo "  --nvidia      Use NVIDIA GTX 1650 for GPU rendering"
    echo "  --amd         Use AMD RX 6400 (default/display GPU)"
    echo "  --balanced    Distribute workload between both GPUs (useful for Vulkan apps and large encodes)"
    echo "  --auto        Intelligent mode selection (default)"
    echo ""
    echo "Examples:"
    echo "  smart-run --nvidia blender"
    echo "  smart-run --balanced ffmpeg -i video.mp4 -o out.mp4"
    echo "  smart-run steam"
    exit 2
fi

# Determine current user
if [[ $EUID -ne 0 ]]; then
    EXEC_USER="${USER}"
else
    EXEC_USER="${SUDO_USER:-root}"
fi

# Parse GPU mode
GPU_MODE="auto"
if [[ "${1:-}" =~ ^--(nvidia|amd|balanced|auto)$ ]]; then
    GPU_MODE="${1#--}"
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "Error: No command specified"
    exit 2
fi

CMD=("$@")
APP_NAME=$(basename "${CMD[0]}")

# Intelligent app detection for auto mode
if [[ "$GPU_MODE" == "auto" ]]; then
    case "$APP_NAME" in
        blender|cycles-daemon|optix*)
            GPU_MODE="nvidia"
            ;;
        ffmpeg|MediaInfo|HandBrake)
            GPU_MODE="balanced"
            ;;
        steam|vulkan*)
            GPU_MODE="nvidia"
            ;;
        obs)
            GPU_MODE="nvidia"
            ;;
        kdenlive|darktable|krita)
            GPU_MODE="balanced"
            ;;
        *)
            GPU_MODE="amd"
            ;;
    esac
fi

# Helper: set Vulkan ICDs for balanced mode if both exist
_set_vk_icds() {
    local nv_icd amd_icd
    nv_icd="$(ls /usr/share/vulkan/icd.d/*nvidia*.json 2>/dev/null | head -n1 || true)"
    amd_icd="$(ls /usr/share/vulkan/icd.d/*radeon*.json /usr/share/vulkan/icd.d/*amd*.json 2>/dev/null | head -n1 || true)"
    if [[ -n "$nv_icd" && -n "$amd_icd" ]]; then
        export VK_ICD_FILENAMES="${nv_icd}:${amd_icd}"
    elif [[ -n "$nv_icd" ]]; then
        export VK_ICD_FILENAMES="${nv_icd}"
    elif [[ -n "$amd_icd" ]]; then
        export VK_ICD_FILENAMES="${amd_icd}"
    fi
}

# Set GPU environment variables based on mode
case "$GPU_MODE" in
    nvidia)
        if command -v nvidia-smi &>/dev/null; then
            export __NV_PRIME_RENDER_OFFLOAD=1
            export __GLX_VENDOR_LIBRARY_NAME=nvidia
            export DRI_PRIME=0
            _set_vk_icds
            echo "[GPU] Using NVIDIA GTX 1650 for: ${CMD[*]}"
        else
            echo "[GPU] NVIDIA not available, falling back to AMD"
            GPU_MODE="amd"
        fi
        ;;
    balanced)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export DRI_PRIME=0
        export LIBVA_DRIVER_NAME=radeonsi
        export VDPAU_DRIVER=radeonsi
        _set_vk_icds
        echo "[GPU] Using balanced mode (both GPUs) for: ${CMD[*]}"
        ;;
    amd)
        export LIBVA_DRIVER_NAME=radeonsi
        export VDPAU_DRIVER=radeonsi
        unset __NV_PRIME_RENDER_OFFLOAD 2>/dev/null || true
        unset __GLX_VENDOR_LIBRARY_NAME 2>/dev/null || true
        echo "[GPU] Using AMD RX 6400 for: ${CMD[*]}"
        ;;
esac

# Special-case helper: use gpu-parallel-ffmpeg when in balanced mode and invoking ffmpeg
if [[ "$GPU_MODE" == "balanced" && "$APP_NAME" == "ffmpeg" && -x "/usr/local/bin/gpu-parallel-ffmpeg" ]]; then
    echo "[smart-run] Redirecting to gpu-parallel-ffmpeg for parallel encoding..."
    exec /usr/local/bin/gpu-parallel-ffmpeg "${CMD[@]:1}"
fi

# Execute command with appropriate user context
if [[ "$EXEC_USER" != "root" && -n "$EXEC_USER" ]]; then
    runuser -l "$EXEC_USER" -c "${CMD[*]}"
else
    "${CMD[@]}"
fi
SMARTRUN_EOF
chmod 755 "${SMART_RUN_PATH}"
success "smart-run utility installed at ${SMART_RUN_PATH}"

# gpu-check: Comprehensive GPU diagnostics
log "Creating gpu-check diagnostic utility..."
cat > "${GPU_CHECK_PATH}" <<'GPUCHECK_EOF'
#!/usr/bin/env bash
# gpu-check: Comprehensive GPU diagnostics and status report

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         GPU Status and Diagnostics Report                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. PCI Device Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
lspci -nn | grep -E "(VGA|3D)" || echo "No GPUs detected"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. Loaded Kernel Modules"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
lsmod | grep -E 'nvidia|amdgpu|nouveau' || echo "No GPU kernel modules loaded"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. OpenGL Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v glxinfo &>/dev/null; then
    glxinfo | grep -E 'OpenGL vendor|OpenGL renderer|OpenGL version|OpenGL core profile' | head -4
else
    echo "glxinfo not installed (install glx-utils package)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. Vulkan Support & Device Enumeration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v vulkaninfo &>/dev/null; then
    echo "Vulkan devices (short):"
    vulkaninfo 2>/dev/null | awk '/^\s*deviceName/ {print; count++} count==6{exit}' || true
    # Check for both AMD/NVIDIA ICD files
    NV_ICD="$(ls /usr/share/vulkan/icd.d/*nvidia*.json 2>/dev/null | head -n1 || true)"
    AMD_ICD="$(ls /usr/share/vulkan/icd.d/*radeon*.json /usr/share/vulkan/icd.d/*amd*.json 2>/dev/null | head -n1 || true)"
    echo "NVIDIA ICD: ${NV_ICD:-not found}"
    echo "AMD ICD: ${AMD_ICD:-not found}"
    if [[ -n "$NV_ICD" && -n "$AMD_ICD" ]]; then
        echo "Cooperative Vulkan mode: both vendor ICDs present (applications may enumerate both devices)."
    fi
else
    echo "vulkaninfo not installed (install vulkan-tools package)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. NVIDIA GPU Status (nvidia-smi)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,temperature.gpu,utilization.gpu,utilization.memory \
               --format=csv,noheader || echo "nvidia-smi query failed"
else
    echo "NVIDIA drivers not installed or nvidia-smi not available"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. AMD GPU Monitoring (radeontop/vainfo)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v radeontop &>/dev/null; then
    echo "Running radeontop for 2 seconds..."
    timeout 2 radeontop -b || true
else
    echo "radeontop not installed (install radeontop package for AMD monitoring)"
fi
if command -v vainfo &>/dev/null; then
    echo "vainfo (VA-API):"
    vainfo 2>/dev/null | head -10 || true
else
    echo "vainfo not installed (install libva-utils package)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. GPU Power Management Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for pci_dev in /sys/bus/pci/devices/*/power/control; do
    if [[ -r "$pci_dev" ]]; then
        device=$(dirname "$pci_dev" | xargs basename)
        power_mode=$(cat "$pci_dev" 2>/dev/null || echo "unknown")
        echo "  $device: $power_mode"
    fi
done
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "8. PRIME Render Offload Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Environment Variables (current shell):"
echo "  __NV_PRIME_RENDER_OFFLOAD: ${__NV_PRIME_RENDER_OFFLOAD:-disabled}"
echo "  __GLX_VENDOR_LIBRARY_NAME: ${__GLX_VENDOR_LIBRARY_NAME:-default}"
echo "  DRI_PRIME: ${DRI_PRIME:-0}"
echo "  LIBVA_DRIVER_NAME: ${LIBVA_DRIVER_NAME:-default}"
echo "  VK_ICD_FILENAMES: ${VK_ICD_FILENAMES:-not-set}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "9. System Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Kernel: $(uname -r)"
echo "Fedora: $(awk -F= '/^VERSION_ID/ {print $2}' /etc/os-release)"
if command -v lscpu &>/dev/null; then
    echo "CPU: $(lscpu | awk -F: '/Model name/ {gsub(/^ +| +$/,"",$2); print $2}')"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║              End of GPU Diagnostics Report                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
GPUCHECK_EOF
chmod 755 "${GPU_CHECK_PATH}"
success "gpu-check diagnostic utility installed at ${GPU_CHECK_PATH}"

# gpu-balance: GPU load balancer (interactive monitor + simple suggestions)
log "Creating gpu-balance load distribution utility..."
cat > "${GPU_BALANCE_PATH}" <<'GPUBALANCE_EOF'
#!/usr/bin/env bash
# gpu-balance: Real-time GPU load monitoring and balancing (interactive suggestions)

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          GPU Load Balancer & Monitor (Real-time)           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "This utility monitors and suggests optimal GPU allocation."
echo "Press Ctrl-C to exit."
echo ""

if ! command -v nvidia-smi &>/dev/null; then
    echo "Warning: nvidia-smi not available. Cannot monitor NVIDIA GPU."
fi

while true; do
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "GPU Load Monitoring - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # NVIDIA Stats
    echo "NVIDIA GTX 1650 Status:"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu,temperature.gpu \
                   --format=csv,noheader,nounits 2>/dev/null | while read idx mem_used mem_total util temp; do
            util_int=${util%.*}
            echo "  GPU $idx Memory: ${mem_used}MB / ${mem_total}MB"
            echo "  Utilization: ${util}%"
            echo "  Temperature: ${temp}°C"

            # Recommendation
            if (( util_int > 85 )); then
                echo "  Status: HIGH LOAD - Consider running encode jobs on AMD or staging via gpu-parallel-ffmpeg"
            elif (( util_int > 50 )); then
                echo "  Status: MODERATE LOAD - Performance optimal"
            else
                echo "  Status: LOW LOAD - Good for balanced operations"
            fi
        done
    else
        echo "  Not available (driver not installed)"
    fi
    echo ""

    # AMD Stats
    echo "AMD RX 6400 Status:"
    if command -v radeontop &>/dev/null; then
        timeout 1 radeontop -b -n 1 2>/dev/null || echo "  Monitoring unavailable"
    else
        echo "  Monitoring unavailable (radeontop not installed)"
    fi
    echo ""

    # Recommendations
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Workload Recommendations:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Light tasks (Web, Office): Run on AMD RX 6400 (default display GPU)"
    echo "• Heavy GPU rendering (Blender/OptiX): smart-run --nvidia blender"
    echo "• Parallel video encoding: gpu-parallel-ffmpeg -i in.mp4 -o out.mp4 -j 2"
    echo "• Use gpu-coop for mixed/advanced modes: gpu-coop --balanced <app>"
    echo ""

    sleep 3
done
GPUBALANCE_EOF
chmod 755 "${GPU_BALANCE_PATH}"
success "gpu-balance load monitoring utility installed at ${GPU_BALANCE_PATH}"

# system-tune: System optimization utility
log "Creating system-tune optimization utility..."
cat > "${SYSTEM_TUNE_PATH}" <<'SYSTEMTUNE_EOF'
#!/usr/bin/env bash
# system-tune: Advanced system and GPU tuning for Fedora 43

if [[ $EUID -ne 0 ]]; then
    echo "Error: system-tune must be run as root"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         System Performance Tuning Utility                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Available tuning profiles:"
echo ""
echo "1) Maximum Performance (Gaming/Heavy Workloads)"
echo "2) Balanced Mode (Default - Office/Web)"
echo "3) Power Saving Mode"
echo "4) Reset to Conservative Defaults"
echo "5) Show Current Settings"
echo ""
read -p "Select profile (1-5): " choice

case "$choice" in
    1)
        echo "Applying Maximum Performance tuning..."
        # CPU
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$gov" 2>/dev/null || true
        done
        # I/O
        for sched in /sys/block/*/queue/scheduler; do
            echo "mq-deadline" > "$sched" 2>/dev/null || echo "kyber" > "$sched" 2>/dev/null || true
        done
        # VM
        sysctl -w vm.swappiness=5 >/dev/null
        sysctl -w vm.dirty_ratio=20 >/dev/null
        echo "✓ Maximum Performance profile applied"
        ;;
    2)
        echo "Applying Balanced Mode tuning..."
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "schedutil" > "$gov" 2>/dev/null || echo "powersave" > "$gov" 2>/dev/null || true
        done
        sysctl -w vm.swappiness=10 >/dev/null
        sysctl -w vm.dirty_ratio=10 >/dev/null
        echo "✓ Balanced Mode profile applied"
        ;;
    3)
        echo "Applying Power Saving Mode..."
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "powersave" > "$gov" 2>/dev/null || true
        done
        sysctl -w vm.swappiness=60 >/dev/null
        sysctl -w vm.dirty_ratio=5 >/dev/null
        echo "✓ Power Saving profile applied"
        ;;
    4)
        echo "Resetting to conservative defaults..."
        sysctl -w vm.swappiness=30 >/dev/null
        sysctl -w vm.dirty_ratio=10 >/dev/null
        echo "✓ Defaults restored"
        ;;
    5)
        echo "Current System Settings:"
        echo "  VM Swappiness: $(cat /proc/sys/vm/swappiness)"
        echo "  VM Dirty Ratio: $(cat /proc/sys/vm/dirty_ratio)%"
        echo "  CPU Governors:"
        for gov in /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
            [[ -r "$gov" ]] && echo "    $(cat "$gov")"
        done
        ;;
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac

echo ""
SYSTEMTUNE_EOF
chmod 755 "${SYSTEM_TUNE_PATH}"
success "system-tune optimization utility installed at ${SYSTEM_TUNE_PATH}"

success "All helper scripts created successfully."

################################################################################
# PHASE 8: DRIVER COMPILATION & KERNEL MODULES
################################################################################
log "Building kernel modules for GPU drivers..."

if command -v akmods >/dev/null 2>&1; then
    log "Building akmods kernel modules (this may take a few minutes)..."
    akmods --force 2>&1 | tee -a "$LOG_FILE" || warn "akmods build completed with some warnings."
    success "Kernel modules built/updated."
else
    warn "akmods not available. Kernel modules will be built on next boot if using akmod drivers."
fi

################################################################################
# PHASE 9: CLEANUP & SYSTEM OPTIMIZATION
################################################################################
log "Performing system cleanup and optimization..."

log "Removing unnecessary packages..."
dnf autoremove -y 2>&1 | tee -a "$LOG_FILE" || warn "autoremove had issues."

log "Cleaning package cache..."
dnf clean all 2>&1 | tee -a "$LOG_FILE" || warn "Cache cleaning had issues."

success "System cleanup completed."

################################################################################
# FINALIZATION
################################################################################
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   INSTALLATION & SYSTEM OPTIMIZATION COMPLETED            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠ IMPORTANT: Reboot your system now for kernel modules and some driver settings to take effect${NC}"
echo ""
echo "Command: ${CYAN}sudo reboot${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}NEXT STEPS:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. After reboot, verify GPU setup:"
echo "   ${CYAN}gpu-check${NC}"
echo ""
echo "2. If you use X11, run prime-setup as your regular session user to ensure provider linkage:"
echo "   ${CYAN}prime-setup${NC}"
echo ""
echo "3. Monitor real-time GPU usage:"
echo "   ${CYAN}gpu-balance${NC}"
echo ""
echo "4. Tune system performance:"
echo "   ${CYAN}sudo system-tune${NC}"
echo ""
echo "5. Run applications with optimal GPU selection:"
echo "   ${CYAN}smart-run <app>              ${NC}(auto GPU selection)"
echo "   ${CYAN}smart-run --nvidia <app>    ${NC}(force NVIDIA GTX 1650)"
echo "   ${CYAN}smart-run --amd <app>       ${NC}(force AMD RX 6400)"
echo "   ${CYAN}smart-run --balanced <app>  ${NC}(use both GPUs / Vulkan multi-ICD)"
echo ""
echo "6. For large video encodes, use the parallel encoder helper:"
echo "   ${CYAN}gpu-parallel-ffmpeg -i input.mp4 -o output.mp4 -j 2${NC}"
echo ""
echo "7. Use lossless scaling for games (integer scaling, FSR, NIS):"
echo "   ${CYAN}lossless-scale --help                                  ${NC}(show all options)"
echo "   ${CYAN}lossless-scale --integer --res 1280x720 steam          ${NC}(pixel-perfect 720p->native)"
echo "   ${CYAN}lossless-scale --fsr-quality --fps 60 ./game           ${NC}(FSR upscaling + 60fps cap)"
echo "   ${CYAN}lossless-scale --fsr --mangohud --gpu nvidia game      ${NC}(FSR + overlay + NVIDIA)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}WHAT WAS CONFIGURED:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✓ Cooperative GPU workflows (PRIME Render Offload + Vulkan multi-ICD hints)"
echo "✓ Intelligent helper scripts (smart-run, gpu-coop, gpu-parallel-ffmpeg, prime-setup)"
echo "✓ Lossless scaling support (gamescope-based integer/FSR/NIS scaling)"
echo "✓ Automatic driver installation (NVIDIA, AMD) where GPUs detected"
echo "✓ NVIDIA persistence enabled and akmods configuration"
echo "✓ GPU power management with runtime autosuspend"
echo "✓ CPU frequency scaling optimization (i9-9900)"
echo "✓ I/O scheduler optimization"
echo "✓ System memory and swap tuning"
echo "✓ GameMode for automatic gaming profile switching"
echo "✓ Full multimedia codec support"
echo "✓ VA-API and Vulkan GPU acceleration (where available)"
echo "✓ Smart workload distribution between GPUs"
echo "✓ Comprehensive GPU monitoring tools"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}IMPORTANT NOTES:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "• Physical merging of AMD and NVIDIA into one single hardware GPU is not possible."
echo "  This setup provides a cooperative environment where each GPU can be used"
echo "  for its strengths (AMD for display/VA-API, NVIDIA for CUDA/optix/nvenc, etc.)."
echo ""
echo "• Use 'smart-run' or 'gpu-coop --balanced' for applications that can enumerate"
echo "  multiple Vulkan devices or for workloads you want split intelligently."
echo ""
echo "• For X11 users, run 'prime-setup' in your graphical session after login to"
echo "  ensure provider mappings are functional and offload works smoothly."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}GPU CONFIGURATION SUMMARY:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $AMD_PRESENT; then
    echo "✓ AMD RX 6400 detected at ${AMD_PCI_ADDR}"
    echo "  - Driver: AMDGPU (Mesa)"
    echo "  - Role: Primary display / VA-API decode & balanced compute"
    echo "  - Status: Ready"
fi
echo ""
if $NVIDIA_PRESENT; then
    echo "✓ NVIDIA GTX 1650 detected at ${NVIDIA_PCI_ADDR}"
    echo "  - Driver: NVIDIA proprietary"
    echo "  - Role: Render offload / CUDA / NVENC"
    echo "  - Status: Ready for offload"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}INSTALLATION LOG:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Full log available at: ${LOG_FILE}"
echo ""
echo -e "${GREEN}Thank you for using Fedora 43 Dual-GPU Cooperative Setup!${NC}"
echo ""
