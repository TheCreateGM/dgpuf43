# Fedora 43 Dual-GPU Cooperative Mode Setup & System Optimizer

## System Configuration
- **Motherboard**: ASUS Z390-F
- **CPU**: Intel Core i9-9900
- **Primary GPU (PCIE x16 Slot 1)**: AMD RX 6400 (Display/Primary)
- **Secondary GPU (PCIE x16 Slot 2)**: NVIDIA GTX 1650 (Compute/Render Offload)
- **OS**: Fedora Linux 43

---

## Overview

This script auto-detects and configures a dual-GPU (AMD + NVIDIA) system for cooperative workloads:

- **Auto-install missing drivers/packages** (RPM Fusion, NVIDIA, AMD)
- **Configure PRIME Render Offload** and Vulkan multi-ICD hints
- **Intelligent workload balancing** and power management
- **Helper utilities** for easy GPU switching and parallel encoding

> **Note**: AMD and NVIDIA GPUs cannot be physically merged (no SLI/CrossFire). This setup creates a cooperative environment where each GPU handles tasks it's best suited for.

---

## How It Works

### GPU Roles

| GPU | Role | Use Cases |
|-----|------|----------|
| **AMD RX 6400** | Primary Display | Desktop, browser, video playback, VA-API decode |
| **NVIDIA GTX 1650** | Render Offload | Gaming, Blender/CUDA, NVENC encoding, heavy compute |

### Workload Strategy
```
Desktop/Light Tasks → AMD RX 6400 (always-on, efficient)
        ↓
Heavy Tasks → NVIDIA GTX 1650 (on-demand via PRIME offload)
        ↓
Task Completed → NVIDIA suspends (power saving)
```

---

## Installation

### Step 1: Run the Script
```bash
chmod +x main.sh
sudo ./main.sh
```

The script will:
1. Validate system requirements
2. Enable RPM Fusion repositories
3. Install AMD (AMDGPU/Mesa) and NVIDIA drivers
4. Configure PRIME Render Offload for X11/Wayland
5. Install helper utilities
6. Optimize CPU, memory, and I/O settings
7. Configure power management and TLP
8. Install GameMode and multimedia codecs

### Step 2: Reboot
```bash
sudo reboot
```

### Step 3: Verify Installation
```bash
gpu-check
```

### Step 4 (X11 Only): Set Provider Mappings
If using X11, run as your session user after login:
```bash
prime-setup
```

---

## Installed Helper Utilities

The script installs these utilities to `/usr/local/bin/`:

| Utility | Description |
|---------|-------------|
| `smart-run` | Intelligent GPU workload launcher with auto-detection |
| `gpu-check` | Comprehensive GPU diagnostics report |
| `gpu-balance` | Real-time GPU load monitoring |
| `system-tune` | Interactive system performance tuning |
| `prime-setup` | X11 provider mapping for PRIME offload |
| `gpu-coop` | Cooperative GPU mode launcher |
| `gpu-parallel-ffmpeg` | Parallel video encoding across GPUs |

---

## Usage Guide

### smart-run — Intelligent GPU Launcher

```bash
# Auto-select GPU based on application
smart-run <command>

# Force specific GPU
smart-run --nvidia blender
smart-run --amd firefox
smart-run --balanced ffmpeg -i video.mp4 -o out.mp4
```

**Auto-detection rules:**
- `blender`, `steam`, `obs` → NVIDIA
- `ffmpeg`, `kdenlive`, `darktable` → Balanced (both GPUs)
- Everything else → AMD

### gpu-coop — Cooperative GPU Mode

```bash
# Run with specific GPU mode
gpu-coop --nvidia <command>      # NVIDIA only
gpu-coop --amd <command>         # AMD only
gpu-coop --balanced <command>    # Both GPUs (Vulkan multi-ICD)
gpu-coop --auto <command>        # Auto-detect
```

### gpu-parallel-ffmpeg — Parallel Video Encoding

Split and encode video segments in parallel using available GPUs:

```bash
gpu-parallel-ffmpeg -i input.mp4 -o output.mp4 [-j jobs] [-c codec] [-b bitrate]
```

**Options:**
- `-i INPUT` — Input file (required)
- `-o OUTPUT` — Output file (required)
- `-j JOBS` — Number of parallel jobs (default: number of GPUs)
- `-c h264|hevc` — Codec (default: h264)
- `-b BITRATE` — Bitrate (default: 2000k)

**Example:**
```bash
gpu-parallel-ffmpeg -i movie.mp4 -o encoded.mp4 -j 2 -b 4000k
```

### system-tune — System Performance Tuning

```bash
sudo system-tune
```

**Profiles:**
1. Maximum Performance (Gaming/Heavy Workloads)
2. Balanced Mode (Default)
3. Power Saving Mode
4. Reset to Defaults
5. Show Current Settings

