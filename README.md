# Fedora 43 Advanced System Optimizer

Version 4.0.0

A comprehensive, production-ready optimization script for Fedora Linux 43, targeting maximum performance with power efficiency for desktop and gaming workloads.

---

## Target Hardware

- **CPU**: Intel Core i9-9900 (8 cores / 16 threads)
- **RAM**: 64GB DDR4
- **GPU 1**: AMD RX 6400 XT (Primary Display)
- **GPU 2**: NVIDIA GTX 1650 (Compute/Offload)
- **Motherboard**: ASUS Z390-F Gaming
- **OS**: Fedora Linux 43 (Wayland + X11)

---

## Features Overview

### CPU Optimization

- Intel P-state configuration with `balance_performance` EPP
- Turbo Boost enabled with dynamic frequency scaling
- Kernel scheduler tuning for desktop responsiveness
- Scheduler autogroup for better interactive workloads
- Custom `tuned` profile (gaming-optimized)
- thermald integration for thermal management
- IRQ balancing with custom policy
- CPU affinity optimization for system services

### Advanced CPU Topology Optimization

- NUMA-aware scheduling (single-socket optimization)
- CPU set configuration for workload isolation
- System services reserved to cores 0-1
- Application cores 2-7 (and HT siblings 10-15) available
- IRQ affinity binding for network/storage/GPU
- Real-time scheduling improvements
- Timer migration disabled for lower latency

### Memory Optimization (64GB Aware)

- Low swappiness (10) for high-RAM systems
- Optimized dirty page ratios to prevent stalls
- Transparent Huge Pages set to `madvise`
- ZRAM with zstd compression (16GB / 25% of RAM)
- EarlyOOM protection against runaway processes
- `vm.max_map_count` set for gaming compatibility (2147483642)
- Hugepages pre-allocated (1024 x 2MB = 2GB)
- VFS cache pressure optimization
- Memory compaction for reduced fragmentation
- Preload for predictive application caching

### Dual-GPU Setup (AMD + NVIDIA)

- **AMD RX 6400 XT**: Primary display, Vulkan/RADV, VA-API
- **NVIDIA GTX 1650**: PRIME render offload, compute tasks
- Automatic NVIDIA driver installation (akmod)
- NVIDIA persistence mode and power management
- GPU selection utilities for per-application control
- Enhanced AMD RDNA2 optimizations (ACO, GPL, NGGC, SAM)
- User-accessible GPU power controls via udev rules

### Vulkan Multi-GPU Configuration

- Both GPUs visible to Vulkan applications
- ICD file management for GPU selection
- DXVK global configuration with async shaders
- VKD3D-Proton optimization
- RADV optimizations for RDNA2
- Multi-GPU launcher with flexible options

### LSFG-VK Integration

- Lossless Scaling Frame Generation for Vulkan
- Auto-builds from source during installation
- Vulkan implicit layer registration
- Compatible with Steam's Lossless Scaling assets
- Wrapper script for easy activation

### Magpie-like Upscaling

- GPU-accelerated window upscaling via Gamescope
- FSR (FidelityFX Super Resolution) support
- NIS (NVIDIA Image Scaling) support
- Integer, linear, and nearest scaling modes
- Presets: 720p, 900p, 1080p, 4K Performance/Balanced/Quality
- Configurable FSR sharpness (0-20)
- GPU selection for compositor
- MangoHud integration

### Virtual Resource Optimization

- cgroups v2 configuration for task isolation
- systemd slice weights (User > Gaming > System)
- High-performance slice with maximum CPU/IO/Memory priority
- Background slice for low-priority tasks
- User session resource controls
- Real-time scheduling limits
- Memory locking allowances

### Network Optimization

