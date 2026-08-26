# Guix Installation Scripts

Modular scripts for installing minimal Guix OS on different platforms with
automated hardware detection, safety checks, and guided workflows.

**AI-Assisted Development:** This project was developed with significant contributions from Claude (Anthropic), ChatGPT-4 (OpenAI), and Cursor's native LLM agents. The codebase, documentation, and troubleshooting guides were collaboratively created through iterative human-AI pairing.

buymeacoffee.com/durantschoon (🙏 help support my LLM habit)

**New to Guix?** [Guix System on Oracle Cloud's free tier](https://durantschoon.github.io/guix-platform-install/)
walks through getting a free always-on Guix machine, written for someone who has
never used Guix. It is a description of the flow, not a button — it deploys
nothing and asks you for nothing. Parts are still unfinished, and the page says
which. Source: [`web/index.html`](web/index.html).

## ⚠️ Choose Your Platform

**Pick the right installer for your use case:**

| Platform | Use Case | Data Safety | Requirements |
|----------|----------|-------------|--------------|
| **[`cloudzy`](cloudzy/)** | Fresh VPS (Cloudzy, etc.) | ⚠️ **WIPES ENTIRE DISK** | VPS with Guix ISO access |
| **[`framework`](framework/)** | Framework 13 single-boot | ⚠️ **WIPES ENTIRE DISK** | Framework 13, no existing OS needed |
| **[`framework-dual`](framework-dual/)** | Framework 13 dual-boot with Pop!_OS | ✅ **PRESERVES existing OS** | Framework 13 with Pop!_OS already installed |
| **[`raspberry-pi`](raspberry-pi/)** | Raspberry Pi 3/4/5 | N/A (Image-based) | Apple Silicon Mac for building |

### Hardware Requirements

- **Disk Space**: 40GB minimum (60GB+ recommended)
- **RAM**: 2GB minimum (4GB+ recommended)
- **Architecture**: x86_64 (Framework/VPS) or aarch64 (Raspberry Pi)
- **Secure Boot**: Not supported - disable in BIOS before installation

---

## Quick Install

**One command from Guix ISO:**

```bash
curl -fsSL https://raw.githubusercontent.com/durantschoon/\
guix-platform-install/main/lib/bootstrap-installer.sh | \
bash -s -- <platform>
```

Replace `<platform>` with: `cloudzy`, `framework`, or `framework-dual`

**⚠️ WARNING:** `cloudzy` and `framework` will **WIPE YOUR ENTIRE DISK**.
Only use on fresh systems.

See [`QUICKSTART.md`](QUICKSTART.md) for complete instructions.

## 📖 Documentation Guide

**Choose your documentation path:**

- 🚀 **New to Guix?** → [`QUICKSTART.md`](QUICKSTART.md) - Simple, step-by-step guide
- 🔧 **Experienced with Guix?** → [`docs/GUIDE_SEASONED_GUIX.md`](docs/GUIDE_SEASONED_GUIX.md) - Advanced configuration, channel pinning, custom packages
- 💻 **Setting up dual-boot?** → [`docs/GUIDE_DUAL_BOOT.md`](docs/GUIDE_DUAL_BOOT.md) - Framework 13 + Pop!_OS dual-boot guide
- 📚 **Need technical reference?** → [`docs/GUIDE_REFERENCE.md`](docs/GUIDE_REFERENCE.md) - Troubleshooting, technical deep-dives, recovery
- 👨‍💻 **Contributing to this project?** → [`docs/GUIDE_CONTRIBUTING.md`](docs/GUIDE_CONTRIBUTING.md) - Developer documentation, code patterns, testing
- 🖥️ **Platform-specific help?** → See platform READMEs: [`cloudzy/README.md`](cloudzy/README.md), [`framework/README.md`](framework/README.md), [`raspberry-pi/README.md`](raspberry-pi/README.md)

**Not sure where to start?** See [`docs/README.md`](docs/README.md) for complete documentation navigation with suggested reading paths.

## Quick Navigation

- ⚡ **Quick Start Guide**: See [`QUICKSTART.md`](QUICKSTART.md) -
  Complete workflow from ISO to customized system
- 🎨 **Customization Guide**: See
  [`postinstall/CUSTOMIZATION.md`](postinstall/CUSTOMIZATION.md) -
  Add features after minimal install
- 📦 **Channel Management**: See
  [`postinstall/CHANNEL_MANAGEMENT.md`](postinstall/CHANNEL_MANAGEMENT.md) -
  Configure Guix channels (nonguix, custom repos)
- 🌍 **Mirror Configuration**: See [`lib/mirrors.md`](lib/mirrors.md) -
  Optimize download speeds globally
- 📚 **Installation Knowledge**: See
  [`docs/INSTALLATION_KNOWLEDGE.md`](docs/INSTALLATION_KNOWLEDGE.md) -
  Deep technical details and lessons learned
- 🔧 **Troubleshooting**: See
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) -
  Common issues and solutions
