# Fedora 43 Advanced System Optimizer — Dual-GPU Workstation

Version 8.0.0

A comprehensive, production-ready optimization script for Fedora 43 Linux targeting maximum performance with power efficiency for desktop, gaming, AI/compute, and development workloads.

---

## Target Hardware

- **CPU**: Intel Core i9-9900 (8 cores / 16 threads)
- **RAM**: 64GB DDR4
- **GPU 1**: AMD RX 6400 XT (Primary Display)
- **GPU 2**: NVIDIA RTX 3050 (Compute/Offload)
- **Motherboard**: ASUS ROG Strix Z390-F Gaming
- **OS**: Fedora Linux 43 (Xfce, X11)

---

## Features Overview

### CPU Optimization

- Intel P-state configuration with Turbo Boost and HWP dynamic boost
- Kernel scheduler tuning (autogroup, migration cost, latency, granularity)
- RCU offloading and timer migration
- NUMA-aware scheduling for single-socket optimization
- IRQ balancing with `irqbalance` (deepest cache level 2)
- Custom `tuned` profiles: `extreme-performance` and `balanced-performance`
- `thermald` integration for thermal management
- Intel microcode updates
- Systemd CPU affinity for critical services (NetworkManager, sshd, firewalld)

### CPU Instruction Set Detection

- Automatic detection of AVX-512, AVX2, AES-NI, SSE4.2, FMA
- Compiler flags (`CFLAGS`/`CXXFLAGS`) tuned per detected instruction set
- Intel MKL/IPP/OpenMP threading configured for 16 threads

### Intel Optimized Libraries

- Intel IPP Cryptography (ipp-crypto)
- DGEMM optimization (AVX-512/AVX2)
- Highwayhash (minio)
- BLAS/LAPACK/MKL threading environment
- AES-NI hardware crypto acceleration

### Thread Affinity and Workload Isolation

- cgroups v2 with systemd slices:
  - `gaming.slice` — high CPU priority (weight 200), all cores
  - `compute.slice` — cores 4–15, weight 180
  - `background.slice` — low priority (weight 20)
- Launch commands: `main.sh run-gaming -- <cmd>` / `main.sh run-compute -- <cmd>`
- Compute thread affinity via environment.d (KMP, OMP, MKL, BLAS)

### Memory Optimization (64GB Aware)

- Low swappiness (10) for high-RAM systems
- Optimized dirty page ratios to prevent stalls
- Transparent Huge Pages set to `madvise`
- EarlyOOM protection against runaway processes
- `vm.max_map_count` set for gaming compatibility (2147483642)
- Hugepages pre-allocated (1024 × 2MB = 2GB)
- VFS cache pressure optimization
- Memory compaction and defragmentation tuning
- jemalloc/tcmalloc allocator environment tuning
- Storage optimization frameworks (TidesDB, WiscKey, caRamel, java-memory-agent)

### Dual-GPU Setup (AMD + NVIDIA)

- **AMD RX 6400 XT**: Primary display, Vulkan/RADV, ACO/GPL/NGGC/SAM
- **NVIDIA RTX 3050**: PRIME render offload via `main.sh run-nvidia`, compute tasks
- Automatic NVIDIA driver installation (akmod) with Secure Boot MOK enrollment
- NVIDIA persistence mode and dynamic power management
- GPU coordination via modprobe, udev, and environment.d

### Graphics Pipeline

- **Vulkan Multi-GPU**: Both GPUs visible to Vulkan applications via ICD files
- **Zink**: OpenGL over Vulkan for reduced driver overhead (Mesa)
- **ANGLE**: OpenGL ES compatibility layer over Vulkan
- **vkBasalt**: Global Vulkan post-processing (FSR, NIS)
- **DXVK/VKD3D**: DirectX-to-Vulkan translation for Windows games
- Shader cache optimization (10GB Mesa disk cache)

### Advanced GPU Utilities

- **LSFG-VK**: Lossless Scaling Frame Generation for Vulkan
- **Pikzel**: Modern C++ graphics framework (0xworks)
- **ComfyUI-MultiGPU**: Multi-GPU AI workload support
- **optimus-GPU-switcher**: GPU switching utility (NVIDIA systems)
- **vgpu_unlock**: NVIDIA vGPU support (DualCoder)
- All cloned to `/opt/gpu-utils/`

### Magpie-like Upscaling

- GPU-accelerated window upscaling via Gamescope
- FSR (FidelityFX Super Resolution) and NIS (NVIDIA Image Scaling) support
- Configurable resolution and refresh rate
- MangoHud integration

