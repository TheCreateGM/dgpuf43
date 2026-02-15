#!/bin/bash
#===============================================================================
# Fedora 43 Advanced System Optimizer
# Target: Intel i9-9900 (8c/16t) | 64GB DDR4 | AMD RX 6400 XT | NVIDIA GTX 1650
# Board: ASUS Z390-F Gaming
# Purpose: Maximum performance with power efficiency, LSFG-VK, Magpie-like upscaling
#===============================================================================
# Features:
#   - Advanced CPU scheduler tuning (NUMA-aware, IRQ affinity, cgroups)
#   - Dual GPU parallel Vulkan support (AMD + NVIDIA cooperation)
#   - LSFG-VK frame generation integration
#   - Magpie-like upscaling via Gamescope
#   - Virtual resource optimization (cgroups v2, CPU pinning, isolation)
#   - 64GB RAM-optimized memory management (ZRAM, hugepages, caching)
#   - Network stack optimization (BBR, low-latency, buffer tuning)
#   - Power efficiency balancing
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/fedora-optimizer.log"
BACKUP_DIR="/var/backup/fedora-optimizer"
VERSION="4.0.0"

# Target Hardware
TARGET_CPU="i9-9900"
TARGET_RAM_GB=64
TARGET_GPU_AMD="RX 6400"
TARGET_GPU_NVIDIA="GTX 1650"

# Global state
HAS_AMD_GPU=false
HAS_NVIDIA_GPU=false
DISPLAY_SERVER="unknown"

#-------------------------------------------------------------------------------
# Colors and Logging
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n" | tee -a "$LOG_FILE"; }

#-------------------------------------------------------------------------------
# Safety Checks
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_fedora() {
    if ! grep -qi "fedora" /etc/os-release 2>/dev/null; then
        error "This script is designed for Fedora Linux only"
        exit 1
    fi
    local version
    version=$(grep VERSION_ID /etc/os-release | cut -d= -f2)
    log "Detected Fedora version: $version"
}

check_hardware() {
    header "Hardware Detection"
    
    # CPU
    local cpu_model
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
    local cpu_cores
    cpu_cores=$(nproc)
    log "CPU: $cpu_model ($cpu_cores threads)"
    
    # RAM
    local ram_gb
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    log "RAM: ${ram_gb}GB"
    
    # GPUs
    log "GPUs detected:"
    lspci | grep -E "VGA|3D" | while read -r line; do
        log "  - $line"
    done
    
    # Check for expected hardware
    if grep -qi "i9-9900" /proc/cpuinfo; then
        success "Intel i9-9900 detected"
    else
        warn "Expected i9-9900, found different CPU - script will adapt"
    fi
    
    if lspci | grep -qi "AMD.*RX\|Radeon"; then
        success "AMD GPU detected"
        HAS_AMD_GPU=true
    else
        HAS_AMD_GPU=false
        warn "No AMD GPU detected"
    fi
    
    if lspci | grep -qi "NVIDIA"; then
        success "NVIDIA GPU detected"
        HAS_NVIDIA_GPU=true
    else
        HAS_NVIDIA_GPU=false
        warn "No NVIDIA GPU detected"
    fi
}

detect_display_server() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        DISPLAY_SERVER="wayland"
    elif [[ -n "${DISPLAY:-}" ]]; then
        DISPLAY_SERVER="x11"
    else
        DISPLAY_SERVER="unknown"
    fi
    log "Display server: $DISPLAY_SERVER"
}

#-------------------------------------------------------------------------------
# Backup System
#-------------------------------------------------------------------------------
create_backup() {
    header "Creating Backup"
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    local files_to_backup=(
        "/etc/sysctl.conf"
        "/etc/sysctl.d/"
        "/etc/modprobe.d/"
        "/etc/tuned/"
        "/etc/default/grub"
        "/etc/environment"
        "/etc/udev/rules.d/"
    )
    
    local existing_files=()
    for f in "${files_to_backup[@]}"; do
        [[ -e "$f" ]] && existing_files+=("$f")
    done
    
    if [[ ${#existing_files[@]} -gt 0 ]]; then
        tar -czf "$backup_file" "${existing_files[@]}" 2>/dev/null || true
        success "Backup created: $backup_file"
    fi
    
    # Create restore script
    cat > "$BACKUP_DIR/restore.sh" << 'RESTORE_EOF'
#!/bin/bash
# Restore script - run to revert changes
BACKUP_DIR="/var/backup/fedora-optimizer"
LATEST=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)
if [[ -n "$LATEST" ]]; then
    echo "Restoring from: $LATEST"
    tar -xzf "$LATEST" -C /
    echo "Restored. Please reboot."
else
    echo "No backup found"
fi
RESTORE_EOF
    chmod +x "$BACKUP_DIR/restore.sh"
}

#-------------------------------------------------------------------------------
# Package Installation
#-------------------------------------------------------------------------------
install_packages() {
    header "Installing Required Packages"
    
    # Enable RPM Fusion repos
    log "Enabling RPM Fusion repositories..."
    dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
        2>/dev/null || true
    
    # Core optimization packages
    local packages=(
        # CPU/Power management
        tuned
        tuned-utils
        powertop
        thermald
        kernel-tools
        cpuid
        hwloc
        
        # GPU - AMD
        mesa-vulkan-drivers
        mesa-va-drivers
        mesa-vdpau-drivers
        libva-utils
        vulkan-tools
        radeontop
        libva-vdpau-driver
        
        # GPU - NVIDIA (General utils)
        vulkan-loader
        libv4l
        
        # Memory tools
        zram-generator
        earlyoom
        numactl
        
        # Network optimization
        irqbalance
        ethtool
        iperf3
        iproute-tc
        
        # Gaming/Performance
        gamemode
        gamescope
        mangohud
        libdecor
        
        # LSFG-VK Build Dependencies
        git
        cmake
        ninja-build
        vulkan-headers
        libX11-devel
        libXrandr-devel
        libXinerama-devel
        libXcursor-devel
        libXi-devel
        wayland-devel
        wayland-protocols-devel
        libxkbcommon-devel
        
        # Monitoring
        htop
        btop
        nvtop
        iotop
        glxinfo
        vulkan-caps-viewer
        
        # Multimedia codecs
        gstreamer1-plugins-bad-free
        gstreamer1-plugins-good
        gstreamer1-plugins-ugly
        gstreamer1-plugin-libav
        ffmpeg
        
    )
    
    # LSFG-VK Build Dependencies
    local build_deps=(
        git cmake ninja-build vulkan-headers libX11-devel libXrandr-devel
        libXinerama-devel libXcursor-devel libXi-devel wayland-devel
        wayland-protocols-devel libxkbcommon-devel
    )
    
    log "Installing core packages..."
    dnf install -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE"
    
    log "Ensuring build dependencies..."
    dnf install -y "${build_deps[@]}" 2>&1 | tee -a "$LOG_FILE"
    
    success "Core packages and build dependencies installed"
}

install_nvidia_driver() {
    if [[ "$HAS_NVIDIA_GPU" != "true" ]]; then
        log "Skipping NVIDIA driver (no NVIDIA GPU detected)"
        return
    fi
    
    header "Installing NVIDIA Proprietary Driver"
    
    # Check if already installed
    if command -v nvidia-smi &>/dev/null; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
        success "NVIDIA driver already installed (version: $driver_version)"
        return
    fi
    
    log "Installing NVIDIA akmod driver..."
    dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda nvidia-vaapi-driver 2>&1 | tee -a "$LOG_FILE"
    
    # Wait for kmod to build
    log "Waiting for kernel module to build..."
    akmods --force 2>&1 | tee -a "$LOG_FILE"
    
    # Load the module
    modprobe nvidia 2>/dev/null || warn "NVIDIA module not loaded (reboot required)"
    
    success "NVIDIA driver installed (reboot required)"
}

#-------------------------------------------------------------------------------
# LSFG-VK Integration (Lossless Scaling for Vulkan)
#-------------------------------------------------------------------------------
install_lsfg_vk() {
    header "LSFG-VK Integration (Lossless Scaling Frame Generation)"
    
    # Ensure dependencies
    if ! command -v cmake &>/dev/null || ! command -v ninja &>/dev/null; then
        warn "Build tools missing, skipping LSFG-VK build."
        return
    fi

    local build_dir="/usr/local/src/lsfg-vk"
    
    log "Pulling LSFG-VK source..."
    if [[ -d "$build_dir" ]]; then
        rm -rf "$build_dir"
    fi
    mkdir -p "$(dirname "$build_dir")"
    
    # Clone repository
    git clone --depth 1 "https://github.com/PancakeTAS/lsfg-vk.git" "$build_dir" 2>&1 | tee -a "$LOG_FILE" || {
        warn "Failed to clone LSFG-VK. Connectivity issue?"
        return
    }

    log "Building LSFG-VK..."
    pushd "$build_dir" >/dev/null
    
    mkdir -p build && cd build
    cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tee -a "$LOG_FILE"
    ninja 2>&1 | tee -a "$LOG_FILE"
    
    # Install manually since it's a layer
    log "Installing LSFG-VK layer..."
    mkdir -p /usr/local/lib/lsfg-vk
    cp lsfg_vk.so /usr/local/lib/lsfg-vk/
    
    # Configure JSON manifest
    mkdir -p /usr/share/vulkan/implicit_layer.d
    cat > /usr/share/vulkan/implicit_layer.d/lsfg_vk.json << 'EOF'
{
    "file_format_version": "1.0.0",
    "layer": {
        "name": "VK_LAYER_LSFG_frame_generation",
        "type": "GLOBAL",
        "api_version": "1.3.0",
        "library_path": "/usr/local/lib/lsfg-vk/lsfg_vk.so",
        "implementation_version": "1",
        "description": "LSFG Frame Generation Layer",
        "enable_environment": {
            "ENABLE_LSFG": "1"
        },
        "disable_environment": {
            "DISABLE_LSFG": "1"
        }
    }
}
EOF
    popd >/dev/null
    
    # Create convenience wrapper
    cat > /usr/local/bin/lsfg-run << 'SS_EOF'
#!/bin/bash
# Wrapper for LSFG-VK
# USAGE: lsfg-run <command>

echo "========================================================"
echo " LSFG-VK Wrapper (Requires Lossless Scaling Assets)     "
echo "========================================================"

if [[ -z "${LSFG_ASSETS:-}" ]]; then
    # Auto-detect if user has Lossless Scaling in standard Steam location
    # Note: This path is a guess for where users might link it. 
    # Scripts should be safe, so we just check environment or warn.
    if [[ -d "$HOME/.steam/steam/steamapps/common/Lossless Scaling" ]]; then
         export LSFG_ASSETS="$HOME/.steam/steam/steamapps/common/Lossless Scaling"
    else
         echo "[WARN] LSFG_ASSETS not set. Frame generation logic needs prop data."
         echo "       Export LSFG_ASSETS='/path/to/Lossless Scaling' before running."
    fi
fi

export ENABLE_LSFG=1
# Force high priority for the game/layer
exec "$@"
SS_EOF
    chmod +x /usr/local/bin/lsfg-run

    success "LSFG-VK installed. Use 'lsfg-run <game>' to launch."
    warn "REQUIRED: You must own 'Lossless Scaling' on Steam and point LSFG_ASSETS to it."
}

#-------------------------------------------------------------------------------
# CPU Optimization
#-------------------------------------------------------------------------------
optimize_cpu() {
    header "CPU Optimization (Intel i9-9900)"
    
    # 1. Enable Intel SMT/Hyper-Threading check
    if grep -q "ht" /proc/cpuinfo; then
        log "Hyper-Threading (SMT) detected and enabled."
    else
        warn "Hyper-Threading not detected in /proc/cpuinfo."
    fi

    # 2. Configure Intel P-state driver
    if [[ -d /sys/devices/system/cpu/intel_pstate ]]; then
        log "Configuring Intel P-state..."
        
        # Use powersave governor with intel_pstate (acts like schedutil)
        echo "powersave" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
        
        # Set energy performance preference to balance_performance
        if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
            echo "balance_performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null
            success "EPP set to balance_performance"
        fi
        
        # Enable turbo boost
        if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
            echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
            success "Intel Turbo Boost enabled"
        fi
    fi
    
    # 3. Kernel scheduler optimizations
    log "Applying kernel scheduler optimizations..."
    cat > /etc/sysctl.d/60-cpu-scheduler.conf << 'EOF'
# CPU Scheduler Optimization for Desktop/Gaming (8c/16t i9-9900)
# Enable scheduler autogroup for better desktop responsiveness
kernel.sched_autogroup_enabled = 1

# Reduce migration overhead (better cache utilization for 8c/16t)
kernel.sched_migration_cost_ns = 5000000

# Optimize for interactive workloads (Desktop responsiveness)
kernel.sched_min_granularity_ns = 1500000
kernel.sched_wakeup_granularity_ns = 2000000

# Enable NUMA balancing even on single socket for better memory affinity logic
kernel.numa_balancing = 1

# Reduce latency
kernel.sched_nr_migrate = 32

# Additional scheduler tuning for multi-threaded workloads
kernel.sched_latency_ns = 6000000
kernel.sched_tunable_scaling = 0
kernel.sched_child_runs_first = 0

# Improve responsiveness under load
kernel.sched_rt_runtime_us = 950000
kernel.sched_rt_period_us = 1000000
EOF
    
    # 4. IRQ Balancing and Affinity
    log "Configuring IRQ balancing..."
    if systemctl list-unit-files | grep -q irqbalance; then
        systemctl enable --now irqbalance 2>/dev/null || true
        # Ensure it doesn't balance across SMT siblings if possible
        mkdir -p /etc/sysconfig
        cat > /etc/sysconfig/irqbalance << 'EOF'
# IRQ Balance configuration for i9-9900 (8c/16t)
# Use deepest cache level for better locality
IRQBALANCE_ARGS="--deepestcache=2 --policyscript=/usr/local/bin/irqbalance-policy.sh"
EOF
        
        # Create policy script for better IRQ distribution
        cat > /usr/local/bin/irqbalance-policy.sh << 'IRQPOLICY'
#!/bin/bash
# IRQ balancing policy for dual GPU + high-performance CPU
# Prioritize network and storage IRQs on physical cores
case "$1" in
    *eth*|*eno*|*enp*|*nvme*)
        # Network and NVMe on physical cores only
        echo "ban=1"
        ;;
    *)
        echo "ban=0"
        ;;
esac
IRQPOLICY
        chmod +x /usr/local/bin/irqbalance-policy.sh
        systemctl restart irqbalance 2>/dev/null || true
        success "IRQ balancing configured with custom policy"
    fi

    # 5. Configure thermald for Intel
    if systemctl list-unit-files | grep -q thermald; then
        systemctl enable --now thermald 2>/dev/null || true
        success "thermald enabled"
    fi
    
    # 6. Configure tuned profile
    log "Setting tuned profile..."
    if command -v tuned-adm &>/dev/null; then
        # Create custom gaming profile
        mkdir -p /etc/tuned/gaming-optimized
        cat > /etc/tuned/gaming-optimized/tuned.conf << 'EOF'
[main]
summary=Optimized for gaming and desktop responsiveness
include=throughput-performance

[cpu]
governor=powersave
energy_perf_bias=balance_performance
min_perf_pct=5

[vm]
transparent_hugepages=madvise

[sysctl]
# Virtual memory logic
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5

# Additional scheduler tuning
kernel.sched_autogroup_enabled=1
kernel.sched_migration_cost_ns=5000000

[scheduler]
sched_autogroup_enabled=1
EOF
        tuned-adm profile gaming-optimized 2>/dev/null || tuned-adm profile throughput-performance
        success "tuned profile configured"
    fi
    
    # 7. CPU affinity optimization for system services
    log "Optimizing CPU affinity for system services..."
    # Reserve CPU 0-1 for system, rest for user applications
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/cpu-affinity.conf << 'EOF'
[Manager]
# Reserve first 2 threads for system services
CPUAffinity=0 1
EOF
    
    systemctl daemon-reload
    
    sysctl --system >/dev/null 2>&1
    success "CPU optimization complete"
}