- ✅ **Verification Guide**: See
  [`docs/VERIFICATION.md`](docs/VERIFICATION.md) -
  Verify installation integrity
- 🚀 **VPS Installation**: See [`cloudzy/README.md`](cloudzy/README.md)
- 💻 **Framework 13 Single-Boot**: See [`framework/README.md`](framework/README.md)
- 💻 **Framework 13 Dual-Boot**: See [`framework-dual/README.md`](framework-dual/README.md)
- 🥧 **Raspberry Pi 3/4/5** (Experimental): See
  [`raspberry-pi/README.md`](raspberry-pi/README.md)

---

## Installation Philosophy

### Minimal First, Customize Later

All installation scripts create a **truly minimal** bootable Guix system:

- ✅ Base system packages only
- ✅ User account with sudo access
- ❌ No desktop environment
- ❌ No SSH server
- ❌ No extra packages

**Why?** Get a working system fast (~10 min), boot into it (free of ISO!),
then customize for your exact needs.

**Workflow:**

1. Install minimal Guix from ISO (scripts 01-04)
2. Boot into installed system
3. Customize using `guix-customize` tool or manual config edits

See [`QUICKSTART.md`](QUICKSTART.md) for complete workflow.

---

## Installation Types

### 1. VPS Fresh Install (Cloudzy)

**⚠️ THIS WILL DESTROY ALL DATA ON THE TARGET DEVICE!**

Designed for **fresh VPS instances** where you want to completely replace
the existing system with Guix. It will:

- **Wipe the entire disk** and create new partitions
- **Destroy all existing data** on the target device
- **Replace the operating system** with minimal Guix
- **No SSH/desktop** until you customize after boot

### ✅ **Safe to Use When:**

- You have a **fresh VPS instance** with no important data
- You're running from a **Guix live ISO**
- You want to **completely replace** the existing system
- You're **100% certain** you're targeting the right device

### ❌ **DO NOT USE When:**

- You have **important data** on the target device
- You're running on a **production server** with existing data
- You're **unsure** which device will be targeted
- You want to **preserve** any existing data or system

### 🛡️ **Safety Features:**

- Script detects if you're not on a Guix live ISO
- Script warns if multiple filesystems are mounted (existing system)
- Script shows which device will be targeted before proceeding
- **10-second delay** when warnings are triggered (time to abort)

**If you're not absolutely certain you're in the right situation, STOP NOW!**

**Installation:** See [`cloudzy/README.md`](cloudzy/README.md)

**After Boot:** See
[`postinstall/CUSTOMIZATION.md`](postinstall/CUSTOMIZATION.md) to add
SSH/packages

---

### 2. Framework 13 Single-Boot

**⚠️ THIS WILL DESTROY ALL DATA ON THE TARGET DEVICE!**

Designed for **Framework 13 laptops** where you want Guix as your only OS:

- **Wipes the entire disk** and creates new partitions
- **Destroys all existing data** on the laptop
- **Replaces any existing OS** with minimal Guix
- **WiFi firmware** needed after boot (add via customize tool)

**Prerequisites:**

- Fresh Framework 13 or willingness to wipe everything
- Guix live ISO
- Backup of all important data

**Installation:** See [`framework/README.md`](framework/README.md)

