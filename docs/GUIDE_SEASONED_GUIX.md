# Guide for Seasoned Guix Users

**For users already familiar with Guix System who want advanced configuration, channel management, and development workflows.**

This guide assumes you understand:
- Basic Guix concepts (packages, services, system generations)
- How to edit `/etc/config.scm`
- Running `guix system reconfigure`

If you're new to Guix, start with the [Quickstart](../QUICKSTART.md) instead.

---

## Table of Contents

1. [Channel Management](#channel-management)
2. [Substitute Servers](#substitute-servers)
3. [System Profiles and Generations](#system-profiles-and-generations)
4. [Custom Package Definitions](#custom-package-definitions)
5. [Development Workflows](#development-workflows)
6. [PATH Management](#path-management)
7. [Advanced Recovery](#advanced-recovery)

---

## Channel Management

### Understanding Channels

Guix channels are Git repositories that extend the package collection. The installer supports:

- **Default channels**: Official Guix + nonguix (for proprietary firmware)
- **Custom channels**: Your own channel repositories
- **Channel pinning**: Lock to specific commits for reproducibility

### Channel Pinning for Reproducibility

**Why pin channels?** Different channel commits produce different package versions. Pinning ensures reproducible builds across systems and time.

**Example: Framework 13 AMD GPU Issues**

Framework 13 AMD laptops may experience GDM login loops with current guix/nonguix master commits. Solution: Pin to known-good commits:

```scheme
;; wingolog-channels.scm
(list
  (channel
    (name 'guix)
    (url "https://git.savannah.gnu.org/git/guix.git")
    (branch "master")
    (commit "91d80460296e2d5a01704d0f34fb966a45a165ae"))
  (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (branch "master")
    (commit "10318ef7dd53c946bae9ed63f7e0e8bb8941b6b1")
    (introduction
      (make-channel-introduction
       "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
       (openpgp-fingerprint
        "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
```

**Using pinned channels:**

```bash
# Reconfigure with pinned channels
sudo guix time-machine -C ~/wingolog-channels.scm -- \
  system reconfigure /etc/config.scm
```

**Finding good commits:**

1. Check [Wingo's Framework 13 AMD guide](https://wingolog.org/archives/2024/02/16/guix-on-the-framework-13-amd) for known-good combinations
2. Test commits incrementally: start with older known-good, move forward
3. Document working combinations in your channels.scm

### Custom Channel Repositories

**Using your own channel repository:**

```bash
# Set environment variables
export GUIX_CHANNEL_REPO="https://github.com/yourusername/guix-config"
export GUIX_CHANNEL_BRANCH="main"
export GUIX_CHANNEL_PATH="channels/"

# Run installer - it will download and use your channels.scm
curl -fsSL https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/lib/bootstrap-installer.sh | bash
```

**Channel repository structure:**

```
your-guix-config/
├── channels/
│   └── channels.scm
├── systems/
│   ├── desktop.scm
│   └── server.scm
└── README.md
```

**Example channels.scm with custom channel:**

```scheme
(cons* 
 ;; Your custom channel
 (channel
  (name 'my-channel)
  (url "https://github.com/yourusername/my-guix-channel")
  (branch "main"))
 
 ;; Nonguix for proprietary firmware
 (channel
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (branch "master")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint
     "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
 %default-channels)
```

See [postinstall/CHANNEL_MANAGEMENT.md](../postinstall/CHANNEL_MANAGEMENT.md) for complete channel management details.

### The Two-Pull Process (Framework Installations)

**Critical Finding:** After installing Guix on Framework 13, you must perform a two-pull process to add the nonguix channel.

**Why two pulls?**

1. **First `guix pull`**: Upgrades from Guix 1.4.0 (ISO) to latest master
   - Required because old Guix doesn't support channel introductions
   - Takes 10-30 minutes
   - Creates generation 1

2. **Create `~/.config/guix/channels.scm`** with nonguix channel

3. **Second `guix pull`**: Adds nonguix channel
   - Takes 10-30 minutes
   - Creates generation 2

4. **Fix PATH** (CRITICAL):
   ```bash
   export PATH="$HOME/.config/guix/current/bin:$PATH"
   # Add to ~/.bashrc for persistence
   ```

**Common pitfall:** Without PATH update, `guix describe` shows generation 1 (system) instead of generation 2 (user), and nonguix packages won't be found.

---

## Substitute Servers

### Understanding Substitutes

Substitutes are pre-built binaries that Guix downloads instead of building locally. This dramatically speeds up installations.

### Multiple Substitute URLs

**Why use multiple URLs?** Mirrors can be flaky. Multiple URLs provide redundancy:

```bash
guix system init /mnt/etc/config.scm /mnt \
  --fallback \
  --substitute-urls="https://substitutes.nonguix.org https://ci.guix.gnu.org https://bordeaux.guix.gnu.org"
```

**Common substitute servers:**

- `https://ci.guix.gnu.org` - Official CI server
- `https://bordeaux.guix.gnu.org` - Bordeaux mirror
- `https://substitutes.nonguix.org` - Nonguix substitutes (requires authorization)

### Authorizing Nonguix Substitutes

**Required for nonguix channel:**

```bash
wget -qO- https://substitutes.nonguix.org/signing-key.pub | guix archive --authorize
```

**Why authorize?** Guix verifies substitute signatures. You must authorize each substitute server's signing key.

### Managing Substitute Cache

**Check cache size:**

```bash
du -sh /var/guix/substitute-cache
```

**Clear cache if low on space:**

```bash
rm -rf /var/guix/substitute-cache/*
```

**Monitor cache growth:**

```bash
watch -n 1 'du -sh /var/guix/substitute-cache'
```

### Peer-to-Peer Substitutes (GIPS) & Web of Trust

For decentralized environments (local LAN clusters, home servers, Oracle Always Free VPS nodes), the **Guix IPFS Package Substitutes (GIPS)** service provides federated P2P substitute distribution with cryptographic integrity:

```bash
# Point guix-daemon to local GIPS substitute proxy
guix-daemon --substitute-urls="http://127.0.0.1:8080 https://ci.guix.gnu.org"
```

#### Web of Trust (WoT) & Capability Delegation
GIPS uses UCAN-style delegation tokens to establish transitive trust with monotonic capability attenuation:
- **Depth attenuation**: Delegation depth decrements on every hop.
- **Prefix constraints**: Capabilities restrict delegation to specific `/gnu/store/...` paths.
- **Stake decay**: Trust scores decay predictably (15% per hop) across transitive delegations.

#### Objective Cryptographic Fraud Proofs & Gossip
When a malicious publisher signs invalid metadata or equivocates:
- **`HashMismatch`**: Proves delivered NAR bytes do not match the signed `NarHash`.
- **`Equivocation`**: Proves conflicting manifest feeds signed by the same publisher key.
- **Autonomous Gossip**: Broadcast over IPFS PubSub (`gips.fraud.v1`) and GNUnet CADET. Once received, any downstream Web-of-Trust score is severed to 0, immediately protecting the swarm.

---

## System Profiles and Generations

### Understanding Generations

Guix maintains multiple system generations. Each `guix system reconfigure` creates a new generation.

**List generations:**

```bash
guix system list-generations
```

**Switch generations:**

- At GRUB menu: Select previous generation
- After reboot: System uses selected generation

**Rollback:**

```bash
# Reboot and select previous generation in GRUB
# Or reconfigure to previous config.scm
```

### System Profile Location

**System profile symlink:**

```bash
ls -la /run/current-system
# Points to: /gnu/store/...-system
```

**System binaries:**

```bash
/run/current-system/profile/bin/guix
```

**Why this matters:** Scripts running on Guix ISO must use `/run/current-system/profile/bin/bash` shebang, not `/bin/bash` or `/usr/bin/env bash`.

### User Profiles vs System Profiles

**System Guix (old):**
- Location: `/run/current-system/profile/bin/guix`
- From ISO or system installation
- Limited to system packages

**User Guix (pulled):**
- Location: `~/.config/guix/current/bin/guix`
- From `guix pull`
- Includes all channels (nonguix, custom, etc.)

**Critical:** Always verify which `guix` binary is active:

```bash
which guix
# Should show: /home/username/.config/guix/current/bin/guix (after pull)
```

---

## Custom Package Definitions

### Creating Custom Packages

**Basic package definition:**

```scheme
(define-public my-package
  (package
    (name "my-package")
    (version "1.0")
    (source (origin
              (method url-fetch)
              (uri "https://example.com/my-package-1.0.tar.gz")
              (sha256 (base32 "0abc123..."))))
    (build-system gnu-build-system)
    (synopsis "My custom package")
    (description "Description of my package.")
    (home-page "https://example.com")
    (license gpl3+)))
```

**Adding to config.scm:**

```scheme
(packages
  (append (list my-package)
          %base-packages))
```

### Local Package Development

**Using `guix shell` for development:**

```bash
# Create development environment
guix shell gcc make pkg-config -- bash

# Build your package
./configure && make
```

**Testing package builds:**

```bash
# Build locally
guix build my-package

# Install temporarily
guix install my-package
```

### Package Overrides

**Override package variants:**

```scheme
(define my-python
  (package
    (inherit python)
    (name "python-with-custom-features")
    (arguments
     (substitute-keyword-arguments (package-arguments python)
       ((#:configure-flags flags)
        `(cons* "--enable-feature" flags))))))
```

---

## Development Workflows

### Using guix time-machine

**Why use time-machine?** Ensures reproducible builds with pinned channel commits.

**Basic usage:**

```bash
guix time-machine -C ~/channels.scm -- \
  system reconfigure /etc/config.scm
```

**With custom channels:**

```bash
# Set CHANNELS_PATH environment variable
export CHANNELS_PATH="/path/to/wingolog-channels.scm"

# Recovery script auto-detects and uses it
./lib/enforce-guix-filesystem-invariants.sh
```

**Development workflow:**

1. Pin channels to known-good commits
2. Use `guix time-machine` for all system reconfigures
3. Test incrementally newer commits
4. Update channels.scm when stable

### Environment Variables in Chroot

**Critical for chroot operations:**

```bash
# Set PATH before chroot reconfigure
SYSTEM=$(readlink -f /var/guix/profiles/system)
export PATH="$SYSTEM/profile/bin:/run/setuid-programs:$PATH"

# Then chroot and reconfigure
chroot /mnt /bin/bash -c "
  export PATH=\"\$SYSTEM/profile/bin:/run/setuid-programs:\$PATH\"
  guix system reconfigure /etc/config.scm
"
```

**Why this matters:** Chroot environment lacks full PATH. System binaries must be explicitly included.

### Recovery Script Automation

**All manual recovery steps can be automated:**

The `lib/enforce-guix-filesystem-invariants.sh` script automates:

- Filesystem invariant setup (symlinks, resolv.conf)
- PATH setup for chroot
- Custom channels support via `CHANNELS_PATH`
- Bind mounts (/proc, /sys, /dev)

**Usage:**

```bash
# With custom channels
export CHANNELS_PATH="/path/to/wingolog-channels.scm"
./lib/enforce-guix-filesystem-invariants.sh

# Auto-detects channels from common locations
./lib/enforce-guix-filesystem-invariants.sh
```

See [AUTOMATION_ANALYSIS.md](AUTOMATION_ANALYSIS.md) for complete details.

---

## PATH Management

### The PATH Problem

**Symptoms:**
- `guix describe` shows generation 1 (system) instead of generation 2 (user)
- Nonguix packages not found even though channel was added
- `guix search` doesn't find packages from nonguix channel

**Root cause:** PATH not updated to include user's Guix profile.

### Solution

**Add to `~/.bashrc`:**

```bash
export PATH="$HOME/.config/guix/current/bin:$PATH"
```

**Reload shell:**

```bash
source ~/.bashrc
```

**Verify:**

```bash
which guix
# Should show: /home/username/.config/guix/current/bin/guix

guix describe
# Should show generation 2 with nonguix channel
```

### Why This Happens

- Guix has multiple generations and profiles
- System Guix (old) is at `/run/current-system/profile/bin/guix`
- User's pulled Guix is at `~/.config/guix/current/bin/guix`
- Without PATH update, shell uses system Guix by default

**Always verify:** `which guix` before assuming channel availability.

---

## Advanced Recovery

### Kernel/Initrd Workaround (time-machine + nonguix)

**Problem:** When using `guix time-machine` with nonguix channel, `guix system init` creates a system generation but fails to copy kernel/initrd files to `/boot/`.

**Solution: Three-step workaround**

1. **Build system generation:**
   ```bash
   guix time-machine -C channels.scm -- \
     system build /mnt/etc/config.scm
   ```

2. **Manually copy kernel/initrd:**
   ```bash
   SYSTEM=$(readlink -f /mnt/var/guix/profiles/system)
   cp "$SYSTEM/boot/vmlinuz"* /mnt/boot/
   cp "$SYSTEM/boot/initrd"* /mnt/boot/
   ```

3. **Run system init:**
   ```bash
   guix time-machine -C channels.scm -- \
     system init /mnt/etc/config.scm /mnt
   ```

**Why this works:** `system build` creates complete system generation with all files. Manual copy ensures kernel/initrd are in `/boot/` before `system init` runs.

### System Generation Symlink Verification

**Check if system generation exists:**

```bash
ls -la /mnt/var/guix/profiles/system
# Should be symlink to /gnu/store/...-system
```

**If symlink is broken:**

```bash
echo "ERROR: System generation symlink missing - system generation not created"
# Indicates system generation wasn't built correctly
```

**Diagnostic steps:**

1. Check system generation symlink
2. Verify kernel/initrd exist in system generation
3. If files missing but system generation exists, manually copy them

### Chroot Networking (resolv.conf)

**Critical:** Chroot environment needs `/etc/resolv.conf` for network access.

**Automated setup:**

The recovery script automatically copies ISO's resolv.conf:

```bash
# Script does this automatically:
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Verifies copy succeeded (fails hard if not)
if [ ! -f /mnt/etc/resolv.conf ] || [ ! -s /mnt/etc/resolv.conf ]; then
    echo "ERROR: Failed to copy resolv.conf"
    exit 1
fi
```

**Manual setup:**

```bash
# Copy ISO's resolv.conf before chroot
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Verify
cat /mnt/etc/resolv.conf
```

**Why this matters:** Without resolv.conf, `guix system reconfigure` cannot download packages in chroot.

---

## Quick Reference

### Essential Commands

```bash
# Channel management
guix pull -C ~/.config/guix/channels.scm
guix describe

# System management
guix system reconfigure /etc/config.scm
guix system list-generations
guix system rollback

# Package management
guix install package-name
guix upgrade
guix search keyword

# Development
guix shell package-name -- bash
guix build package-name
guix time-machine -C channels.scm -- command

# Verification
which guix
guix describe
ls -la /run/current-system
```

### Common Aliases

Add to `~/.bashrc`:

```bash
alias g='guix'
alias gs='guix shell'
alias gp='guix pull'
alias gi='guix install'
alias gu='guix upgrade'
alias gr='guix remove'
alias gd='guix describe'
alias gt='guix time-machine'
```

---

## Further Reading

- [Installation Knowledge](INSTALLATION_KNOWLEDGE.md) - Deep technical details
- [Channel Management](../postinstall/CHANNEL_MANAGEMENT.md) - Complete channel guide
- [Automation Analysis](AUTOMATION_ANALYSIS.md) - Recovery script details
- [Guile Best Practices](GUILE_BEST_PRACTICES.md) - Scheme/Guile patterns
- [Guile Gotchas](GUILE_GOTCHAS.md) - Common pitfalls

---

**Next Steps:** If you're setting up dual-boot, see [Dual-Boot Guide](GUIDE_DUAL_BOOT.md). For troubleshooting specific issues, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

