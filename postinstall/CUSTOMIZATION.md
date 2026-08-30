# Guix System Customization Guide

After installing the minimal Guix system, use this guide to customize your installation.

## Philosophy

The installation scripts create a **truly minimal** bootable Guix system with:

- ✅ Base system packages only (`%base-packages`)
- ✅ Base services only (`%base-services`)
- ✅ User account with sudo access
- ✅ Network support
- ❌ No SSH server
- ❌ No desktop environment
- ❌ No extra packages

**Why minimal?** Get a working system fast, then customize for your specific needs (VPS server, Framework laptop, development workstation, etc.).

---

## Quick Start: `guix-customize` Tool

After first boot, copy the customization tool to your system:

```bash
# Download the tool
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/guix-platform-install/main/lib/guix-customize -o ~/guix-customize
chmod +x ~/guix-customize

# Run interactive customization
./guix-customize
```

### Interactive Menu Options

```text
Services & Features:
  1) Add SSH service
  2) Add desktop environment (GNOME, Xfce, MATE, LXQt)
  3) Add common packages (git, vim, emacs, htop, curl, wget)

Hardware:
  4) Add Framework 13 hardware support (WiFi/BT firmware)
  5) Show nonguix channel info (proprietary software)

Actions:
  r) Apply changes (reconfigure system)
  e) Edit config manually
  v) View current config
  q) Quit
```

---

## Manual Customization Workflows

### Workflow 1: VPS Server Setup

**Goal:** Headless server with SSH access

```bash
# 1. Add SSH service
sudo nano /etc/config.scm
```

Add to `use-modules`:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services ssh))  ; Add this line
```

Change services:

```scheme
(services
  (append
   (list (service openssh-service-type))
   %base-services))
```

```bash
# 2. Apply changes
sudo guix system reconfigure /etc/config.scm

# 3. SSH is now running on port 22
```

---

### Workflow 2: Framework 13 Desktop

**Goal:** Laptop with GNOME, WiFi, and common tools

```bash
sudo nano /etc/config.scm
```

Add modules:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services desktop)  ; Desktop environments
             (gnu packages linux))   ; Firmware
```

Add firmware (for WiFi/Bluetooth):

```scheme
(operating-system
 (firmware (list linux-firmware))  ; Add this line
 (host-name "framework-guix")
 ...
```

Add desktop and packages:

```scheme
(packages
  (append (list (specification->package "emacs")
                (specification->package "git")
                (specification->package "vim")
                (specification->package "firefox")
                (specification->package "htop"))
          %base-packages))

(services
  (append
   (list (service gnome-desktop-service-type))
   %base-services))
```

Apply:

```bash
sudo guix system reconfigure /etc/config.scm
sudo reboot  # Desktop will start on next boot
```

---

### Workflow 3: Development Workstation

**Goal:** Full development environment with Docker-like tools

```bash
sudo nano /etc/config.scm
```

Add development packages:

```scheme
(packages
  (append (list (specification->package "git")
                (specification->package "emacs")
                (specification->package "vim")
                (specification->package "gcc-toolchain")
                (specification->package "make")
                (specification->package "python")
                (specification->package "node")
                (specification->package "docker")
                (specification->package "docker-compose"))
          %base-packages))
```

Add Docker service:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services docker))

(services
  (append
   (list (service openssh-service-type)
         (service docker-service-type))
   %base-services))