**After Boot:** See
[`postinstall/CUSTOMIZATION.md`](postinstall/CUSTOMIZATION.md) to add
WiFi/desktop

---

### 3. Framework 13 Dual-Boot

**Safe dual-boot installation alongside existing Pop!_OS.**

Designed for Framework 13 laptops with existing Pop!_OS installations:

- **Preserves** existing Pop!_OS installation
- **Reuses** existing EFI System Partition
- **Creates** new Guix partition in free space
- **Shares** bootloader with Pop!_OS

**Prerequisites:**

- Existing Pop!_OS installation
- At least 40-60GB free space (unallocated)
- Backup of important data

**Installation:** See [`framework-dual/README.md`](framework-dual/README.md)

**After Boot:** See
[`postinstall/CUSTOMIZATION.md`](postinstall/CUSTOMIZATION.md) to add
desktop/WiFi

---

### 4. Raspberry Pi (Apple Silicon Required)

⚠️ **REQUIRES APPLE SILICON MAC** - Build Raspberry Pi images on M1/M2/M3/M4 Macs.

Designed for building **Raspberry Pi 3/4/5** images using Apple Silicon:

- **Build on Mac** with Apple Silicon (M1/M2/M3/M4)
- **Native ARM64** compilation (no cross-compilation needed)
- **Single image** works on Pi 3, 4, and 5 (all aarch64)
- **Manual firmware** addition (licensing restrictions)
- **Flash to SD card** and boot on any compatible Raspberry Pi

**Prerequisites:**

- **Apple Silicon Mac** (M1, M2, M3, or M4) - Intel Macs won't work
- **Raspberry Pi** (3, 4, or 5)
  - Pi 5: 4GB+ recommended (best performance)
  - Pi 4: 2GB+ works well
  - Pi 3: 1GB (headless/server only)
- MicroSD card (32GB+, Class 10)
- Guix installed on your Mac
- Balena Etcher or `dd` for SD card flashing

**Installation:** See [`raspberry-pi/README.md`](raspberry-pi/README.md)
**After Boot:** Use customize tool + shared recipes

**Why Apple Silicon?**

- Native ARM64 architecture (same as all Raspberry Pi models)
- Fast builds without emulation
- Build once, works on Pi 3, 4, and 5
- Proven workflow on M-series Macs
- Simplified process compared to cross-compilation

---

## Global Mirror Optimization

**Faster downloads worldwide** - The installation scripts automatically
optimize download speeds by selecting the best mirrors for your region.

### Automatic Region Detection

Scripts detect your location and configure:

- **Git repository mirrors** (for `guix pull`)
- **Substitute servers** (for binary downloads)
- **Channel configurations** (post-boot)

### Supported Regions

- 🇨🇳 **Asia/China**: SJTU, Tsinghua mirrors (10x+ faster in China)
- 🇪🇺 **Europe**: Bordeaux build farm, Savannah
- 🇺🇸 **Americas**: CI server, Bordeaux fallback
- 🌍 **Global**: Official mirrors (default)

### Manual Override

```bash
# Set region before installation
export GUIX_REGION="asia"
./run-remote-steps.sh

# Or use custom mirrors
export GUIX_GIT_URL="https://your-mirror.example.com/guix.git"
```

**Full documentation:** [`lib/mirrors.md`](lib/mirrors.md)

---

## Architecture

### New Safety Checks and Logging

- Mounts use filesystem labels (`/dev/disk/by-label/GUIX_ROOT` and `EFI`) for reliability
- Installers verify labels exist before mounting and warn if free space on `/mnt` is < 40GiB
- Command output is tee-logged to `/tmp/guix-install.log` during system init steps
- If an install fails, review `/tmp/guix-install.log` for details

### Go-Based Installer (framework-dual)

The `framework-dual` platform uses a **Go-based installer** for reliability and type safety:

**Benefits:**

- ✅ No bash variable passing issues
- ✅ Type-safe error handling
- ✅ Built-in verification via Git and Go modules
- ✅ Easier to debug and maintain

**Prerequisites (install on Guix ISO first):**