### AI and Compute Optimization

- PyTorch, CUDA, OpenCL, TensorFlow environment configuration
- Multi-GPU compute (`CUDA_VISIBLE_DEVICES=0,1`)
- NCCL distributed training support
- Intel oneMKL / TBB / OpenMP threading
- Python ML stack: torch, torchvision, numpy, scipy, scikit-learn, onnxruntime, xformers, triton
- CUDA toolkit, ROCm, and Vulkan SDK installation

### Network Optimization

- BBR congestion control with fq_codel qdisc
- TCP buffer tuning (16MB max for 64GB RAM)
- TCP Fast Open enabled (client + server)
- Low latency TCP optimizations
- Connection handling (16384 backlog, 5000 netdev backlog)
- NIC offload features (TSO, GSO, GRO)
- DNS optimization (Cloudflare/Google DNS over TLS)

### Storage Optimization

- Intelligent I/O scheduler selection via udev rules (NVMe: mq-deadline, SSD: bfq, HDD: bfq)
- Periodic TRIM via `fstrim.timer` (daily)
- NVMe-specific tuning (nr_requests, read_ahead_kb, writeback cache)
- `noatime` mount option in fstab
- Filesystem commit interval optimization
- Storage frameworks: eloqstore, WiscKey, k4, LogStore, Bf-Tree, TidesDB, RocksDB, LevelDB

### Power Efficiency

- PowerTOP auto-tune service (PCI/SATA tuning only)
- PCIe runtime PM and ASPM
- USB autosuspend **disabled** (desktop workstation — prevents mouse/keyboard dropouts)
- PowerTOP `ExecStartPost` re-enables all USB devices after `--auto-tune`
- NMI watchdog disabled
- Power profile boot service (`fedora-optimizer-apply.service`)
- CPU frequency scaling per power mode
- GPU power management (AMD DPM, NVIDIA dynamic power)

### Kernel Parameter Tuning

- Intel P-state mode via GRUB (active/passive per power mode)
- CPU security mitigations (configurable via `--mitigations-off`)
- IOMMU passthrough (if enabled in BIOS)
- Transparent hugepages via kernel cmdline
- Watchdog and NMI watchdog disabled
- BLS-aware GRUB configuration with safety verification

### Bootloader Optimization

- GRUB timeout reduced for faster boot
- systemd parallel service loading
- Unnecessary boot services disabled

### Security Hardening