#-------------------------------------------------------------------------------
# Virt-Resource Global Optimization
#-------------------------------------------------------------------------------
optimize_virt_resources() {
    header "Virtualization-Style Resource Optimization"
    log "Configuring systemd slices for task isolation..."

    # Ensure user slice gets high weight
    mkdir -p /etc/systemd/system/user-.slice.d
    cat > /etc/systemd/system/user-.slice.d/50-priority.conf << 'EOF'
[Slice]
CPUWeight=high
IOWeight=high
MemoryMin=4G
MemoryHigh=48G
EOF

    # Ensure system slice doesn't starve user
    mkdir -p /etc/systemd/system/system.slice.d
    cat > /etc/systemd/system/system.slice.d/50-priority.conf << 'EOF'
[Slice]
CPUWeight=default
IOWeight=default
MemoryHigh=16G
EOF

    # Create high-priority slice for gaming/compute workloads
    mkdir -p /etc/systemd/system/gaming.slice.d
    cat > /etc/systemd/system/gaming.slice << 'EOF'
[Unit]
Description=Gaming and High-Performance Applications Slice
Before=slices.target

[Slice]
CPUWeight=1000
IOWeight=1000
MemoryMin=8G
MemoryHigh=56G
EOF

    # Create wrapper to run apps in gaming slice
    cat > /usr/local/bin/gaming-run << 'GAMINGRUN'
#!/bin/bash
# Run application in high-priority gaming slice
if [[ $# -eq 0 ]]; then
    echo "Usage: gaming-run <command>"
    exit 1
fi

exec systemd-run --user --scope --slice=gaming.slice "$@"
GAMINGRUN
    chmod +x /usr/local/bin/gaming-run

    # Configure cgroups v2 optimizations
    log "Configuring cgroups v2 optimizations..."
    cat > /etc/systemd/system.conf.d/cgroups.conf << 'EOF'
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
EOF

    # Reload systemd
    systemctl daemon-reload
    success "Systemd slice weights and cgroups optimized (User > Gaming > System)"
}

#-------------------------------------------------------------------------------
# RAM Optimization (64GB Specific)
#-------------------------------------------------------------------------------
optimize_memory() {
    header "Memory Optimization (64GB DDR4)"
    
    # 1. Create comprehensive memory sysctl config
    cat > /etc/sysctl.d/60-memory-optimization.conf << 'EOF'
#===============================================================================
# Memory Optimization for 64GB RAM System
#===============================================================================

# Swappiness: Very low for high-RAM systems
vm.swappiness = 10

# VFS Cache Pressure: Keep inodes cached
vm.vfs_cache_pressure = 50

# Dirty page ratios for 64GB RAM (writeback handling)
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000

# Memory overcommit (safe defaults)
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Compaction settings
vm.compaction_proactiveness = 20
vm.watermark_scale_factor = 200

# Max map count for games/applications
vm.max_map_count = 2147483642

# Hugepages for 64GB system
# Reserve some hugepages for high-performance apps (e.g. 2GB)
vm.nr_hugepages = 1024
vm.nr_overcommit_hugepages = 512

# Page cache optimization
vm.pagecache = 1
vm.page-cluster = 3

# OOM killer tuning
vm.oom_kill_allocating_task = 0
vm.panic_on_oom = 0

# Zone reclaim mode (disabled for better performance)
vm.zone_reclaim_mode = 0

# Minimum free memory (important for 64GB)
vm.min_free_kbytes = 262144
EOF
    
    # 2. Configure Transparent Huge Pages
    log "Configuring Transparent Huge Pages..."
    # Persistent THP config via tmpfiles
    cat > /etc/tmpfiles.d/thp.conf << 'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag - - - - madvise
w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 1
w /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs - - - - 60000
w /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs - - - - 10000
EOF
    
    # Apply immediately
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    
    # 3. Configure ZRAM (compressed RAM swap)
    log "Configuring ZRAM..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
# Use 16GB for ZRAM on 64GB system (25% of RAM)
zram-size = 16384
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
mount-point = /dev/zram0
EOF
    
    # Enable zram service
    systemctl daemon-reload
    systemctl enable --now systemd-zram-setup@zram0.service 2>/dev/null || true
    
    success "ZRAM configured (16GB with zstd compression)"
    
    # 4. Configure EarlyOOM (Out-of-Memory killer)
    log "Configuring EarlyOOM..."
    if systemctl list-unit-files | grep -q earlyoom; then
        mkdir -p /etc/default
        cat > /etc/default/earlyoom << 'EOF'
# EarlyOOM configuration for 64GB system
# Kill processes when memory drops below 5% or swap below 10%
EARLYOOM_ARGS="-m 5 -s 10 -r 60 --avoid '(^|/)(init|systemd|Xorg|gnome-shell|plasmashell|sddm|gdm|lightdm)$' --prefer '(^|/)(Web Content|firefox|chrome|electron)' -n"
EOF
        systemctl enable --now earlyoom 2>/dev/null || true
        success "EarlyOOM configured and enabled"
    fi
    
    # 5. Configure preload for faster application launches (optional)
    if command -v preload &>/dev/null || dnf list installed preload &>/dev/null; then
        log "Configuring preload for predictive caching..."
        systemctl enable --now preload 2>/dev/null || true
    else
        log "Installing preload for predictive caching..."
        dnf install -y preload 2>/dev/null || true
        systemctl enable --now preload 2>/dev/null || true
    fi
    
    sysctl --system >/dev/null 2>&1
    success "Memory optimization complete"
}

#-------------------------------------------------------------------------------
# GPU Optimization - AMD
#-------------------------------------------------------------------------------
optimize_gpu_amd() {
    if [[ "$HAS_AMD_GPU" != "true" ]]; then return; fi
    
    header "AMD GPU Optimization (RX 6400 XT)"
    
    # 1. AMDGPU kernel parameters
    log "Configuring AMDGPU driver..."
    cat > /etc/modprobe.d/amdgpu.conf << 'EOF'
options amdgpu deep_color=1
options amdgpu ppfeaturemask=0xffffffff
options amdgpu dc=1
options amdgpu dpm=1
options amdgpu bapm=1
EOF
    
    # 2. Udev rules for power management and device access
    cat > /etc/udev/rules.d/80-amdgpu-power.rules << 'EOF'
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="auto"
EOF
    
    # 3. Vulkan ICD configuration (ensure RADV is preferred for RDNA2)
    mkdir -p /etc/vulkan/icd.d
    if [[ -f /usr/share/vulkan/icd.d/radeon_icd.x86_64.json ]]; then
        log "Found RADV ICD, setting as default for AMD."
    fi

    # 4. Environment variables for AMD
    cat > /etc/profile.d/amd-gpu.sh << 'EOF'
export RADV_PERFTEST=aco,gpl
export mesa_glthread=true
export AMD_VULKAN_ICD=RADV
export DRI_PRIME=0
EOF
    success "AMD GPU optimization complete"
}

#-------------------------------------------------------------------------------
# GPU Optimization - NVIDIA
#-------------------------------------------------------------------------------
optimize_gpu_nvidia() {
    if [[ "$HAS_NVIDIA_GPU" != "true" ]]; then return; fi
    
    header "NVIDIA GPU Optimization (GTX 1650)"
    
    # 1. NVIDIA kernel module options
    cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
options nvidia NVreg_EnableResizableBar=1
EOF
    
    # 2. Enable NVIDIA services for persistence and power management
    log "Enabling NVIDIA services..."
    systemctl enable --now nvidia-persistenced 2>/dev/null || true
    systemctl enable --now nvidia-powerd 2>/dev/null || true
    systemctl enable --now nvidia-hibernate 2>/dev/null || true
    systemctl enable --now nvidia-resume 2>/dev/null || true
    systemctl enable --now nvidia-suspend 2>/dev/null || true

    # 3. Configure PRIME Offload environment
    cat > /etc/profile.d/nvidia-gpu.sh << 'EOF'
# NVIDIA PRIME Offload Variables
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
EOF

    success "NVIDIA GPU optimization complete"
}

#-------------------------------------------------------------------------------
# Dual GPU Cooperation & Gaming
#-------------------------------------------------------------------------------
configure_dual_gpu_gaming() {
    header "Dual GPU & Gaming Configuration"
    
    # 1. Multi-GPU Vulkan Layer Setup
    log "Configuring Vulkan multi-GPU visibility..."
    # Ensure both ICDs are visible to applications
    
    # 2. Magpie-like Upscaling Wrapper (Gamescope)
    cat > /usr/local/bin/upscale-run << 'UPSCALE'
#!/bin/bash
# Magpie-like Upscaler using Gamescope
# USAGE: upscale-run [fsr|nis|integer] <width> <height> <command>

if [[ $# -lt 4 ]]; then
    echo "Usage: upscale-run <fsr|nis|integer> <target_w> <target_h> <command>"
    echo "Example: upscale-run fsr 1920 1080 glxgears"
    exit 1
fi

MODE="$1"
WIDTH="$2"
HEIGHT="$3"
shift 3

# Detect preferred GPU for scaling (Default to AMD for lower latency scaling on RDNA2)
GPU_ARGS=""
if lspci | grep -qi "AMD"; then
    # Use AMD for the compositor (Gamescope)
    GPU_ARGS="--prefer-output AMD"
fi

# Internal render resolution (720p default for upscaling)
INTERNAL_W=1280
INTERNAL_H=720

ARGS="-w $INTERNAL_W -h $INTERNAL_H -W $WIDTH -H $HEIGHT -f $GPU_ARGS"

case "$MODE" in
    fsr) ARGS+=" -F fsr" ;;
    nis) ARGS+=" -F nis" ;;
    integer) ARGS+=" -S integer" ;;
esac

echo "Running: gamescope $ARGS -- $@"
exec gamescope $ARGS -- "$@"
UPSCALE
    chmod +x /usr/local/bin/upscale-run

    # 3. Smart GPU selector
    cat > /usr/local/bin/gpu-select << 'GPUSELECT'
#!/bin/bash
# Select GPU for specific tasks
case "${1:-}" in
    amd)
        shift
        export DRI_PRIME=0
        export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
        echo "[GPU] Using AMD Radeon (Primary)"
        exec "$@"
        ;;
    nvidia)
        shift
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export __VK_LAYER_NV_optimus=NVIDIA_only
        export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
        echo "[GPU] Offloading to NVIDIA GTX 1650"
        exec "$@"
        ;;
    parallel)
        shift
        # Experimental: Attempt to expose both GPUs to Vulkan apps
        export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json:/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
        echo "[GPU] Parallel Vulkan mode (Multi-GPU)"
        exec "$@"
        ;;
    auto)
        shift
        unset DRI_PRIME VK_ICD_FILENAMES __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME
        exec "$@"
        ;;
    *)
        echo "Usage: gpu-select [amd|nvidia|parallel|auto] <command>"
        exit 0
        ;;