```bash
guix install go gcc-toolchain curl perl rsync
source ~/.guix-profile/etc/profile
```

**Usage from Guix ISO:**

Step 1: Verify the manifest checksum (get this from your local machine after running `./update-manifest.sh`):

**Option A: Hex hash verification (traditional method):**
```bash
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/SOURCE_MANIFEST.txt | shasum -a 256
# Compare the output with the expected hash from update-manifest.sh output
```

**Option B: Word-based verification (easier to read aloud/verify):**
```bash
# After bootstrap builds hash-to-words tool (see Step 2):
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/SOURCE_MANIFEST.txt | shasum -a 256 | awk '{print $1}' | ./hash-to-words
# Compare the word output with the expected words from update-manifest.sh
```

The word-based method converts the 64-character hex hash into a series of readable English words, making it easier to verify over phone/voice or when comparing manually.

Step 2: Download and run the bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/lib/bootstrap-installer.sh -o bootstrap.sh
bash bootstrap.sh
```

**For specific version:**

```bash
export GUIX_INSTALL_REF=v0.1.6  # Use a specific tag
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/${GUIX_INSTALL_REF}/lib/bootstrap-installer.sh -o bootstrap.sh
bash bootstrap.sh
```

**Verification strategy:**

1. Git verifies commit/tag integrity when cloning
2. Go verifies go.mod (and go.sum if external deps exist)
3. Source compiled locally before execution

**Interactive installation flow:**

The installer prompts before each step:

- Answer **"Y"** (yes) to run the step - idempotent design skips already-completed work
- Answer **"n"** (no) to skip and exit - useful for pausing installation

**Idempotency for safe reruns:**

- Step 1: Skips formatting if partition already has ext4 filesystem
- Step 2: Skips store sync if /mnt is mounted and populated
- Step 3: Skips config generation if /mnt/etc/config.scm exists

This means you can safely rerun after interruptions - answer "yes" to all steps and only incomplete work will be performed.

**Manual build (for advanced users):**

```bash
git clone --depth 1 --branch main https://github.com/durantschoon/guix-platform-install.git
cd guix-platform-install
go build -o run-remote-steps .
./run-remote-steps
```

---

### All Platforms Use Go-Based Installer

All platforms (cloudzy, framework, framework-dual, raspberry-pi) now use the **Go-based installer** architecture:

**Benefits:**

- ✅ Type-safe state management (no bash variable passing)
- ✅ Centralized error handling
- ✅ Built-in verification via Git and Go modules
- ✅ Idempotent operations (safe to rerun)
- ✅ Easier to test and maintain

## Preparation

### On local machine

Where repo is cloned, get the shasum256 of the main `run-remote-steps.sh`

**IMPORTANT**: Always get the checksum from the same source you'll download from!

- **For testing/development**: Use `main` branch

- **For stable releases**: Use a specific tag (e.g., `v0.1.3`)

Substitute your command for pbcopy if not on a mac

To check and record on the iso instance:

```bash
# For testing latest changes (main branch)
shasum -a 256 run-remote-steps.sh | pbcopy

# For stable version (specific tag)
git checkout v0.1.3
shasum -a 256 run-remote-steps.sh | pbcopy
```

or instead prepare to manually check

```bash
shasum -a 256 run-remote-steps.sh
```

## Environment Variables

### Pre-Installation Setup (Recommended)

Set these environment variables **before** running the bootstrap script to customize your installation:

```bash
# User configuration
export USER_NAME="yourname"
export FULL_NAME="Your Full Name"
export TIMEZONE="America/New_York"
export HOST_NAME="my-guix-system"

# High-DPI display: Set larger console font before installer runs
export USEBIGFONT="1"  # Use default (solar24x32), or specify any font name from consolefonts directory

# Keyboard: Swap Caps Lock and Left Ctrl (useful for Emacs users)
export KEYBOARD_LAYOUT="us:ctrl:swapcaps"  # or "us" for standard layout