```

---

## Adding Proprietary Software (Nonguix)

For proprietary firmware, drivers, or software (Steam, Discord, etc.):

### 1. Add Nonguix Channel

Create `~/.config/guix/channels.scm`:

```scheme
(cons* (channel
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

### 2. Update and Reconfigure

```bash
guix pull
sudo guix system reconfigure /etc/config.scm
```

### 3. Install Nonguix Packages

```bash
# Install proprietary NVIDIA drivers
guix install nvidia-driver

# Install Steam
guix install steam
```

---

## Platform-Specific Optimizations

### Framework 13

**Better battery life:**

```scheme
(use-modules (gnu services pm))

(services
  (append
   (list (service tlp-service-type))  ; Laptop power management
   %base-services))
```

**Better audio:**

```scheme
(use-modules (gnu services audio))

(services
  (append
   (list (service pipewire-service-type))  ; Modern audio stack
   %base-services))
```

### VPS/Server

**Faster boot:**

```scheme
(bootloader-configuration
 (bootloader grub-efi-bootloader)
 (targets '("/boot/efi"))
 (timeout 1)  ; Fast boot (1 second GRUB timeout)
 (terminal-outputs '(console)))  ; No splash screen
```

**Minimal kernel:**

```scheme
(kernel linux-libre-minimal)  ; Smaller kernel, faster boot
```

---

## Common Customization Recipes

### Installing Emacs (Multiple Options)

The guix-customize tool includes three Emacs recipe options pre-installed in `~/guix-customize/recipes/`:

**Option 1: Spacemacs** - Emacs distribution with Vim keybindings and layers

```bash
cd ~/guix-customize
./recipes/add-spacemacs.sh
```

**Option 2: Doom Emacs** - Modern, fast Emacs framework with great defaults

```bash
cd ~/guix-customize
./recipes/add-doom-emacs.sh
```

**Option 3: Vanilla Emacs** - Plain Emacs with sensible minimal configuration

```bash
cd ~/guix-customize
./recipes/add-vanilla-emacs.sh
```

All three recipes:

- Add Emacs and dependencies to your config.scm using idiomatic Guix style
- Support importing your existing config from a Git repository
- Create appropriate configuration files for first-time users
- Provide clear next steps after installation

**Importing Your Existing Config:**

Each recipe will ask if you want to import an existing configuration from a Git repository. You can:

- Provide your dotfiles repo URL to import automatically during setup
- Skip import and do it manually later

For detailed import instructions, see: `~/guix-customize/EMACS_IMPORT_GUIDE.md`

**Example: Importing Doom Emacs config**

```bash
# Recipe will prompt for repo URL like:
# https://github.com/yourusername/doom-config

# Or import manually later:
git clone https://github.com/yourusername/doom-config ~/.config/doom
~/.config/emacs/bin/doom sync
```

---

### Add User to Docker Group

```scheme
(user-account
 (name "yourname")
 (comment "Your Name")
 (group "users")
 (supplementary-groups '("wheel" "netdev" "audio" "video" "docker")))
```

### Change Timezone

```scheme
(timezone "America/Los_Angeles")  ; Or your timezone
```

### Add Swap File

```bash
# Create 4GB swap file
sudo dd if=/dev/zero of=/swapfile bs=1G count=4
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Add to config.scm:

```scheme
(swap-devices
 (list (swap-space
        (target "/swapfile"))))
```

---

## Recommended System Services

### Power Management (Laptops)

**TLP** provides automatic power management for laptops:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services pm))  ; Add this line

(services
  (append
   (list (service tlp-service-type))
   %base-services))
```

**Benefits:**

- Automatic battery optimization
- CPU frequency scaling
- USB autosuspend
- Disk power management

**After adding:** `sudo guix system reconfigure /etc/config.scm && sudo reboot`

---

### Time Synchronization

**NTP** keeps your system clock accurate:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services networking))  ; Add this line

(services
  (append
   (list (service ntp-service-type))
   %base-services))
```

**Why you need this:**

- SSL/TLS certificates require accurate time
- Log timestamps will be correct
- Scheduled tasks run at the right time

**Note:** Most modern systems already include basic time sync in `%base-services`. Only add if you need advanced NTP features.

---

### SSD Maintenance (fstrim)

**Periodic TRIM** keeps SSDs healthy and fast:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services linux))  ; Add this line

(services
  (append
   (list (service fstrim-service-type))
   %base-services))
```

**Benefits:**

- Maintains SSD performance
- Extends SSD lifespan
- Runs weekly by default

**Recommended for:** Any system with SSD/NVMe storage

---

### Better Entropy (Random Number Generation)

**rngd** provides better entropy for cryptographic operations:

```scheme
(use-modules (gnu)
             (gnu system nss)
             (gnu services base))  ; Add this line

(services
  (append
   (list (service rngd-service-type))
   %base-services))
```

**Benefits:**

- Faster cryptographic operations
- Reduces boot delays waiting for entropy
- Better security for key generation

**Recommended for:** Servers and systems doing crypto operations

---

### Complete Laptop Setup Example

Combining all recommended services for a laptop:

```scheme
(use-modules (gnu)
             (gnu packages linux)
             (gnu system nss)
             (gnu services desktop)      ; Desktop environment
             (gnu services pm)           ; Power management
             (gnu services networking)   ; NetworkManager
             (gnu services linux)        ; fstrim
             (nongnu packages linux)     ; Proprietary kernel/firmware
             (nongnu system linux-initrd))

(operating-system
 (host-name "framework13")
 (timezone "America/New_York")
 (locale "en_US.utf8")

 ;; Hardware support
 (kernel linux)
 (firmware (list linux-firmware))
 (initrd-modules
  (append '("amdgpu" "nvme" "xhci_pci" "usbhid" "i2c_piix4")
          %base-initrd-modules))

 ;; ... bootloader and file-systems sections ...

 (services
  (append
   (list
    ;; Desktop
    (service gnome-desktop-service-type)

    ;; Power management
    (service tlp-service-type)

    ;; SSD maintenance
    (service fstrim-service-type)

    ;; Better entropy
    (service rngd-service-type))

   %desktop-services))  ; Use %desktop-services (includes NetworkManager, time sync, etc.)

 ;; ... users and packages sections ...
)
```

**Note:** `%desktop-services` already includes NetworkManager, NTP, and many other useful services. See [official docs](https://guix.gnu.org/manual/en/html_node/Desktop-Services.html) for the full list.

---

## Troubleshooting

### WiFi Not Working (Framework 13)

1. Add `linux-firmware` package (see Workflow 2 above)
2. If still not working, add nonguix channel for proprietary firmware
3. Reboot after reconfiguring

### Can't SSH In

1. Check SSH service is added to config.scm
2. Check firewall: `sudo guix install nftables`
3. Verify SSH is running: `sudo herd status ssh-daemon`

### Desktop Won't Start

1. Make sure you added desktop service to config.scm
2. Reboot after reconfiguring (desktop services need clean boot)
3. Check what display manager services are available:
   ```bash
   sudo herd status
   # Look for: gdm (GNOME), lightdm (Xfce/MATE/LXQt), or sddm (KDE)
   ```
4. Check if display manager is running:
   ```bash
   # For GNOME:
   sudo herd status gdm
   
   # For Xfce/MATE/LXQt:
   sudo herd status lightdm
   ```
5. If service not found, check your config.scm:
   ```bash
   grep -i "desktop-service-type\|gdm\|lightdm" /etc/config.scm
   ```
6. Check logs (if service exists):
   ```bash
   sudo journalctl -u gdm    # For GNOME
   sudo journalctl -u lightdm  # For Xfce/MATE/LXQt
   ```

### Can't Log In to GNOME (Password Not Working)

**Symptom:** Password works in text console but not at GNOME login screen (GDM)

**Possible Causes:**

1. **Keyboard layout mismatch** - Password was set with a different keyboard layout than GDM uses
2. **Password set during installation** - Password might have been set before keyboard layout was configured
3. **GDM using different base layout** - GDM might not be inheriting the system keyboard layout from `config.scm`
4. **Num Lock state** - If password contains numbers, Num Lock state might differ between console and GDM
5. **Special characters** - Password might contain characters that are mapped differently in GDM vs console

**Diagnosis Steps:**

1. **Test what keyboard layout GDM is actually using:**
   - At the GDM login screen, click in the password field
   - Type a test string like "qwerty" or "asdf" (you won't see it, but it's being entered)
   - If you type "q" and get "a" instead, GDM might be using Dvorak
   - If characters don't match what you expect, GDM is using a different layout than your console

2. **Check your config.scm:**
   ```bash
   grep -A 3 "keyboard-layout" /etc/config.scm
   ```
   - Note what layout is configured (should be "us" for QWERTY)
   - Check if there are any options like `#:options '("ctrl:swapcaps")`

3. **Check when password was set:**
   - Was it set during installation (before keyboard layout was configured)?
   - Was it set after configuring keyboard layout?

**Quick Fix:**

1. Switch to text console: Press `Ctrl+Alt+F3` or `Ctrl+Alt+F4`
2. Log in with your username and password (terminal uses correct layout)
3. **Reset password** - Set it fresh while logged into the console:
   ```bash
   passwd yourusername
   ```
   **Important:** Type the password exactly as you want it to work in GDM. If GDM is using a different layout, you may need to mentally "translate" or use a password that works with both layouts.

4. **If password contains numbers:** Make sure Num Lock state matches between console and GDM

5. Switch back to graphical login: Press `Alt+F7` or `Alt+F1`
6. Log in with new password

**Alternative Solutions:**

1. **If GDM layout doesn't match config.scm:**
   - GDM may not be inheriting the system keyboard layout properly
   - Try resetting password from text console (which uses config.scm layout)
   - Type password as if GDM is using the default US QWERTY layout

2. **Test GDM layout directly:**
   - At GDM login screen, type test characters in password field
   - If "qwerty" produces different characters, GDM is using a different layout
   - You may need to mentally translate your password to match GDM's layout

3. **Check if password was set with wrong layout:**
   - If password was set during installation before keyboard config, it might have been set with ISO default layout
   - Reset password from console (which uses your config.scm layout) and type it as if GDM uses default US QWERTY

**Troubleshooting Autostart Script Not Working:**

**Important:** GNOME uses Wayland by default (not X11), so `setxkbmap` won't work. The autostart script uses `gsettings` instead.

If the autostart script exists but keyboard layout isn't being applied in GNOME:

1. **Check if autostart file exists:**
   ```bash
   ls -la ~/.config/autostart/keyboard-layout.desktop
   cat ~/.config/autostart/keyboard-layout.desktop
   ```

2. **Manually configure keyboard layout using gsettings (for Wayland/GNOME):**
   ```bash
   # Set keyboard options (e.g., ctrl:swapcaps)
   gsettings set org.gnome.desktop.input-sources xkb-options "['ctrl:swapcaps']"
   
   # Verify it was set
   gsettings get org.gnome.desktop.input-sources xkb-options
   ```
   Then test: Caps Lock should now act as Ctrl, Ctrl should act as Caps Lock

3. **If gsettings command works but autostart doesn't:**
   - The autostart script might be running before GNOME is fully initialized
   - Try adding it to your `~/.bashrc` or `~/.profile` as a workaround:
     ```bash
     gsettings set org.gnome.desktop.input-sources xkb-options "['ctrl:swapcaps']" 2>/dev/null || true
     ```

4. **Check GNOME Settings:**
   - Open Settings → Keyboard
   - Check if keyboard layout is set there (GNOME Settings might override autostart)

5. **Note about X11 vs Wayland:**
   - If you're using X11 (not Wayland), you can use `setxkbmap`:
     ```bash
     setxkbmap us -option ctrl:swapcaps
     ```
   - To check which you're using: `echo $XDG_SESSION_TYPE` (should show "wayland" or "x11")

**Permanent Fix:** The autostart script (`~/.config/autostart/keyboard-layout.desktop`) sets keyboard layout after login, but GDM needs it configured before login. For now, use a password that works with the default layout, or configure GDM keyboard layout manually via dconf (requires additional setup).

**Note:** Root/admin accounts: In Guix, you typically don't log in as root on the desktop. Users have `sudo` access. To set a root password: `sudo passwd root`

---

### Workflow 4: P2P Package Substitute Service (GIPS)

**Goal:** Declarative GIPS daemon (`gipsd`) on Guix System for peer-to-peer substitute downloads.

1. **Automated Setup with Config Helper:**
   ```bash
   guile lib/guile-config-helper.scm add-gips-service /etc/config.scm
   ```

2. **Manual Configuration in `/etc/config.scm`:**
   Add `(gips service)` to `use-modules`:
   ```scheme
   (use-modules (gnu)
                (gips service))  ; GIPS system service
   ```

   Add `(service gips-service-type)` to the `services` field:
   ```scheme
   (services
     (append
      (list (service gips-service-type
                     (gips-configuration
                      (gipsd-config
                       (gipsd-configuration
                        #:listen "127.0.0.1:8080"
                        #:db-path "/var/lib/gips/gipsd.sqlite")))))
      %base-services))
   ```

3. **Apply changes:**
   ```bash
   sudo guix system reconfigure /etc/config.scm
   ```

---

## Further Reading

- [Official Guix Manual](https://guix.gnu.org/manual/)
- [Guix System Configuration Examples](https://guix.gnu.org/cookbook/en/html_node/System-Configuration.html)
- [Nonguix Documentation](https://gitlab.com/nonguix/nonguix)