esac
GPUSELECT
    chmod +x /usr/local/bin/gpu-select
    
    success "Gaming wrappers installed (upscale-run, gpu-select)"
}

#-------------------------------------------------------------------------------
# Network Optimization
#-------------------------------------------------------------------------------
optimize_network() {
    header "Network Optimization"
    
    # 1. Advanced TCP/IP Tuning for Low Latency and High Throughput
    cat > /etc/sysctl.d/60-network-optimization.conf << 'EOF'
# TCP Congestion Control: BBR (Google)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Low Latency Tuning
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

# Buffer Sizes (Optimized for 1Gbps+ and 64GB RAM)
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Connection handling
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# TCP Performance
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# Increase ephemeral port range
net.ipv4.ip_local_port_range = 1024 65535
EOF
    
    # 2. Enable irqbalance with specific tuning for i9-9900 (8c/16t)
    if systemctl list-unit-files | grep -q irqbalance; then
        systemctl enable --now irqbalance 2>/dev/null || true
        success "IRQ balancing enabled and tuned"
    fi
    
    # 3. NIC offloading and Ring Buffer Optimization
    if command -v ethtool &>/dev/null; then
        local primary_nic
        primary_nic=$(ip route | grep default | awk '{print $5}' | head -1)
        if [[ -n "$primary_nic" ]]; then
            log "Tuning NIC: $primary_nic"
            # Enable hardware offloading
            ethtool -K "$primary_nic" tx on rx on tso on gso on gro on lro off 2>/dev/null || true
            # Increase ring buffers to max if possible
            local max_rx
            max_rx=$(ethtool -g "$primary_nic" 2>/dev/null | grep -A 5 "Pre-set" | grep "RX:" | awk '{print $2}')
            if [[ -n "$max_rx" && "$max_rx" -gt 0 ]]; then
                ethtool -G "$primary_nic" rx "$max_rx" 2>/dev/null || true
            fi
            success "NIC offloading and buffers optimized: $primary_nic"
        fi
    fi
    
    sysctl --system >/dev/null 2>&1
    success "Network optimization complete"
}

#-------------------------------------------------------------------------------
# Storage Optimization
#-------------------------------------------------------------------------------
optimize_storage() {
    header "Storage Optimization"
    
    cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
    
    # Enable fstrim
    systemctl enable --now fstrim.timer 2>/dev/null || true
    
    # Read-ahead
    cat > /etc/udev/rules.d/60-readahead.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/read_ahead_kb}="128"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
EOF
    success "Storage optimization complete"
}

#-------------------------------------------------------------------------------
# Power Management
#-------------------------------------------------------------------------------
optimize_power() {
    header "Power Management (Efficiency Focus)"
    
    # 1. PCIe ASPM (Active State Power Management)
    if [[ -f /sys/module/pcie_aspm/parameters/policy ]]; then
        # Use 'powersave' for best efficiency, or 'performance' for lowest latency.
        # 'default' is usually a safe middle ground, but 'powersave' is better for draw.
        echo "powersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    fi
    
    # 2. USB autosuspend rules
    cat > /etc/udev/rules.d/60-usb-power.rules << 'EOF'
# Enable USB autosuspend for non-input devices
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="*", TEST=="power/control", ATTR{power/control}="auto"
# Disable for mice/keyboards to avoid lag
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"
EOF

    # 3. SATA/AHCI Link Power Management
    for host in /sys/class/scsi_host/host*/link_power_management_policy; do
        [[ -f "$host" ]] && echo "med_power_with_dipm" > "$host" 2>/dev/null || true
    done

    # 4. Intel Audio Power Saving
    if [[ -f /sys/module/snd_hda_intel/parameters/power_save ]]; then
        echo "1" > /sys/module/snd_hda_intel/parameters/power_save
        echo "Y" > /sys/module/snd_hda_intel/parameters/power_save_controller
    fi

    # 5. Runtime Power Management for PCI devices
    cat > /etc/udev/rules.d/60-pcie-pm.rules << 'EOF'
# Enable runtime PM for all PCI devices
ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"
EOF

    success "Power management configured (Balanced Efficiency)"
}