# Then run bootstrap
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/lib/bootstrap-installer.sh | bash -s -- <platform>
```

**Benefits:**
- **USEBIGFONT**: Larger console font makes installer output easier to read on high-DPI displays (Framework 13, etc.)
- **KEYBOARD_LAYOUT**: Caps Lock ↔ Ctrl swap is applied at first login (no need to configure manually)

### DEVICE (auto-detected)

The `DEVICE` environment variable specifies the target storage device for installation. If not set, the script automatically detects from common VPS device names in order of preference:

- `/dev/sda` - Standard SATA/SCSI devices (most common)
- `/dev/vda` - Virtio block devices (KVM/QEMU)
- `/dev/xvda` - Xen virtual block devices
- `/dev/nvme0n1` - NVMe SSD devices (first drive)
- `/dev/nvme1n1` - NVMe SSD devices (second drive)
- `/dev/sdb` - Secondary SATA/SCSI devices
- `/dev/vdb` - Secondary Virtio block devices

You can override with: `DEVICE="/dev/sdb"`

### BOOT_MODE (auto-detected)

The `BOOT_MODE` environment variable specifies the boot mode for the system. If not set, the script automatically detects whether the system uses BIOS or UEFI boot:

- **UEFI**: Uses `grub-efi-bootloader` with `/boot/efi` target
- **BIOS**: Uses `grub-bootloader` with device target

You can override with: `BOOT_MODE="bios"` or `BOOT_MODE="uefi"`

### SWAP_SIZE (default: 4G)

The `SWAP_SIZE` environment variable controls the size of the swap file created during installation. The default of 4G is chosen because:

- **VPS Compatibility**: Covers most VPS memory configurations (1-8GB RAM)
- **Guix Requirements**: Guix package compilation and system updates are memory-intensive
- **Modern Best Practices**: 2-4GB is recommended for systems with 1-8GB RAM
- **Safety Margin**: Provides headroom for memory spikes and system stability
- **Hibernation Support**: Allows for suspend-to-disk if needed

You can customize the swap size using formats like:

- `SWAP_SIZE="2G"` - 2 gigabytes
- `SWAP_SIZE="512M"` - 512 megabytes  
- `SWAP_SIZE="8192K"` - 8192 kilobytes

### USEBIGFONT (optional)

The `USEBIGFONT` environment variable enables automatic setting of a larger console font **before** the installer runs. This makes the installer output easier to read on high-DPI displays (Framework 13, etc.).

**Usage:**
```bash
# Keep current font (skip font change) - EASIEST OPTION
export USEBIGFONT="0"

# Use default font (solar24x32)
export USEBIGFONT="1"  # or "yes", "true", or "t"

# Specify a custom font name (matches on prefix, handles .psf, .psfu, .psf.gz, etc.)
export USEBIGFONT="solar24x32"  # Explicitly use default
export USEBIGFONT="solar24x36"  # Matches solar24x36.psf, solar24x36.psf.gz, etc.
export USEBIGFONT="<font-name>"  # Use any font found in consolefonts directory
```

**What it does:**
- Sets a larger console font immediately when bootstrap script starts
- **`USEBIGFONT="0"`** - Keeps current font (easiest option, no font change)
- If you specify a font name, it matches on prefix (handles `.psf`, `.psfu`, `.psf.gz`, etc.)
- If you use boolean values ("1", "yes", "true", "t"), defaults to `solar24x32`
- If specified font is not found, falls back to `solar24x32`
- Makes installer output easier to read during installation
- Font persists for the duration of the installation session

**Finding available fonts:**
Fonts available on the ISO vary. Check what's available:
```bash
ls /run/current-system/profile/share/consolefonts/
```

**Note:** Available fonts depend on the Guix ISO version. The script will show available fonts if your specified font isn't found. If `solar24x32` isn't available, the script will attempt to find any large font (containing "32" in the name).

**Recommended for:**
- Framework 13 AMD (2256x1504 display)
- Any high-DPI laptop display
- Users who find default console font too small

**Note:** Font is set temporarily for the installation session. To make it permanent, add console-font-service-type to your config.scm after installation (see [`docs/CONSOLE_FONT_TIPS.md`](docs/CONSOLE_FONT_TIPS.md)).

### KEYBOARD_LAYOUT (optional)

The `KEYBOARD_LAYOUT` environment variable configures keyboard layout and options for the installed system. Set this **before** running the bootstrap script.

**Usage:**
```bash
# Standard US layout
export KEYBOARD_LAYOUT="us"

