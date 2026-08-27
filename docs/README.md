# Documentation Guide

**Pick your path based on your experience level:**

## 🚀 New to Guix? Start here:
- **[Quickstart for Beginners](../QUICKSTART.md)** - Simple, opinionated path
  - Assumes you know basic Unix (cd, ls, mounting filesystems)
  - Walks you through ISO boot → installed system → first customizations
  - Explains Guix concepts as you encounter them

## 🔧 Experienced with Guix? Advanced guides:
- **[Seasoned Guix User Guide](GUIDE_SEASONED_GUIX.md)** - Advanced configuration
  - Channel pinning and substitute servers
  - System profiles and generations
  - Custom package definitions
  - Development workflows

## 💻 Setting up dual-boot? Hardware-specific:
- **[Dual-Boot Guide](GUIDE_DUAL_BOOT.md)** - Framework 13 + Pop!_OS
  - Preserving existing OS
  - GRUB configuration for chainloading
  - Partition management without data loss

## 📚 Need technical reference? Troubleshooting?
- **[Reference Documentation Guide](GUIDE_REFERENCE.md)** - Technical deep-dives
  - Installation troubleshooting
  - System configuration
  - Hardware-specific issues
  - Recovery and automation
  - Installation internals

## 👨‍💻 Contributing to this project?
- **[Contributing Guide](GUIDE_CONTRIBUTING.md)** - Developer documentation
  - Getting started with the codebase
  - Development workflows
  - Code patterns and best practices
  - Testing procedures
  - Process documentation

## 🖥️ Platform-Specific Guides

**Platform-specific installation details:**
- **[VPS Installation](../cloudzy/README.md)** - Cloudzy, DigitalOcean, AWS
- **[Framework 13 Single-Boot](../framework/README.md)** - Framework 13 (Guix only)
- **[Framework 13 Dual-Boot](../framework-dual/README.md)** - Framework 13 + Pop!_OS
- **[Raspberry Pi](../raspberry-pi/README.md)** - Raspberry Pi 3/4/5
- **[Oracle Cloud](../oracle/README.md)** - Generic image and disposable validation workflow

## 📚 Reference Documentation (Quick Links)

### Installation & Troubleshooting
- **[Installation Knowledge](INSTALLATION_KNOWLEDGE.md)** - Deep technical details
- **[Troubleshooting Guide](TROUBLESHOOTING.md)** - Common issues and solutions
- **[Verification Guide](VERIFICATION.md)** - Verify installation integrity
- **[Automation Analysis](AUTOMATION_ANALYSIS.md)** - Recovery script details

### Post-Install Customization
- **[Customization Guide](../postinstall/CUSTOMIZATION.md)** - Adding features after install
- **[Channel Management](../postinstall/CHANNEL_MANAGEMENT.md)** - Configure Guix channels
- **[Emacs Import Guide](../postinstall/EMACS_IMPORT_GUIDE.md)** - Import existing Emacs config

### System Configuration
- **[Console Font Tips](CONSOLE_FONT_TIPS.md)** - High-DPI display fonts
- **[Disable rsyslog MARK](DISABLE_RSYSLOG_MARK.md)** - Disable keepalive messages
- **[GNOME Login Troubleshooting](GNOME_LOGIN_TROUBLESHOOTING.md)** - Desktop environment issues

## 🗺️ Suggested Reading Paths

### Path 1: First-Time Guix User (Fresh VPS Install)
1. [Quickstart for Beginners](../QUICKSTART.md)
2. [Installation Knowledge](INSTALLATION_KNOWLEDGE.md) - Sections: cow-store, Bash paths, Environment variables
3. [Customization Guide](../postinstall/CUSTOMIZATION.md) - Add SSH and essential packages
4. Come back to advanced topics as needed

### Path 2: Experienced Guix User (Framework 13 Install)
1. [Seasoned Guix User Guide](GUIDE_SEASONED_GUIX.md)
2. [Installation Knowledge](INSTALLATION_KNOWLEDGE.md) - Sections: Nonguix channels, Kernel/initrd workaround
3. [GNOME Login Troubleshooting](GNOME_LOGIN_TROUBLESHOOTING.md) - If needed
4. [Automation Analysis](AUTOMATION_ANALYSIS.md) - Understanding recovery scripts

### Path 3: Dual-Boot Setup (Framework 13 + Pop!_OS)
1. [Dual-Boot Guide](GUIDE_DUAL_BOOT.md)
2. [Installation Knowledge](INSTALLATION_KNOWLEDGE.md) - Sections: Partition detection, Label-based mounting
3. [Customization Guide](../postinstall/CUSTOMIZATION.md)
4. [Seasoned Guix User Guide](GUIDE_SEASONED_GUIX.md) - Channel management

## 👨‍💻 Developer Resources (Quick Links)

**See [Contributing Guide](GUIDE_CONTRIBUTING.md) for complete developer documentation.**

- **[Repository Structure](STRUCTURE.md)** - Codebase organization
- **[Testing Guide](TESTING.md)** - Test suite documentation
- **[Postinstall Development](POSTINSTALL_DEV.md)** - Postinstall script development
- **[Guile Best Practices](GUILE_BEST_PRACTICES.md)** - Scheme/Guile patterns
- **[Guile Gotchas](GUILE_GOTCHAS.md)** - Common pitfalls
- **[Guile Knowledge](GUILE_KNOWLEDGE.md)** - Quick reference
- **[Guile Conversion](GUILE_CONVERSION.md)** - Bash to Guile conversion
- **[Time Tracking Retrospective](TIME_TRACKING_RETROSPECTIVE.md)** - Process insights
- **[Batch Conversion Best Practices](BATCH_CONVERSION_BEST_PRACTICES.md)** - Conversion workflow
- **[CLAUDE.md](../CLAUDE.md)** - Development notes for AI assistants
- **[Checklist](../CHECKLIST.md)** - Development status

---

**Not sure where to start?** Most users should begin with the [Quickstart](../QUICKSTART.md).