- Kernel hardening (`kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, `kexec_load_disabled`)
- Network security (`rp_filter`, TCP SYN cookies, source route filtering)
- SSH hardening (no root login, password + pubkey auth, rate limiting)
- Firewall (`firewalld`) enabled with SSH allowed
- `fail2ban` for SSH brute-force protection
- SELinux enforcing maintained
- Telemetry/ABRT services disabled
- `auditd` with security monitoring rules
- Rootkit detection tools (rkhunter/chkrootkit)

### Privacy Optimization

- ABRT and crash reporting services disabled
- DNF anonymous counting (`countme`) disabled
- Journal logging limits (512MB system, 128MB runtime, 1 week retention)
- Unnecessary background services disabled

### System Smoothness

- PipeWire low-latency configuration (256 samples @ 48kHz)
- Realtime scheduling for audio (@audio group, rtprio 95)
- Input latency optimization (timer slack 50μs, scheduler tuning)
- Compositor optimizations (Qt, GTK environment variables)
- Frame pacing and VSync configuration
- Developer build flags (`-O3 -march=native -flto` via environment.d)
- Preload for predictive application caching
- EarlyOOM protection

### Developer Platform (skippable with `--skip-developer-tools`)

- C/C++ (GCC, Clang, CMake, Ninja, Make, Meson)
- Rust/Cargo, Go, Python 3, Perl, Zig, NASM
- Dart/Flutter SDK
- Multi-architecture: 32-bit libs, ARM cross-compilation, MinGW
- Wine for Windows compatibility, Android tools
- System debugging: valgrind, gdb, strace, ltrace, perf, bpftrace

### Virtualization & Cross-Platform

- KVM/QEMU/Libvirt virtualization stack (requires CPU VMX/SVM; auto-detected)
- Graceful skip if hardware virtualization is absent — Wine and Android still configured
- VFIO readiness (IOMMU configuration if enabled in BIOS)
- Wine optimization for Windows compatibility (FSR enabled)
- Android emulation environment
- CPU pinning hooks for VMs

---

## Installation

### Quick Start

```bash
chmod +x main.sh
sudo ./main.sh
```

The script will:

1. Run pre-flight health checks and clean up dangerous files from previous runs
2. Detect hardware (CPU, RAM, GPUs, storage, instruction sets)
3. Install required packages and NVIDIA drivers
4. Create a manifest-based backup for rollback
5. Apply all optimizations (CPU, GPU, memory, storage, network, kernel, power, security)
6. Configure kernel boot parameters (GRUB) with BLS awareness
7. Set up systemd slices, power profile manager, and AI/compute environment
8. Validate all configuration files
9. Prompt for reboot

### Command-Line Options

```bash
sudo ./main.sh [OPTIONS] [SUBCOMMAND] [ARGS...]
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Show changes without applying them |
| `--non-interactive` | Skip all confirmation prompts (same as `--no-confirm`) |
| `--no-confirm` | Skip all confirmation prompts |
| `--rollback <run-id>` | Restore system from a previous backup |
| `--apply-after-reboot` | Automatically reboot after optimization |
| `--power-mode <mode>` | Set power mode (`balanced`, `performance`, `powersave`) |
| `--mitigations-off` | Disable CPU security mitigations for performance |
| `--deep-cstates` | Enable deep C-state restrictions for low latency |
| `--enable-virtualization` | Enable virtualization support (QEMU/KVM/VFIO) |
| `--skip-developer-tools` | Skip installation of developer tools and languages |
| `--help` | Display help message and exit |

### After Installation

```bash
sudo reboot

# Check power profile
./main.sh power-mode status

# Check GPU status
./main.sh gpu-info

# List available backups
./main.sh --list-backups
```

---

## Subcommands

| Command | Description |
|---------|-------------|
| `./main.sh run-nvidia -- <cmd>` | Run command with NVIDIA GPU (PRIME offload) |
| `./main.sh run-gamescope-fsr [nw nh tw th] <cmd>` | Run with Gamescope FSR upscaling |
| `./main.sh upscale-run [nw nh tw th] -- <cmd>` | Run with Gamescope upscaling layer |
| `./main.sh gpu-info` | Display GPU information |
| `./main.sh gpu-benchmark` | Run GPU benchmark (vkcube) |
| `./main.sh run-compute -- <cmd>` | Run in `compute.slice` (cores 4–15) |
| `./main.sh run-gaming -- <cmd>` | Run in `gaming.slice` (all cores, high priority) |
| `./main.sh power-mode status` | Show current power profile and governor |
| `./main.sh power-mode list` | List available tuned profiles |
| `sudo ./main.sh power-mode performance` | Switch to extreme-performance profile |
| `sudo ./main.sh power-mode balanced` | Switch to balanced-performance profile |
| `sudo ./main.sh power-mode powersave` | Switch to powersave profile |
| `./main.sh intel-libs-setup` | Show Intel optimized libraries and build instructions |
| `./main.sh --list-backups` | List available backup run-ids |
| `sudo ./main.sh --rollback <run-id>` | Restore from manifest-based backup |

---

## Rollback

All changes can be reverted using the manifest-based backup system:

```bash
./main.sh --list-backups
sudo ./main.sh --rollback <run-id>
sudo reboot
```

Backup location: `/var/backup/fedora-optimizer/<run-id>/`

Each backup includes a manifest, metadata, individual file backups, and a tarball.

---

## Safety and Stability

- **Deferred Activation**: All system tuning changes apply after reboot, not live
- **Manifest-Based Backup**: Per-file backup with timestamped run-ids
- **Rollback**: `./main.sh --rollback <run-id>` restores any previous state
- **Dangerous File Cleanup**: Removes known-problematic files from previous runs at startup
- **BLS-Aware Boot**: GRUB and boot verification aware of BLS (Boot Loader Specification)
- **Configuration Validation**: Validates GRUB, sysctl, modprobe syntax before applying
- **GRUB Interrupt Safety**: Automatic GRUB backup restore if script is interrupted during critical boot configuration changes
- **Hardware Auto-Detection**: Adapts to actual CPU features (VMX, AVX-512, instruction sets) — does not assume exact i9-9900 match
- **Error Handling**: `set -euo pipefail` with trap handlers, automatic rollback on fatal errors
- **Script Isolation**: Self-contained — no external optimization scripts sourced

---

## Requirements

- **Fedora Linux 43** (enforced at runtime)
- Root privileges for system optimization (`sudo`)
- Internet connection for package installation

---

## License

MIT License