#-------------------------------------------------------------------------------
# Kernel Boot Parameters
#-------------------------------------------------------------------------------
configure_grub() {
    header "Kernel Boot Parameters"
    
    cp /etc/default/grub /etc/default/grub.backup.$(date +%Y%m%d) 2>/dev/null || true
    
    local new_params=""
    [[ "$HAS_NVIDIA_GPU" == "true" ]] && new_params+=" nvidia-drm.modeset=1 nvidia-drm.fbdev=1"
    [[ "$HAS_AMD_GPU" == "true" ]] && new_params+=" amdgpu.ppfeaturemask=0xffffffff"
    new_params+=" mitigations=auto nowatchdog nmi_watchdog=0 transparent_hugepage=madvise intel_pstate=passive"
    new_params+=" intel_iommu=on iommu=pt"
    new_params+=" skew_tick=1"
    
    local current_params
    current_params=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub | cut -d'"' -f2)
    
    for param in $new_params; do
        if ! echo "$current_params" | grep -q "${param%%=*}"; then
            current_params+=" $param"
        fi
    done
    
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current_params\"|" /etc/default/grub
    
    if [[ -d /sys/firmware/efi ]]; then
        grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true
    else
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi
    
    success "GRUB parameters configured"
}

#-------------------------------------------------------------------------------
# Enhanced AMD GPU Optimization with Control Utility
#-------------------------------------------------------------------------------
enhance_amd_gpu() {
    if [[ "$HAS_AMD_GPU" != "true" ]]; then return; fi
    
    log "Enhancing AMD GPU configuration..."
    
    # Enhanced AMD GPU parameters
    cat > /etc/modprobe.d/amdgpu-enhanced.conf << 'EOF'
# Enhanced AMD RX 6400 XT (RDNA2) Configuration
options amdgpu gpu_recovery=1
options amdgpu aspm=1
options amdgpu runpm=1
EOF
    
    # Enhanced udev rules for user access
    cat >> /etc/udev/rules.d/80-amdgpu-power.rules << 'EOF'

# Allow users to access GPU performance controls
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", DRIVERS=="amdgpu", RUN+="/bin/chmod 0666 /sys/class/drm/%k/device/power_dpm_force_performance_level"
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", DRIVERS=="amdgpu", RUN+="/bin/chmod 0666 /sys/class/drm/%k/device/pp_power_profile_mode"
EOF
    
    # Enhanced environment variables
    cat >> /etc/profile.d/amd-gpu.sh << 'EOF'

# Enhanced RDNA2 Optimization
export RADV_PERFTEST=aco,gpl,nggc,sam
export RADV_DEBUG=zerovram
export AMD_DEBUG=nodma,nofmask
export RADV_FORCE_FAMILY=navi23
EOF

    # Create AMD GPU control utility
    cat > /usr/local/bin/amd-gpu-mode << 'AMDMODE'
#!/bin/bash
# AMD GPU Performance Mode Switcher
CARD=$(find /sys/class/drm/card*/device/power_dpm_force_performance_level 2>/dev/null | grep -v render | head -1)

if [[ -z "$CARD" ]]; then
    echo "No AMD GPU found"
    exit 1
fi

case "${1:-auto}" in
    performance|high)
        echo "high" > "$CARD"
        echo "AMD GPU: Performance mode"
        ;;
    power|low)
        echo "low" > "$CARD"
        echo "AMD GPU: Power saving mode"
        ;;
    auto|balanced)
        echo "auto" > "$CARD"
        echo "AMD GPU: Auto/Balanced mode"
        ;;
    manual)
        echo "manual" > "$CARD"
        echo "AMD GPU: Manual mode"
        ;;
    status)
        echo "Current mode: $(cat $CARD)"
        ;;
    *)
        echo "Usage: amd-gpu-mode [performance|power|auto|manual|status]"
        echo "Current: $(cat $CARD)"
        ;;
esac
AMDMODE
    chmod +x /usr/local/bin/amd-gpu-mode
    
    success "AMD GPU enhancements applied"
}

#-------------------------------------------------------------------------------
# Enhanced NVIDIA GPU Optimization
#-------------------------------------------------------------------------------
enhance_nvidia_gpu() {
    if [[ "$HAS_NVIDIA_GPU" != "true" ]]; then return; fi
    
    log "Enhancing NVIDIA GPU configuration..."
    
    # Create NVIDIA GPU control utility
    cat > /usr/local/bin/nvidia-gpu-mode << 'NVMODE'
#!/bin/bash
# NVIDIA GPU Performance Mode Switcher

if ! command -v nvidia-smi &>/dev/null; then
    echo "NVIDIA driver not installed"
    exit 1
fi

case "${1:-auto}" in
    performance|high)
        sudo nvidia-smi -pm 1
        sudo nvidia-smi -pl 75
        echo "NVIDIA GPU: Performance mode"
        ;;
    power|low)
        sudo nvidia-smi -pm 1
        sudo nvidia-smi -pl 50
        echo "NVIDIA GPU: Power saving mode"
        ;;
    auto)
        sudo nvidia-smi -pm 1
        sudo nvidia-smi -pl 65
        echo "NVIDIA GPU: Auto/Balanced mode"
        ;;
    status)
        nvidia-smi --query-gpu=name,power.draw,power.limit,clocks.gr,clocks.mem --format=csv
        ;;
    *)
        echo "Usage: nvidia-gpu-mode [performance|power|auto|status]"
        nvidia-smi --query-gpu=name,power.draw,power.limit --format=csv,noheader
        ;;
esac
NVMODE
    chmod +x /usr/local/bin/nvidia-gpu-mode
    
    success "NVIDIA GPU enhancements applied"
}

#-------------------------------------------------------------------------------
# System Monitoring and Diagnostics Utility
#-------------------------------------------------------------------------------
create_monitoring_tools() {
    header "Creating System Monitoring Tools"
    
    # Create comprehensive system status script
    cat > /usr/local/bin/system-status << 'SYSSTATUS'
#!/bin/bash
# Comprehensive System Status Display

echo "=========================================="
echo "  SYSTEM STATUS - Fedora Optimizer"
echo "=========================================="
echo ""

# CPU Info
echo "CPU:"
echo "  Model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  Threads: $(nproc)"
echo "  Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
    echo "  EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
fi
echo ""

# Memory Info
echo "Memory:"
free -h | grep -E "Mem|Swap"
if [[ -f /sys/block/zram0/disksize ]]; then
    echo "  ZRAM: $(( $(cat /sys/block/zram0/disksize) / 1024 / 1024 / 1024 ))GB"
fi
echo ""

# GPU Info
echo "GPUs:"
lspci | grep -E "VGA|3D" | sed 's/^/  /'
echo ""

# Storage
echo "Storage:"
df -h / | tail -1 | awk '{print "  Root: "$3" used / "$2" total ("$5" used)"}'
echo ""

# Network
echo "Network:"
if command -v ip &>/dev/null; then
    PRIMARY_NIC=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -n "$PRIMARY_NIC" ]]; then
        echo "  Interface: $PRIMARY_NIC"
        SPEED=$(ethtool "$PRIMARY_NIC" 2>/dev/null | grep Speed | awk '{print $2}')
        [[ -n "$SPEED" ]] && echo "  Speed: $SPEED"
    fi
fi
echo ""

# Tuned Profile
if command -v tuned-adm &>/dev/null; then
    echo "Tuned Profile: $(tuned-adm active 2>/dev/null | cut -d: -f2 | xargs)"
fi

echo ""
echo "=========================================="
SYSSTATUS
    chmod +x /usr/local/bin/system-status
    
    # Create performance test script
    cat > /usr/local/bin/perf-test << 'PERFTEST'
#!/bin/bash
# Quick Performance Test

echo "Running quick performance tests..."
echo ""

# CPU test
echo "CPU Test (10 seconds):"
timeout 10 sysbench cpu --threads=$(nproc) run 2>/dev/null | grep "events per second" || echo "  sysbench not installed"
echo ""

# Memory test
echo "Memory Test:"
timeout 5 sysbench memory --threads=4 run 2>/dev/null | grep "transferred" || echo "  sysbench not installed"
echo ""

# Disk test
if command -v sysbench &>/dev/null; then
    echo "Disk Test (sequential read):"
    cd /tmp
    sysbench fileio --file-test-mode=seqrd --file-total-size=1G prepare >/dev/null 2>&1
    sysbench fileio --file-test-mode=seqrd --file-total-size=1G run 2>/dev/null | grep "read, MiB/s"
    sysbench fileio --file-test-mode=seqrd --file-total-size=1G cleanup >/dev/null 2>&1
fi

echo ""
echo "Test complete!"
PERFTEST
    chmod +x /usr/local/bin/perf-test
    
    success "Monitoring tools created (system-status, perf-test)"
}