---

## Monitoring

### GPU Diagnostics
```bash
gpu-check
```

Shows:
- PCI device detection
- Loaded kernel modules
- OpenGL and Vulkan info
- NVIDIA status (nvidia-smi)
- AMD status (radeontop/vainfo)
- Power management status
- PRIME configuration

### Real-Time GPU Monitoring
```bash
gpu-balance
```

Interactive monitor showing:
- NVIDIA memory/utilization/temperature
- AMD GPU status
- Workload recommendations

### Additional Tools
```bash
nvidia-smi               # NVIDIA status
radeontop                # AMD GPU usage
vulkaninfo               # Vulkan device enumeration
vainfo                   # VA-API status
glxinfo | grep -i vendor # OpenGL vendor
```

---

## Configuration Files Created

| File | Purpose |
|------|--------|
| `/etc/modprobe.d/50-nvidia.conf` | NVIDIA kernel module options (DPM, modeset) |
| `/etc/X11/xorg.conf.d/10-prime-offload.conf` | Xorg PRIME Render Offload config |
| `/etc/profile.d/gpu_config.sh` | Global GPU environment variables |
| `/etc/profile.d/gpu_wayland.sh` | Wayland GPU configuration |
| `/etc/sysctl.d/98-gpu-optimization.conf` | Kernel parameter tuning |
| `/etc/udev/rules.d/99-gpu-power.rules` | GPU runtime power management |

---

## Gaming

### Steam
```bash
smart-run --nvidia steam

# Or add to game launch options:
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %command%
```

### Lutris / Heroic
```bash
smart-run --nvidia lutris
smart-run --nvidia heroic
```

### GameMode
GameMode is automatically installed and enabled. It switches to performance mode when games launch.

---

## Video Encoding

### NVIDIA NVENC
```bash
smart-run --nvidia ffmpeg -i input.mp4 -c:v h264_nvenc -preset slow output.mp4
```

### AMD VAAPI
```bash
ffmpeg -vaapi_device /dev/dri/renderD128 -i input.mp4 \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi output.mp4
```

### Parallel Encoding (Both GPUs)
```bash
gpu-parallel-ffmpeg -i input.mp4 -o output.mp4 -j 2
```

---

## Troubleshooting

### NVIDIA Not Working
```bash
# Check driver
lsmod | grep nvidia
nvidia-smi

# Rebuild kernel module
sudo akmods --force

# Check logs
journalctl -b | grep nvidia
```

### AMD Not Detected
```bash
lsmod | grep amdgpu
lspci | grep -E "VGA|3D"
vainfo
```

### Black Screen After Reboot
```bash
# Boot to rescue mode, then:
sudo rm /etc/X11/xorg.conf.d/10-prime-offload.conf
sudo reboot
```

### Reset Configuration
```bash
sudo rm /etc/X11/xorg.conf.d/10-prime-offload.conf
sudo rm /etc/modprobe.d/50-nvidia.conf
sudo rm /etc/profile.d/gpu_*.sh
sudo rm /etc/sysctl.d/98-gpu-optimization.conf
sudo rm /etc/udev/rules.d/99-gpu-power.rules
sudo reboot
```

---

## What Gets Configured

- ✓ PRIME Render Offload + Vulkan multi-ICD hints
- ✓ Intelligent helper scripts (smart-run, gpu-coop, gpu-parallel-ffmpeg)
- ✓ Automatic driver installation (NVIDIA akmod, AMD Mesa)
- ✓ NVIDIA persistence daemon and modprobe options
- ✓ GPU runtime power management (autosuspend)
- ✓ CPU frequency scaling (performance governor)
- ✓ I/O scheduler optimization (mq-deadline/kyber)
- ✓ Memory and swap tuning
- ✓ GameMode for automatic gaming profiles
- ✓ Multimedia codecs (GStreamer, FFmpeg)
- ✓ VA-API and Vulkan acceleration
- ✓ TLP power management daemon

---

## Logs

Full installation log: `/var/log/dual-gpu-setup.log`

---

## FAQ

**Can both GPUs run simultaneously?**
Yes. AMD handles display while NVIDIA processes compute tasks via PRIME offload.

**Does this work on Wayland?**
Yes. The script configures environment variables for both X11 and Wayland.

**How much power is saved?**
NVIDIA suspends when idle (0W), saving ~75W compared to always-on.

**Can I connect monitors to NVIDIA?**
Not recommended. Use AMD for display output for best power efficiency.

---

## Resources

- Installation Log: `/var/log/dual-gpu-setup.log`
- Xorg Logs: `/var/log/Xorg.0.log`
- NVIDIA Logs: `journalctl -b | grep nvidia`
- Fedora Forums: https://discussion.fedoraproject.org/