- BBR congestion control (Google's algorithm)
- FQ (Fair Queue) scheduler
- TCP buffer tuning (32MB max for 64GB RAM)
- TCP Fast Open enabled
- Low latency TCP optimizations
- IRQ balancing with irqbalance
- NIC hardware offloading (TSO, GSO, GRO)
- Ring buffer maximization
- Adaptive interrupt coalescing
- Connection handling optimization (65535 backlog)
- ECN (Explicit Congestion Notification) enabled

### Storage Optimization

- Intelligent I/O scheduler selection:
  - NVMe: `none` (hardware handles queuing)
  - SATA SSD: `mq-deadline`
  - HDD: `bfq`
- Periodic TRIM via fstrim.timer
- Optimized read-ahead values

### Power Efficiency

- PCIe ASPM (powersave mode)
- SATA link power management (med_power_with_dipm)
- USB autosuspend (except HID devices)
- Intel audio codec power saving
- Runtime PM for PCI devices
- Dynamic CPU/GPU downclocking when idle

### Gaming Tools

- **GameMode** with custom configuration
- **Gamescope** wrapper for FSR upscaling
- **MangoHud** pre-configured
- Gaming slice with priority scheduling
- DXVK async shader compilation

### Developer Platform

- **Core Toolchains**: GCC, Clang/LLVM, Rust, Go, Zig, NASM
- **Build Systems**: CMake, Ninja, Make, Automake
- **Scripting**: Python 3, Perl, Git with LFS support
- **Windows Compatibility**: Wine, DXVK, VKD3D-Proton
- **Cross-Compilation**: MinGW-w64 (32-bit and 64-bit)
- **Debugging**: GDB, Valgrind, Strace, Ltrace, Perf
- **Development Libraries**: Full 32-bit development stack

### Virtualization & Multi-Arch

- **KVM/QEMU**: Full virtualization stack with virt-manager
- **libvirt**: Complete VM management infrastructure
- **Nested Virtualization**: Enabled for Intel VT-x
- **Multi-Arch Support**: Box64/Box86 for x86 emulation (if available)
- **Binary Format Support**: binfmt_misc for cross-architecture execution

### Security Hardening

- **Firewall**: firewalld with home zone configuration
- **SELinux**: Enforcing mode enabled
- **Audit**: auditd for system auditing
- **SSH Hardening**: Root login disabled, key-only auth, connection limits
- **Network Security**: rp_filter, syncookies, redirect protection
- **Service Masking**: Unnecessary services (avahi, cups, bluetooth) masked

### Desktop Smoothness & UX

- **GNOME Optimizations**: Reduced animations, touchpad improvements
- **Wayland Native**: Proper environment variables for Wayland apps
- **File Watchers**: Increased inotify limits for development
- **Input Latency**: Reduced input latency via udev rules
- **Display**: Triple buffering, proper video driver modesetting

---

## Installation

### Quick Start

```bash
chmod +x main.sh
sudo ./main.sh
```

The script will:

1. Detect your hardware (CPU, RAM, GPUs)
2. Create a backup for rollback
3. Enable RPM Fusion repositories
4. Install required packages and NVIDIA drivers
5. Build and install LSFG-VK
6. Install developer platform (GCC, Rust, Go, Wine, MinGW)
7. Set up virtualization stack (KVM, QEMU, virt-manager)
8. Apply security hardening (firewall, SELinux, SSH)
9. Apply all CPU, memory, GPU, network, and storage optimizations
10. Configure desktop smoothness settings
11. Configure kernel boot parameters
12. Install helper utilities
13. Create verification tools

### After Installation

```bash
sudo reboot
verify-optimization  # Check all optimization states
system-status        # View system overview
```

---

## Installed Utilities

### GPU and Gaming

| Command | Description |
|---------|-------------|
| `gpu-select [amd\|nvidia\|parallel\|auto] <cmd>` | Run command on specific GPU |
| `multigpu-run [options] <cmd>` | Multi-GPU launcher with flexible options |
| `magpie-linux [options] <cmd>` | FSR/NIS upscaling (Magpie-like) |
| `lsfg-run <cmd>` | LSFG-VK frame generation |
| `gaming-run <cmd>` | Run in high-priority gaming slice |
| `upscale-run <scaler> <w> <h> <cmd>` | Basic Gamescope upscaling wrapper |

### CPU and Performance

| Command | Description |
|---------|-------------|
| `cpu-pin <mode> <cmd>` | CPU affinity control |
| `highperf-run <cmd>` | Maximum performance cgroup slice |
| `background-run <cmd>` | Low-priority background execution |

### System Management

| Command | Description |
|---------|-------------|
| `power-profile <mode>` | Power profile switching (performance/balanced/powersave/gaming) |
| `amd-gpu-mode <mode>` | AMD GPU power control (performance/power/auto/manual) |
| `nvidia-gpu-mode <mode>` | NVIDIA GPU power control (performance/power/auto) |
| `optimize-irq` | Optimize IRQ affinity for network/storage/GPU |
| `nic-optimize <interface>` | Optimize network interface settings |
| `mtu-optimize <interface>` | Auto-detect and set optimal MTU |
| `upscale-run <scaler> <w> <h> <cmd>` | Basic Gamescope upscaling wrapper |

### Developer Tools

| Command | Description |
|---------|-------------|
| `wine` | Windows application compatibility layer |
| `box64` | x86_64 emulation on ARM64 (if available) |
| `virt-manager` | Virtual machine management GUI |

### Security Tools

| Command | Description |
|---------|-------------|
| `firewall-cmd` | Firewall management |
| `ausearch` | Audit log search |
| `getenforce` | Check SELinux status |

### Monitoring and Diagnostics

| Command | Description |
|---------|-------------|
| `system-status` | System overview |
| `vulkan-info` | Vulkan GPU information |
| `net-benchmark` | Network testing |
| `perf-test` | Performance benchmarks |
| `verify-optimization` | Verify all optimizations |

---

## Usage Examples

### GPU Selection

```bash
# Run Blender on NVIDIA
gpu-select nvidia blender

# Run Firefox on AMD
gpu-select amd firefox

# Both GPUs visible (Vulkan multi-GPU)
gpu-select parallel ./vulkan-app

# Auto-detect (system default)
gpu-select auto ./app
```

### Multi-GPU Launcher

```bash
# Primary AMD, NVIDIA as secondary
multigpu-run --primary-amd steam

# NVIDIA only with MangoHud
multigpu-run --nvidia-only --mangohud ./game

# Both GPUs with LSFG frame generation
multigpu-run --both --lsfg ./game

# With Gamescope at 1440p
multigpu-run --gamescope 2560 1440 ./game
```

### Magpie-like Upscaling

```bash
# Quick preset: 720p to native with FSR
magpie-linux --720p ./game

# Custom: 720p to 1440p with FSR
magpie-linux -i 1280x720 -o 2560x1440 -s fsr ./game

# 4K Quality preset with MangoHud
magpie-linux --4k-quality --mangohud steam steam://rungameid/12345

# NIS scaler instead of FSR
magpie-linux -s nis --720p ./game
```

### CPU Pinning

```bash
# Performance mode (all cores except system-reserved)
cpu-pin performance ./render-job

# Gaming mode (physical cores only, no HT)
cpu-pin gaming ./game

# Render mode (all 16 threads)
cpu-pin render blender -b scene.blend

# Single high-performance core
cpu-pin single ./single-threaded-app

# Balanced (half capacity)
cpu-pin balanced ./background-task
```

### Power Profiles

```bash
# Maximum performance
sudo power-profile performance

# Gaming (performance + low latency)
sudo power-profile gaming

# Daily use / balanced
sudo power-profile balanced

# Power saving
sudo power-profile powersave

# Check current state
power-profile status
```

### Resource Control

```bash
# Run game in high-priority slice
highperf-run ./game

# Run backup in background slice
background-run rsync -av /home /backup

# Gaming slice (systemd scope)
gaming-run steam
```

### LSFG Frame Generation

```bash
# Run with LSFG (requires Lossless Scaling assets)
lsfg-run ./game

# Or with environment variable
LSFG_ASSETS="/path/to/Lossless Scaling" lsfg-run ./game
```

### Quick Aliases

```bash
# Magpie-Linux quick presets
fsr720 ./game      # 720p to native with FSR
fsr900 ./game      # 900p to native with FSR  
fsr4k ./game       # 4K balanced preset
upscale ./game     # Custom upscale
```

---

## Configuration Files Created

### Kernel Parameters (sysctl)

| Location | Purpose |
|----------|---------|
| `/etc/sysctl.d/60-cpu-scheduler.conf` | Kernel scheduler tuning |
| `/etc/sysctl.d/60-cpu-topology.conf` | CPU topology and NUMA |
| `/etc/sysctl.d/60-memory-optimization.conf` | Memory management |
| `/etc/sysctl.d/60-network-optimization.conf` | Basic network tuning |
| `/etc/sysctl.d/60-network-advanced.conf` | Advanced network tuning |

### GPU Configuration

| Location | Purpose |
|----------|---------|
| `/etc/modprobe.d/amdgpu.conf` | AMD GPU driver options |
| `/etc/modprobe.d/amdgpu-enhanced.conf` | Enhanced AMD options |
| `/etc/modprobe.d/nvidia.conf` | NVIDIA driver options |
| `/etc/profile.d/amd-gpu.sh` | AMD environment variables |
| `/etc/profile.d/nvidia-gpu.sh` | NVIDIA environment variables |
| `/etc/profile.d/vulkan-multigpu.sh` | Vulkan multi-GPU config |
| `/etc/profile.d/magpie-aliases.sh` | Upscaling aliases |
| `/etc/dxvk.conf` | DXVK global configuration |

### systemd Configuration

| Location | Purpose |
|----------|---------|
| `/etc/systemd/zram-generator.conf` | ZRAM swap configuration |
| `/etc/systemd/system/gaming.slice` | Gaming applications slice |
| `/etc/systemd/system/highperf.slice` | High-performance slice |
| `/etc/systemd/system/background.slice` | Background tasks slice |
| `/etc/systemd/system/user@.service.d/resource-control.conf` | User session limits |
| `/etc/systemd/system.conf.d/cpu-affinity.conf` | System CPU affinity |
| `/etc/systemd/system.conf.d/cpu-topology.conf` | CPU topology |
| `/etc/systemd/system.conf.d/cgroups.conf` | cgroups accounting |
| `/etc/systemd/system/power-profile-boot.service` | Boot power profile |

### udev Rules

| Location | Purpose |
|----------|---------|
| `/etc/udev/rules.d/60-io-scheduler.rules` | I/O scheduler rules |
| `/etc/udev/rules.d/60-readahead.rules` | Read-ahead tuning |
| `/etc/udev/rules.d/60-usb-power.rules` | USB power management |
| `/etc/udev/rules.d/60-pcie-pm.rules` | PCIe power management |
| `/etc/udev/rules.d/60-network-tuning.rules` | Network interface tuning |
| `/etc/udev/rules.d/60-usb-autosuspend.rules` | USB autosuspend rules |
| `/etc/udev/rules.d/60-sata-pm.rules` | SATA power management |
| `/etc/udev/rules.d/60-pci-runtime-pm.rules` | PCI runtime power management |
| `/etc/udev/rules.d/60-noatime.rules` | NVMe mount options |
| `/etc/udev/rules.d/60-nvme-tuning.rules` | NVMe readahead/nr_requests |
| `/etc/udev/rules.d/60-input-latency.rules` | Input latency reduction |
| `/etc/udev/rules.d/80-amdgpu-power.rules` | AMD GPU power management |

### Security Configuration

| Location | Purpose |
|----------|---------|
| `/etc/sysctl.d/60-security-hardening.conf` | Network security hardening |
| `/etc/ssh/sshd_config.d/hardening.conf` | SSH hardening overrides |
| `/etc/selinux/config` | SELinux enforcing mode |
| `/etc/systemd/system/powertop.service` | Powertop auto-tune service |

### Other

| Location | Purpose |
|----------|---------|
| `/etc/tuned/gaming-optimized/tuned.conf` | Custom tuned profile |
| `/etc/tuned/cpu-pstate.conf` | Intel P-state configuration |
| `/etc/default/earlyoom` | EarlyOOM configuration |
| `/etc/sysconfig/irqbalance` | IRQ balance configuration |
| `/etc/tmpfiles.d/thp.conf` | THP persistent config |
| `/usr/share/vulkan/implicit_layer.d/lsfg_vk.json` | LSFG Vulkan layer |
| `/etc/security/limits.d/99-fd-limits.conf` | File descriptor limits |
| `/etc/systemd/journald.conf.d/99-journal-size.conf` | Journal size limits |
| `/etc/modprobe.d/kvm-intel.conf` | KVM nested virtualization |
| `/etc/modprobe.d/nvidia-pm.conf` | NVIDIA runtime PM |
| `/etc/modprobe.d/video.conf` | Video driver options |
| `/etc/ssh/sshd_config.backup.*` | SSH config backup |
| `/etc/dconf/db/local.d/compositor` | GNOME compositor settings |
| `/etc/environment.d/99-wayland.conf` | Wayland environment |
| `/etc/sysctl.d/60-binfmt.conf` | Binary format support |

---

## Rollback

All changes can be reverted:

```bash
# Restore from backup
sudo /var/backup/fedora-optimizer/restore.sh
sudo reboot
```

Backup location: `/var/backup/fedora-optimizer/`

---

## Verification

```bash
# Comprehensive verification report
verify-optimization

# Quick system status
system-status

# Individual checks
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
sysctl vm.swappiness
sysctl net.ipv4.tcp_congestion_control
nvidia-smi
zramctl
tuned-adm active
```

---

## Troubleshooting

### NVIDIA Driver Issues

```bash
# Check driver status
lsmod | grep nvidia
nvidia-smi

# Rebuild kernel module
sudo akmods --force

# Check logs
journalctl -b | grep nvidia

# Verify PRIME offload
__NV_PRIME_RENDER_OFFLOAD=1 glxinfo | grep "OpenGL renderer"
```

### AMD GPU Issues

```bash
lsmod | grep amdgpu
vainfo
vulkaninfo --summary

# Check power level
cat /sys/class/drm/card*/device/power_dpm_force_performance_level
```

### Performance Not Improved

```bash
# Verify tuned profile is active
tuned-adm active

# Check if BBR is enabled
sysctl net.ipv4.tcp_congestion_control

# Verify ZRAM is active
zramctl

# Check CPU governor and EPP
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference

# Verify scheduler tuning
sysctl kernel.sched_autogroup_enabled
```

### Multi-GPU Issues

```bash
# List Vulkan devices
vulkaninfo --summary

# Check ICD files
ls -la /usr/share/vulkan/icd.d/

# Test specific GPU
gpu-select amd vulkaninfo --summary
gpu-select nvidia vulkaninfo --summary
```

### Reset Everything

```bash
sudo /var/backup/fedora-optimizer/restore.sh
sudo reboot
```

---

## What Gets Installed

### Packages

- **CPU/Power**: tuned, tuned-utils, powertop, thermald, kernel-tools, hwloc, cpuid
- **GPU AMD**: mesa-vulkan-drivers, mesa-va-drivers, mesa-vdpau-drivers, libva-utils, vulkan-tools, radeontop
- **GPU NVIDIA**: akmod-nvidia, xorg-x11-drv-nvidia-cuda, nvidia-vaapi-driver, nvtop
- **Memory**: zram-generator, earlyoom, numactl, preload
- **Network**: irqbalance, ethtool, iperf3, iproute-tc
- **Gaming**: gamemode, gamescope, mangohud, libdecor
- **Build Tools**: git, cmake, ninja-build, vulkan-headers, various -devel packages
- **Monitoring**: htop, btop, iotop, glxinfo
- **Codecs**: ffmpeg, gstreamer1-plugins-bad-free, gstreamer1-plugins-good, gstreamer1-plugins-ugly, gstreamer1-plugin-libav
- **Developer**: gcc, gcc-c++, clang, llvm, rust, cargo, go, zig, nasm, make, gdb, valgrind, strace, perf
- **Cross-Platform**: wine, wine-common, mingw64-gcc, mingw32-gcc
- **Virtualization**: qemu-kvm, libvirt, virt-manager, virt-install
- **Security**: firewalld, audit, audit-libs

---

## Safety and Stability

- **Safe Defaults**: All settings are conservative and well-tested
- **Reversible**: Full backup created before any changes
- **No Kernel Patches**: Uses standard kernel features only
- **Update Safe**: Will not break system updates
- **Idempotent**: Safe to run multiple times
- **Error Handling**: Script uses `set -euo pipefail` for safety

---

## Logs and Backup

- **Installation Log**: `/var/log/fedora-optimizer.log`
- **Backup Location**: `/var/backup/fedora-optimizer/`
- **CPU Topology Map**: `/var/log/cpu-topology.txt` (if hwloc installed)

---

## Expected Results

After running and rebooting:

- Faster application launches (preload + optimized caching)
- Smoother gaming with proper GPU selection and FSR upscaling
- Better multitasking under heavy load (cgroups + scheduler tuning)
- Lower idle power consumption (ASPM + runtime PM)
- Improved network throughput (BBR + buffer tuning)
- Faster storage I/O (appropriate schedulers + TRIM)
- Quieter operation when idle (dynamic power management)
- Frame generation capability (LSFG-VK)
- Magpie-like upscaling on Linux (Gamescope + FSR/NIS)
- Complete development environment (GCC, Rust, Go, Wine, MinGW)
- Virtualization ready (KVM, QEMU, virt-manager)
- Enhanced security (firewall, SELinux, SSH hardening)
- Improved desktop responsiveness (GNOME/Wayland optimizations)

---

## License

MIT License