#-------------------------------------------------------------------------------
# Advanced CPU Topology & NUMA Optimization
#-------------------------------------------------------------------------------
optimize_cpu_topology() {
    header "Advanced CPU Topology Optimization (i9-9900 8c/16t)"
    
    # 1. Detect CPU topology using hwloc if available
    if command -v lstopo &>/dev/null; then
        log "Detecting CPU topology with hwloc..."
        lstopo --no-io --of txt > /var/log/cpu-topology.txt 2>/dev/null || true
    fi
    
    # 2. Create CPU sets for different workload types
    log "Creating optimized CPU sets..."
    
    # Physical cores (0-7) and their HT siblings (8-15) for i9-9900
    # Reserve cores 0-1 for system, 2-7 (and 10-15) for applications
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/cpu-topology.conf << 'EOF'
[Manager]
# System services use cores 0-1 and their HT siblings 8-9
CPUAffinity=0 1 8 9
EOF

    # 3. Configure CPU isolation for latency-sensitive workloads
    cat > /etc/sysctl.d/60-cpu-topology.conf << 'EOF'
# CPU Topology Optimization for i9-9900 (8c/16t, single NUMA node)

# NUMA balancing (simulate NUMA awareness for better memory affinity)
kernel.numa_balancing = 1

# Scheduler domain flags for better load balancing
kernel.sched_domain.cpu0.domain0.flags = 4143

# Reduce scheduler tick overhead
kernel.sched_cfs_bandwidth_slice_us = 3000

# Improve CPU cache utilization
kernel.sched_migration_cost_ns = 5000000
kernel.sched_nr_migrate = 8

# Real-time scheduling improvements
kernel.sched_rt_runtime_us = 980000
kernel.sched_rt_period_us = 1000000

# Timer and interrupt optimization
kernel.timer_migration = 0
EOF

    # 4. Create CPU pinning utility for applications
    cat > /usr/local/bin/cpu-pin << 'CPUPIN'
#!/bin/bash
# CPU Pinning Utility for i9-9900 (8c/16t)
# Usage: cpu-pin <mode> <command>

case "${1:-help}" in
    performance)
        # Use all cores except system-reserved (0-1)
        shift
        exec taskset -c 2-7,10-15 "$@"
        ;;
    gaming)
        # Use physical cores 2-7 only (no HT - reduces latency)
        shift
        exec taskset -c 2-7 "$@"
        ;;
    render)
        # Use all threads for maximum parallel compute
        shift
        exec taskset -c 0-15 "$@"
        ;;
    single)
        # Single high-performance core
        shift
        exec taskset -c 4 nice -n -5 "$@"
        ;;
    balanced)
        # Half cores for background-friendly
        shift
        exec taskset -c 2-5,10-13 "$@"
        ;;
    *)
        echo "Usage: cpu-pin <mode> <command>"
        echo "Modes:"
        echo "  performance  - All cores except system (2-7,10-15)"
        echo "  gaming       - Physical cores only, no HT (2-7)"
        echo "  render       - All 16 threads (0-15)"
        echo "  single       - Single high-perf core (4)"
        echo "  balanced     - Half system capacity (2-5,10-13)"
        ;;
esac
CPUPIN
    chmod +x /usr/local/bin/cpu-pin
    
    # 5. IRQ affinity for reduced latency
    log "Configuring IRQ affinity for reduced latency..."
    cat > /usr/local/bin/optimize-irq << 'IRQOPT'
#!/bin/bash
# Optimize IRQ affinity - bind network/storage to dedicated cores

# Find network IRQs and bind to cores 0-1
for irq in $(grep -E 'eth|enp|eno' /proc/interrupts | cut -d: -f1 | tr -d ' '); do
    echo 3 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done

# Find NVMe IRQs and distribute across cores 0-3
for irq in $(grep nvme /proc/interrupts | cut -d: -f1 | tr -d ' '); do
    echo f > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done

# Find GPU IRQs and bind to dedicated cores
for irq in $(grep -E 'nvidia|amdgpu' /proc/interrupts | cut -d: -f1 | tr -d ' '); do
    echo 30 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done

echo "IRQ affinity optimized"
IRQOPT
    chmod +x /usr/local/bin/optimize-irq
    
    # Run IRQ optimization
    /usr/local/bin/optimize-irq 2>/dev/null || true
    
    sysctl --system >/dev/null 2>&1
    success "CPU topology optimization complete"
}