# US layout with Caps Lock ↔ Left Ctrl swap (recommended for Emacs users)
export KEYBOARD_LAYOUT="us:ctrl:swapcaps"
```

**Format:** `layout:option1:option2` (e.g., `us:ctrl:swapcaps`)

**Options:**
- **`us`** - Standard US keyboard layout
- **`us:ctrl:swapcaps`** - US layout with Caps Lock and Left Ctrl swapped (useful for Emacs)

**When to use:**
- Set before bootstrap script to avoid prompts during installation
- Caps Lock ↔ Ctrl swap is especially useful for Emacs users
- Applied automatically at first login (no manual configuration needed)

**Note:** If not set, the installer will prompt you during config generation (step 3).

### GUIX_PLATFORM (default: cloudzy)

The `GUIX_PLATFORM` environment variable specifies which platform's installation scripts to use. If not set, defaults to `cloudzy`:

- **`cloudzy`** (default) - VPS fresh install (Cloudzy and similar providers)
- **`framework`** - Framework 13 single-boot (Guix only)
- **`framework-dual`** - Framework 13 dual-boot with Pop!_OS

You can override with: `GUIX_PLATFORM="framework"` or `GUIX_PLATFORM="framework-dual"`

**Platform-specific script sequences:**

- **cloudzy**: `01-partition` → `02-mount-bind` → `03-config-write` → `04-system-init`
- **framework**: `01-partition` → `02-mount-bind` → `03-config-write` → `04-system-init`
- **framework-dual**: `01-partition-check` → `02-mount-existing` → `03-config-dual-boot` → `04-system-init`

**Note**: Raspberry Pi installation uses a different approach (image-based) and is not supported by this script-based installer.

---

## Development

### Running Tests

For detailed testing information, see [`docs/TESTING.md`](docs/TESTING.md).

Common development tasks have stable GNU Make entry points:

```bash
make test
make manifest
make oracle-help
```

The underlying scripts remain directly executable; Make is a documented
interface, not a second implementation.

**Local Testing** (requires Go 1.21+):

```bash
./run-tests.sh
```

Runs unit tests for:
- Common library functions ([lib/common.go](lib/common.go))
- Platform-specific installation steps
- String operations and error handling
- State management

**Docker Testing** (no local Go installation needed):

```bash
# Run all tests in Docker container
./test-docker.sh

# Open interactive shell for debugging
./test-docker.sh shell

# Clean up Docker volumes
./test-docker.sh clean
```

The Docker environment uses Alpine Linux + Go 1.21 and includes all necessary tools (bash, partitioning utilities, etc.). Works with Docker Desktop or Colima.

**Test Files:**
- [lib/common_test.go](lib/common_test.go) - Unit tests for shared functions
- `*/install/*_test.go` - Platform-specific integration tests
- [cmd/hash-to-words/main_test.go](cmd/hash-to-words/main_test.go) - Hash verification tool tests

See [`docs/TESTING.md`](docs/TESTING.md) for complete test documentation including test structure, coverage details, and how to add new tests.

### Updating Manifest

After modifying installation scripts, update the manifest:

```bash
./update-manifest.sh
```

This regenerates SHA256 checksums for all critical scripts and displays the manifest hash for verification.

### Contributing

**Platform-specific READMEs:**

- [cloudzy/README.md](cloudzy/README.md) - VPS installation
- [framework/README.md](framework/README.md) - Framework 13 single-boot
- [framework-dual/README.md](framework-dual/README.md) - Framework 13 dual-boot
- [raspberry-pi/README.md](raspberry-pi/README.md) - Raspberry Pi images

**Technical documentation:**

- [docs/INSTALLATION_KNOWLEDGE.md](docs/INSTALLATION_KNOWLEDGE.md) - Implementation details and lessons learned
- [CLAUDE.md](CLAUDE.md) - Development notes for AI assistants