#-------------------------------------------------------------------------------
# Advanced Vulkan Multi-GPU Configuration
#-------------------------------------------------------------------------------
configure_vulkan_multi_gpu() {
    header "Vulkan Multi-GPU Configuration"
    
    # 1. Ensure Vulkan loader and ICDs are properly configured
    log "Configuring Vulkan ICD discovery..."
    
    # Create Vulkan configuration directory
    mkdir -p /etc/vulkan/icd.d
    mkdir -p /etc/vulkan/implicit_layer.d
    mkdir -p /etc/vulkan/explicit_layer.d
    
    # 2. Create multi-GPU Vulkan environment configuration
    cat > /etc/profile.d/vulkan-multigpu.sh << 'VKENV'
#!/bin/bash
# Vulkan Multi-GPU Environment Configuration

# Allow Vulkan to see all devices by default
export VK_LOADER_DISABLE_INST_EXT_FILTER=1

# Enable validation layers debugging (disabled by default for performance)
# export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation

# Device selection helpers
alias vk-amd='export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json:/usr/share/vulkan/icd.d/radeon_icd.i686.json'
alias vk-nvidia='export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json'
alias vk-all='unset VK_ICD_FILENAMES'

# DXVK optimizations
export DXVK_ASYNC=1
export DXVK_CONFIG_FILE=/etc/dxvk.conf

# RADV optimizations for RDNA2
export RADV_PERFTEST=aco,gpl,nggc,sam,rt
export RADV_DEBUG=zerovram,nodcc

# VKD3D-Proton optimizations
export VKD3D_CONFIG=dxr
export VKD3D_FEATURE_LEVEL=12_1
VKENV
    chmod +x /etc/profile.d/vulkan-multigpu.sh
    
    # 3. Create DXVK global configuration
    cat > /etc/dxvk.conf << 'DXVKCONF'
# DXVK Global Configuration

# Enable async shader compilation
dxvk.enableAsync = True

# Frame latency (1-16, lower = less input lag)
dxvk.maxFrameLatency = 1

# Use high performance GPU by default
dxvk.customDeviceId = 0

# Enable HDR if available
d3d11.forceSampleRateShading = True

# Tessellation optimization
d3d11.samplerAnisotropy = 16
DXVKCONF
    
    # 4. Create comprehensive GPU info utility
    cat > /usr/local/bin/vulkan-info << 'VKINFO'
#!/bin/bash
# Vulkan GPU Information Utility

echo "================================================"
echo "  Vulkan GPU Configuration"
echo "================================================"
echo ""

if command -v vulkaninfo &>/dev/null; then
    echo "Available Vulkan Devices:"
    vulkaninfo --summary 2>/dev/null | grep -E "GPU|deviceName|driverVersion|apiVersion" | head -20
    echo ""
else
    echo "vulkaninfo not installed. Install with: sudo dnf install vulkan-tools"
fi

echo "Current ICD Configuration:"
echo "  VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-<system default>}"
echo ""

echo "Available ICDs:"
ls -la /usr/share/vulkan/icd.d/*.json 2>/dev/null || echo "  No ICDs found"
echo ""

echo "Loaded Vulkan Layers:"
ls -la /usr/share/vulkan/implicit_layer.d/*.json 2>/dev/null || echo "  No implicit layers"
echo ""

if command -v nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU Status:"
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null
    echo ""
fi

if command -v radeontop &>/dev/null; then
    echo "AMD GPU: Use 'radeontop' for monitoring"
fi
VKINFO
    chmod +x /usr/local/bin/vulkan-info
    
    # 5. Create multi-GPU game launcher
    cat > /usr/local/bin/multigpu-run << 'MGPURUN'
#!/bin/bash
# Multi-GPU Application Launcher
# Supports running apps with both GPUs visible or specific GPU selection

usage() {
    echo "Usage: multigpu-run [options] <command>"
    echo ""
    echo "Options:"
    echo "  --primary-amd       Use AMD as primary, NVIDIA visible"
    echo "  --primary-nvidia    Use NVIDIA as primary, AMD visible"
    echo "  --amd-only          Only AMD GPU visible"
    echo "  --nvidia-only       Only NVIDIA GPU visible"
    echo "  --both              Both GPUs visible (default)"
    echo "  --lsfg              Enable LSFG frame generation"
    echo "  --mangohud          Enable MangoHud overlay"
    echo "  --gamescope <w> <h> Run through Gamescope at resolution"
    echo ""
    echo "Examples:"
    echo "  multigpu-run --primary-amd steam"
    echo "  multigpu-run --nvidia-only --mangohud ./game"
    echo "  multigpu-run --both --lsfg ./game"
}

# Default settings
GPU_MODE="both"
ENABLE_LSFG=0
ENABLE_MANGOHUD=0
GAMESCOPE_ENABLED=0
GAMESCOPE_W=0
GAMESCOPE_H=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary-amd)
            GPU_MODE="primary-amd"
            shift
            ;;
        --primary-nvidia)
            GPU_MODE="primary-nvidia"
            shift
            ;;
        --amd-only)
            GPU_MODE="amd-only"
            shift
            ;;
        --nvidia-only)
            GPU_MODE="nvidia-only"
            shift
            ;;
        --both)
            GPU_MODE="both"
            shift
            ;;
        --lsfg)
            ENABLE_LSFG=1
            shift
            ;;
        --mangohud)
            ENABLE_MANGOHUD=1
            shift
            ;;
        --gamescope)
            GAMESCOPE_ENABLED=1
            GAMESCOPE_W="$2"
            GAMESCOPE_H="$3"
            shift 3
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

# Configure GPU environment
case "$GPU_MODE" in
    primary-amd)
        export DRI_PRIME=0
        export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json:/usr/share/vulkan/icd.d/nvidia_icd.json"
        echo "[GPU] Primary: AMD, Secondary: NVIDIA"
        ;;
    primary-nvidia)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.json:/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
        echo "[GPU] Primary: NVIDIA, Secondary: AMD"
        ;;
    amd-only)
        export DRI_PRIME=0
        export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
        echo "[GPU] AMD only"
        ;;
    nvidia-only)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        export __VK_LAYER_NV_optimus=NVIDIA_only
        export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.json"
        echo "[GPU] NVIDIA only"
        ;;
    both)
        unset VK_ICD_FILENAMES
        unset DRI_PRIME
        unset __NV_PRIME_RENDER_OFFLOAD
        echo "[GPU] Both GPUs available"
        ;;
esac

# Configure LSFG
if [[ $ENABLE_LSFG -eq 1 ]]; then
    export ENABLE_LSFG=1
    echo "[LSFG] Frame generation enabled"
fi

# Configure MangoHud
if [[ $ENABLE_MANGOHUD -eq 1 ]]; then
    export MANGOHUD=1
    echo "[MangoHud] Overlay enabled"
fi

# Build command
CMD="$@"

# Wrap with Gamescope if requested
if [[ $GAMESCOPE_ENABLED -eq 1 ]]; then
    echo "[Gamescope] ${GAMESCOPE_W}x${GAMESCOPE_H}"
    CMD="gamescope -w 1280 -h 720 -W $GAMESCOPE_W -H $GAMESCOPE_H -F fsr -- $CMD"
fi

echo "[Exec] $CMD"
exec $CMD
MGPURUN
    chmod +x /usr/local/bin/multigpu-run
    
    success "Vulkan multi-GPU configuration complete"
}

#-------------------------------------------------------------------------------
# Advanced Magpie-like Upscaling
#-------------------------------------------------------------------------------
configure_magpie_upscaling() {
    header "Magpie-like Upscaling Configuration"
    
    # Check for Gamescope
    if ! command -v gamescope &>/dev/null; then
        warn "Gamescope not installed. Installing..."
        dnf install -y gamescope 2>&1 | tee -a "$LOG_FILE" || {
            warn "Failed to install Gamescope"
            return
        }
    fi
    
    # Create comprehensive upscaling launcher
    cat > /usr/local/bin/magpie-linux << 'MAGPIE'
#!/bin/bash
# Magpie-like Upscaling for Linux
# Uses Gamescope with FSR/NIS/Integer scaling

set -e

# Default settings
INTERNAL_W=1280
INTERNAL_H=720
OUTPUT_W=1920
OUTPUT_H=1080
SCALER="fsr"
FSR_SHARPNESS=5  # 0-20, higher = sharper
FULLSCREEN=1
FRAME_LIMIT=0
MANGOHUD=0
GPU="auto"

usage() {
    echo "Magpie-Linux: GPU-accelerated window upscaling"
    echo ""
    echo "Usage: magpie-linux [options] <command>"
    echo ""
    echo "Resolution Options:"
    echo "  -i, --internal <WxH>   Internal render resolution (default: 1280x720)"
    echo "  -o, --output <WxH>     Output display resolution (default: 1920x1080)"
    echo ""
    echo "Scaling Options:"
    echo "  -s, --scaler <type>    Scaler type: fsr, nis, integer, linear, nearest"
    echo "  --fsr-sharpness <0-20> FSR sharpness (default: 5)"
    echo ""
    echo "Display Options:"
    echo "  -w, --windowed         Run windowed instead of fullscreen"
    echo "  -f, --fps <limit>      Frame rate limit (0 = unlimited)"
    echo ""
    echo "GPU Options:"
    echo "  --gpu <amd|nvidia>     Force specific GPU for compositing"
    echo "  --mangohud             Enable MangoHud overlay"
    echo ""
    echo "Presets:"
    echo "  --720p                 720p -> native (FSR)"
    echo "  --900p                 900p -> native (FSR)"
    echo "  --1080p                1080p -> 1440p (FSR)"
    echo "  --4k-perf              1080p -> 4K (FSR Performance)"
    echo "  --4k-balanced          1440p -> 4K (FSR Balanced)"
    echo "  --4k-quality           1800p -> 4K (FSR Quality)"
    echo ""
    echo "Examples:"
    echo "  magpie-linux --720p ./game"
    echo "  magpie-linux -i 1280x720 -o 2560x1440 -s fsr ./game"
    echo "  magpie-linux --4k-quality --mangohud steam steam://rungameid/12345"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--internal)
            INTERNAL_W=$(echo "$2" | cut -dx -f1)
            INTERNAL_H=$(echo "$2" | cut -dx -f2)
            shift 2
            ;;
        -o|--output)
            OUTPUT_W=$(echo "$2" | cut -dx -f1)
            OUTPUT_H=$(echo "$2" | cut -dx -f2)
            shift 2
            ;;
        -s|--scaler)
            SCALER="$2"
            shift 2
            ;;
        --fsr-sharpness)
            FSR_SHARPNESS="$2"
            shift 2
            ;;
        -w|--windowed)
            FULLSCREEN=0
            shift
            ;;
        -f|--fps)
            FRAME_LIMIT="$2"
            shift 2
            ;;
        --gpu)
            GPU="$2"
            shift 2
            ;;
        --mangohud)
            MANGOHUD=1
            shift
            ;;
        --720p)
            INTERNAL_W=1280; INTERNAL_H=720
            OUTPUT_W=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f1 || echo 1920)
            OUTPUT_H=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f2 || echo 1080)
            SCALER="fsr"
            shift
            ;;
        --900p)
            INTERNAL_W=1600; INTERNAL_H=900
            OUTPUT_W=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f1 || echo 1920)
            OUTPUT_H=$(xrandr 2>/dev/null | grep '*' | head -1 | awk '{print $1}' | cut -dx -f2 || echo 1080)
            SCALER="fsr"
            shift
            ;;
        --1080p)
            INTERNAL_W=1920; INTERNAL_H=1080
            OUTPUT_W=2560; OUTPUT_H=1440
            SCALER="fsr"
            shift
            ;;
        --4k-perf)
            INTERNAL_W=1920; INTERNAL_H=1080
            OUTPUT_W=3840; OUTPUT_H=2160
            SCALER="fsr"
            shift
            ;;
        --4k-balanced)
            INTERNAL_W=2560; INTERNAL_H=1440
            OUTPUT_W=3840; OUTPUT_H=2160
            SCALER="fsr"
            shift
            ;;
        --4k-quality)
            INTERNAL_W=3200; INTERNAL_H=1800
            OUTPUT_W=3840; OUTPUT_H=2160
            SCALER="fsr"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

# Build Gamescope command
GAMESCOPE_ARGS=""
GAMESCOPE_ARGS+=" -w $INTERNAL_W -h $INTERNAL_H"
GAMESCOPE_ARGS+=" -W $OUTPUT_W -H $OUTPUT_H"

# Scaler selection
case "$SCALER" in
    fsr)
        GAMESCOPE_ARGS+=" -F fsr"
        export WINE_FULLSCREEN_FSR=1
        export WINE_FULLSCREEN_FSR_STRENGTH=$FSR_SHARPNESS
        ;;
    nis)
        GAMESCOPE_ARGS+=" -F nis"
        ;;
    integer)
        GAMESCOPE_ARGS+=" -S integer"
        ;;
    linear)
        GAMESCOPE_ARGS+=" -S linear"
        ;;
    nearest)
        GAMESCOPE_ARGS+=" -S nearest"
        ;;
esac

# Fullscreen
[[ $FULLSCREEN -eq 1 ]] && GAMESCOPE_ARGS+=" -f"

# Frame limit
[[ $FRAME_LIMIT -gt 0 ]] && GAMESCOPE_ARGS+=" -r $FRAME_LIMIT"

# GPU selection
case "$GPU" in
    amd)
        export DRI_PRIME=0
        export GAMESCOPE_PREFER_OUTPUT="AMD"
        ;;
    nvidia)
        export __NV_PRIME_RENDER_OFFLOAD=1
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
        ;;
esac

# MangoHud
if [[ $MANGOHUD -eq 1 ]]; then
    export MANGOHUD=1
    export MANGOHUD_DLSYM=1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Magpie-Linux Upscaling                                    ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Internal: ${INTERNAL_W}x${INTERNAL_H}"
echo "║  Output:   ${OUTPUT_W}x${OUTPUT_H}"
echo "║  Scaler:   ${SCALER}"
echo "║  GPU:      ${GPU}"
echo "╚════════════════════════════════════════════════════════════╝"

exec gamescope $GAMESCOPE_ARGS -- "$@"
MAGPIE
    chmod +x /usr/local/bin/magpie-linux
    
    # Create quick preset aliases
    cat >> /etc/profile.d/magpie-aliases.sh << 'ALIASES'
#!/bin/bash
# Magpie-Linux Quick Aliases
alias fsr720='magpie-linux --720p'
alias fsr900='magpie-linux --900p'
alias fsr4k='magpie-linux --4k-balanced'
alias upscale='magpie-linux'
ALIASES
    chmod +x /etc/profile.d/magpie-aliases.sh
    
    success "Magpie-like upscaling configured (use 'magpie-linux --help')"
}

#-------------------------------------------------------------------------------
# Advanced Virtual Resource Optimization
#-------------------------------------------------------------------------------
optimize_virtual_resources_advanced() {
    header "Advanced Virtual Resource Optimization"
    
    # 1. Create comprehensive cgroups v2 configuration
    log "Configuring cgroups v2 for task isolation..."
    
    # Ensure cgroups v2 is enabled (should be default in Fedora 43)
    if ! grep -q "cgroup_no_v1=all" /proc/cmdline && [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        warn "cgroups v2 may not be enabled. Adding to GRUB..."
        # This will be handled by configure_grub
    fi
    
    # 2. Create resource control configuration
    mkdir -p /etc/systemd/system/user@.service.d
    cat > /etc/systemd/system/user@.service.d/resource-control.conf << 'EOF'
[Service]
# Memory limits for user sessions (out of 64GB)
MemoryMax=56G
MemoryHigh=48G

# CPU weight (higher = more CPU time)
CPUWeight=200

# IO weight
IOWeight=200

# Allow real-time scheduling for games
LimitRTPRIO=99
LimitNICE=-20
LimitMEMLOCK=infinity
EOF

    # 3. Create high-performance application slice
    cat > /etc/systemd/system/highperf.slice << 'EOF'
[Unit]
Description=High Performance Applications Slice
Before=slices.target
After=system.slice

[Slice]
# Maximum resource allocation
CPUWeight=1000
CPUQuota=1500%
IOWeight=1000
MemoryMin=8G
MemoryLow=16G
MemoryHigh=56G
MemoryMax=60G

# Allow memory locking for reduced latency
AllowedMemoryNodes=0

# Task limits
TasksMax=4096
EOF

    # 4. Create low-priority background slice
    cat > /etc/systemd/system/background.slice << 'EOF'
[Unit]
Description=Low Priority Background Tasks
Before=slices.target

[Slice]
CPUWeight=50
CPUQuota=200%
IOWeight=10
MemoryMax=8G
TasksMax=256
EOF

    # 5. Create launcher for high-performance slice
    cat > /usr/local/bin/highperf-run << 'HPRUN'
#!/bin/bash
# Run application in high-performance slice with optimizations

if [[ $# -eq 0 ]]; then
    echo "Usage: highperf-run <command>"
    echo "Runs command in high-performance cgroup slice with:"
    echo "  - Maximum CPU priority"
    echo "  - Memory locking enabled"
    echo "  - IO priority boost"
    exit 1
fi

# Pre-launch optimizations
echo "[highperf] Optimizing system for high-performance workload..."

# Sync and drop caches for consistent memory state
sync
echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Compact memory to reduce fragmentation
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

# Run in high-performance slice with additional optimizations
exec systemd-run --user --scope --slice=highperf.slice \
    --property="CPUWeight=1000" \
    --property="IOWeight=1000" \
    --property="MemoryLow=4G" \
    --property="Nice=-10" \
    --property="CPUSchedulingPolicy=rr" \
    --property="CPUSchedulingPriority=50" \
    "$@"
HPRUN
    chmod +x /usr/local/bin/highperf-run
    
    # 6. Create background task launcher
    cat > /usr/local/bin/background-run << 'BGRUN'
#!/bin/bash
# Run application in low-priority background slice

if [[ $# -eq 0 ]]; then
    echo "Usage: background-run <command>"
    exit 1
fi

exec systemd-run --user --scope --slice=background.slice \
    --property="CPUWeight=10" \
    --property="IOWeight=10" \
    --property="Nice=19" \
    "$@"
BGRUN
    chmod +x /usr/local/bin/background-run
    
    # 7. Configure CPU isolation for latency-sensitive tasks
    log "Configuring kernel for better task isolation..."
    cat >> /etc/sysctl.d/60-cpu-scheduler.conf << 'EOF'

# Virtual resource isolation improvements
# Reduce timer interrupt coalescing for lower latency
kernel.timer_migration = 0

# Improve cgroup responsiveness
kernel.sched_cfs_bandwidth_slice_us = 3000

# Better CPU time distribution
kernel.sched_tunable_scaling = 0
EOF

    # 8. Create memory optimization for virtual resources
    log "Configuring memory for virtual resource optimization..."
    cat >> /etc/sysctl.d/60-memory-optimization.conf << 'EOF'

# Virtual memory optimizations for 64GB
# Aggressive writeback to prevent stalls
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1073741824

# Memory compaction for better hugepage availability
vm.compaction_proactiveness = 20
vm.compact_unevictable_allowed = 1

# Improve memory allocation for high-performance apps
vm.extfrag_threshold = 500
EOF

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1
    
    success "Advanced virtual resource optimization complete"
}

#-------------------------------------------------------------------------------
# Advanced Network Optimization
#-------------------------------------------------------------------------------
optimize_network_advanced() {
    header "Advanced Network Optimization"
    
    # 1. Detect primary network interface
    local primary_nic
    primary_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [[ -z "$primary_nic" ]]; then
        warn "No primary network interface detected"
        return
    fi
    
    log "Primary network interface: $primary_nic"
    
    # 2. Enhanced network sysctl configuration
    cat > /etc/sysctl.d/60-network-advanced.conf << 'EOF'
#===============================================================================
# Advanced Network Optimization for High Throughput + Low Latency
#===============================================================================

# BBR Congestion Control with FQ scheduler
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Memory Tuning (optimized for 64GB RAM)
# Min, Pressure, Max (in pages)
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.udp_mem = 786432 1048576 1572864

# Socket Buffer Sizes (32MB max for 10G capable)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Low Latency TCP Optimizations
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# Connection Handling
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1

# Keepalive Optimization
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Advanced TCP Features
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# Security & Performance Balance
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Port Range
net.ipv4.ip_local_port_range = 1024 65535

# Neighbor Table Optimization
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192

# IPv6 Optimizations
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF

    # 3. NIC Hardware Optimization
    if command -v ethtool &>/dev/null; then
        log "Optimizing NIC hardware settings..."
        
        # Enable all offloading features
        ethtool -K "$primary_nic" tx on rx on sg on tso on gso on gro on 2>/dev/null || true
        
        # Disable LRO (can cause issues with routing/bridging)
        ethtool -K "$primary_nic" lro off 2>/dev/null || true
        
        # Enable adaptive interrupt coalescing if supported
        ethtool -C "$primary_nic" adaptive-rx on adaptive-tx on 2>/dev/null || true
        
        # Maximize ring buffer sizes
        local max_rx max_tx
        max_rx=$(ethtool -g "$primary_nic" 2>/dev/null | grep -A 5 "Pre-set" | grep "RX:" | awk '{print $2}' | head -1)
        max_tx=$(ethtool -g "$primary_nic" 2>/dev/null | grep -A 5 "Pre-set" | grep "TX:" | awk '{print $2}' | head -1)
        
        if [[ -n "$max_rx" ]] && [[ "$max_rx" -gt 0 ]]; then
            ethtool -G "$primary_nic" rx "$max_rx" 2>/dev/null || true
        fi
        if [[ -n "$max_tx" ]] && [[ "$max_tx" -gt 0 ]]; then
            ethtool -G "$primary_nic" tx "$max_tx" 2>/dev/null || true
        fi
        
        success "NIC optimization applied: $primary_nic"
    fi
    
    # 4. Create udev rule for persistent NIC optimization
    cat > /etc/udev/rules.d/60-network-tuning.rules << 'EOF'
# Network interface optimization
ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|enp*|eno*", RUN+="/usr/local/bin/nic-optimize %k"
EOF

    # Create NIC optimization script
    cat > /usr/local/bin/nic-optimize << 'NICOPT'
#!/bin/bash
# Automatic NIC optimization on hotplug
NIC="$1"
[[ -z "$NIC" ]] && exit 0

# Wait for interface to be ready
sleep 1

# Apply optimizations
ethtool -K "$NIC" tx on rx on sg on tso on gso on gro on 2>/dev/null
ethtool -K "$NIC" lro off 2>/dev/null
ethtool -C "$NIC" adaptive-rx on adaptive-tx on 2>/dev/null

# Log optimization
logger "NIC $NIC optimized"
NICOPT
    chmod +x /usr/local/bin/nic-optimize
    
    # 5. Create network benchmark utility
    cat > /usr/local/bin/net-benchmark << 'NETBENCH'
#!/bin/bash
# Quick network benchmark utility

echo "Network Benchmark Utility"
echo "========================="
echo ""

# Interface info
PRIMARY_NIC=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -n "$PRIMARY_NIC" ]]; then
    echo "Interface: $PRIMARY_NIC"
    SPEED=$(ethtool "$PRIMARY_NIC" 2>/dev/null | grep Speed | awk '{print $2}')
    [[ -n "$SPEED" ]] && echo "Link Speed: $SPEED"
    echo ""
fi

# Current settings
echo "Current TCP Settings:"
echo "  Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  Queue Discipline: $(sysctl -n net.core.default_qdisc)"
echo "  TCP Fast Open: $(sysctl -n net.ipv4.tcp_fastopen)"
echo "  RMem Max: $(( $(sysctl -n net.core.rmem_max) / 1024 / 1024 ))MB"
echo "  WMem Max: $(( $(sysctl -n net.core.wmem_max) / 1024 / 1024 ))MB"
echo ""

# Latency test
echo "Latency Test (ping google.com):"
ping -c 5 google.com 2>/dev/null | tail -1 || echo "  Unable to reach google.com"
echo ""

# Speed test hint
if command -v iperf3 &>/dev/null; then
    echo "For throughput test, run:"
    echo "  iperf3 -c <server_ip> -t 10"
else
    echo "Install iperf3 for throughput testing: sudo dnf install iperf3"
fi
NETBENCH
    chmod +x /usr/local/bin/net-benchmark
    
    sysctl --system >/dev/null 2>&1
    udevadm control --reload-rules
    udevadm trigger
    
    success "Advanced network optimization complete"
}

#-------------------------------------------------------------------------------
# Power Profile Manager
#-------------------------------------------------------------------------------
create_power_profile_manager() {
    header "Power Profile Manager"
    
    cat > /usr/local/bin/power-profile << 'PWRPROFILE'
#!/bin/bash
# Comprehensive Power Profile Manager
# Balances performance and efficiency for i9-9900 + Dual GPU

set -e

get_status() {
    echo "Current Power Profile Status"
    echo "============================="
    echo ""
    
    # CPU
    echo "CPU:"
    echo "  Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        echo "  EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    fi
    echo "  Turbo: $([ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)" == "0" ] && echo 'Enabled' || echo 'Disabled')"
    echo "  Current Freq: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f MHz", $1/1000}')"
    echo ""
    
    # GPUs
    echo "AMD GPU:"
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        if [[ -f "$card" ]] && [[ -f "$(dirname "$card")/vendor" ]]; then
            if grep -q "0x1002" "$(dirname "$card")/vendor" 2>/dev/null; then
                echo "  Power Level: $(cat "$card" 2>/dev/null)"
            fi
        fi
    done
    echo ""
    
    echo "NVIDIA GPU:"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=power.draw,power.limit,clocks.gr --format=csv,noheader 2>/dev/null || echo "  N/A"
    else
        echo "  Driver not loaded"
    fi
    echo ""
    
    # Tuned
    if command -v tuned-adm &>/dev/null; then
        echo "Tuned Profile: $(tuned-adm active 2>/dev/null | cut -d: -f2 | xargs || echo 'N/A')"
    fi
}

set_performance() {
    echo "Setting PERFORMANCE profile..."
    
    # CPU: Maximum performance
    echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null 2>&1 || true
    fi
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    
    # AMD GPU: High performance
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        echo "high" > "$card" 2>/dev/null || true
    done
    
    # NVIDIA GPU: Performance mode
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -pm 1 2>/dev/null || true
        nvidia-smi -pl 75 2>/dev/null || true  # GTX 1650 max TDP
    fi
    
    # Tuned profile
    tuned-adm profile throughput-performance 2>/dev/null || true
    
    echo "Performance profile activated"
}

set_balanced() {
    echo "Setting BALANCED profile..."
    
    # CPU: Balanced (powersave with intel_pstate acts like schedutil)
    echo "powersave" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        echo "balance_performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null 2>&1 || true
    fi
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    
    # AMD GPU: Auto
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        echo "auto" > "$card" 2>/dev/null || true
    done
    
    # NVIDIA GPU: Auto
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -pm 1 2>/dev/null || true
        nvidia-smi -pl 65 2>/dev/null || true
    fi
    
    # Tuned profile
    tuned-adm profile gaming-optimized 2>/dev/null || tuned-adm profile balanced 2>/dev/null || true
    
    echo "Balanced profile activated"
}

set_powersave() {
    echo "Setting POWERSAVE profile..."
    
    # CPU: Power saving
    echo "powersave" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        echo "power" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null 2>&1 || true
    fi
    # Optional: Disable turbo for max power savings
    # echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    
    # AMD GPU: Low power
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        echo "low" > "$card" 2>/dev/null || true
    done
    
    # NVIDIA GPU: Low power
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -pm 1 2>/dev/null || true
        nvidia-smi -pl 40 2>/dev/null || true
    fi
    
    # Tuned profile
    tuned-adm profile powersave 2>/dev/null || true
    
    echo "Power saving profile activated"
}

set_gaming() {
    echo "Setting GAMING profile..."
    
    # CPU: Performance with balance
    echo "powersave" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference >/dev/null 2>&1 || true
    fi
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    
    # AMD GPU: High performance
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        echo "high" > "$card" 2>/dev/null || true
    done
    
    # NVIDIA GPU: Gaming mode
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi -pm 1 2>/dev/null || true
        nvidia-smi -pl 75 2>/dev/null || true
    fi
    
    # Tuned profile
    tuned-adm profile gaming-optimized 2>/dev/null || tuned-adm profile throughput-performance 2>/dev/null || true
    
    # Disable compositor effects if possible
    if [[ -n "$DISPLAY" ]]; then
        # For GNOME
        gsettings set org.gnome.desktop.interface enable-animations false 2>/dev/null || true
    fi
    
    echo "Gaming profile activated"
}

case "${1:-status}" in
    performance|perf)
        set_performance
        ;;
    balanced|normal)
        set_balanced
        ;;
    powersave|save)
        set_powersave
        ;;
    gaming|game)
        set_gaming
        ;;
    status)
        get_status
        ;;
    *)
        echo "Usage: power-profile [performance|balanced|powersave|gaming|status]"
        echo ""
        echo "Profiles:"
        echo "  performance  Maximum performance, high power"
        echo "  balanced     Balance of performance and efficiency"
        echo "  powersave    Minimum power consumption"
        echo "  gaming       Optimized for gaming (high perf + low latency)"
        echo "  status       Show current power status"
        ;;
esac
PWRPROFILE
    chmod +x /usr/local/bin/power-profile
    
    # Create systemd service for boot-time profile
    cat > /etc/systemd/system/power-profile-boot.service << 'EOF'
[Unit]
Description=Apply default power profile at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-profile balanced
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable power-profile-boot.service 2>/dev/null || true
    
    success "Power profile manager installed"
}

#-------------------------------------------------------------------------------
# Comprehensive Verification Tool
#-------------------------------------------------------------------------------
create_comprehensive_verification() {
    header "Creating Comprehensive Verification Tool"
    
    cat > /usr/local/bin/verify-optimization << 'VERIFY'
#!/bin/bash
# Comprehensive System Optimization Verification

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        Fedora Optimization Verification Report               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# CPU Checks
echo "[CPU]"
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
[[ "$GOV" == "powersave" || "$GOV" == "performance" ]] && pass "Governor: $GOV" || warn "Governor: $GOV"

if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
    EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
    pass "EPP: $EPP"
fi

TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)
[[ "$TURBO" == "0" ]] && pass "Turbo Boost: Enabled" || warn "Turbo Boost: Disabled"

AUTOGROUP=$(sysctl -n kernel.sched_autogroup_enabled 2>/dev/null)
[[ "$AUTOGROUP" == "1" ]] && pass "Scheduler Autogroup: Enabled" || warn "Scheduler Autogroup: Disabled"
echo ""

# Memory Checks
echo "[Memory]"
SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null)
[[ "$SWAPPINESS" -le 20 ]] && pass "Swappiness: $SWAPPINESS" || warn "Swappiness: $SWAPPINESS (consider lowering)"

VFS_CACHE=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)
[[ "$VFS_CACHE" -le 100 ]] && pass "VFS Cache Pressure: $VFS_CACHE" || warn "VFS Cache Pressure: $VFS_CACHE"

if [[ -f /sys/block/zram0/disksize ]]; then
    ZRAM_SIZE=$(( $(cat /sys/block/zram0/disksize) / 1024 / 1024 / 1024 ))
    pass "ZRAM: ${ZRAM_SIZE}GB"
else
    warn "ZRAM: Not active"
fi

THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
[[ "$THP" == "madvise" ]] && pass "THP: madvise" || warn "THP: $THP"
echo ""

# GPU Checks
echo "[GPUs]"
if lspci | grep -qi "AMD.*RX\|Radeon"; then
    pass "AMD GPU: Detected"
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        if [[ -f "$card" ]]; then
            LEVEL=$(cat "$card" 2>/dev/null)
            pass "  Power Level: $LEVEL"
        fi
    done
fi

if lspci | grep -qi "NVIDIA"; then
    pass "NVIDIA GPU: Detected"
    if command -v nvidia-smi &>/dev/null; then
        pass "  Driver: Loaded"
        PERSIST=$(nvidia-smi -q 2>/dev/null | grep 'Persistence Mode' | awk '{print $NF}')
        [[ "$PERSIST" == "Enabled" ]] && pass "  Persistence: Enabled" || warn "  Persistence: $PERSIST"
    else
        warn "  Driver: Not loaded"
    fi
fi
echo ""

# Network Checks
echo "[Network]"
CONG=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[[ "$CONG" == "bbr" ]] && pass "Congestion Control: BBR" || warn "Congestion Control: $CONG"

QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
[[ "$QDISC" == "fq" ]] && pass "Queue Discipline: FQ" || warn "Queue Discipline: $QDISC"

FO=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
[[ "$FO" == "3" ]] && pass "TCP Fast Open: Enabled" || warn "TCP Fast Open: $FO"
echo ""

# Storage Checks
echo "[Storage]"
for dev in /sys/block/nvme* /sys/block/sd*; do
    [[ -d "$dev" ]] || continue
    NAME=$(basename "$dev")
    SCHED=$(cat "$dev/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
    pass "$NAME: $SCHED"
done

FSTRIM=$(systemctl is-active fstrim.timer 2>/dev/null)
[[ "$FSTRIM" == "active" ]] && pass "TRIM Timer: Active" || warn "TRIM Timer: $FSTRIM"
echo ""

# Services Checks
echo "[Services]"
for svc in tuned thermald irqbalance earlyoom; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null)
    [[ "$STATUS" == "active" ]] && pass "$svc: Running" || warn "$svc: $STATUS"
done
echo ""

# Utilities Checks
echo "[Installed Utilities]"
for util in cpu-pin gpu-select multigpu-run magpie-linux power-profile highperf-run; do
    [[ -x /usr/local/bin/$util ]] && pass "$util" || warn "$util: Missing"
done
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "Verification complete!"
VERIFY
    chmod +x /usr/local/bin/verify-optimization
    
    success "Comprehensive verification tool created"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Fedora Advanced Optimization Script v${VERSION} ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       Fedora 43 Advanced System Optimizer v${VERSION}            ║${NC}"
    echo -e "${BOLD}${CYAN}║   Target: i9-9900 (8c/16t) | 64GB | RX 6400 XT | GTX 1650    ║${NC}"
    echo -e "${BOLD}${CYAN}║   Board: ASUS Z390-F Gaming                                   ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_fedora
    check_hardware
    detect_display_server
    
    create_backup
    
    # Package Installation
    install_packages
    install_nvidia_driver
    install_lsfg_vk
    
    # CPU Optimization
    optimize_cpu
    optimize_cpu_topology          # NEW: Advanced topology optimization
    
    # Virtual Resource Optimization
    optimize_virt_resources
    optimize_virtual_resources_advanced  # NEW: Enhanced cgroups/isolation
    
    # Memory Optimization
    optimize_memory
    
    # GPU Optimization
    optimize_gpu_amd
    enhance_amd_gpu
    optimize_gpu_nvidia
    enhance_nvidia_gpu
    
    # Multi-GPU & Vulkan
    configure_dual_gpu_gaming
    configure_vulkan_multi_gpu     # NEW: Advanced Vulkan multi-GPU
    configure_magpie_upscaling     # NEW: Magpie-like upscaling
    
    # Network & Storage
    optimize_network
    optimize_network_advanced       # NEW: Enhanced network tuning
    optimize_storage
    
    # Power Management
    optimize_power
    create_power_profile_manager    # NEW: Power profile manager
    
    # Boot Configuration
    configure_grub
    
    # Tools & Utilities
    create_monitoring_tools
    create_comprehensive_verification  # NEW: Verification tool
    
    header "Optimization Complete!"
    echo -e "${GREEN}✓ All optimizations applied successfully${NC}"
    echo ""
    echo "Installed Utilities:"
    echo "  ┌─ GPU & Gaming ─────────────────────────────────────────────┐"
    echo "  │  gpu-select [amd|nvidia|parallel|auto] <cmd>               │"
    echo "  │  multigpu-run [options] <cmd>   Multi-GPU launcher         │"
    echo "  │  magpie-linux [options] <cmd>   FSR/NIS upscaling          │"
    echo "  │  lsfg-run <cmd>                 Frame generation           │"
    echo "  │  gaming-run <cmd>               High-priority slice        │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo "  ┌─ CPU & Performance ────────────────────────────────────────┐"
    echo "  │  cpu-pin <mode> <cmd>           CPU affinity control       │"
    echo "  │  highperf-run <cmd>             Maximum performance        │"
    echo "  │  background-run <cmd>           Low-priority execution     │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo "  ┌─ System Management ────────────────────────────────────────┐"
    echo "  │  power-profile <mode>           Power profile switching    │"
    echo "  │  amd-gpu-mode <mode>            AMD GPU power control      │"
    echo "  │  nvidia-gpu-mode <mode>         NVIDIA GPU power control   │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo "  ┌─ Monitoring & Diagnostics ─────────────────────────────────┐"
    echo "  │  system-status                  System overview            │"
    echo "  │  vulkan-info                    Vulkan GPU information     │"
    echo "  │  net-benchmark                  Network testing            │"
    echo "  │  perf-test                      Performance benchmarks     │"
    echo "  │  verify-optimization            Verify all optimizations   │"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Quick Start:"
    echo "  • Run 'power-profile gaming' before playing games"
    echo "  • Use 'magpie-linux --720p ./game' for FSR upscaling"
    echo "  • Use 'multigpu-run --nvidia-only ./game' for NVIDIA-only"
    echo "  • Run 'verify-optimization' to check all settings"
    echo ""
    echo -e "${YELLOW}⚠ REBOOT REQUIRED for all changes to take effect!${NC}"
    echo ""
    echo "Backup location: $BACKUP_DIR"
    echo "Restore command: sudo $BACKUP_DIR/restore.sh"
    echo "Log file: $LOG_FILE"
}

main "$@"
