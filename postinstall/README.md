# Shared Post-Installation Recipes

Common customization recipes that work across all platforms (cloudzy, framework, framework-dual).

## What Are Recipes?

Recipes are modular, reusable bash scripts that add specific features to your Guix system. They're designed to be:

- **Platform-agnostic**: Work on VPS, laptop, single-boot, dual-boot
- **Standalone**: Can be run individually or from customize tools
- **Safe**: Backup config before making changes
- **Idempotent**: Safe to run multiple times

## Available Recipes

### recipes/add/personal-config.scm — start here

The first postinstall step: turn a machine that merely boots into your machine.
It installs `git`, sets up an SSH key and pauses while you register it, clones
your own configuration repository, and runs whatever that repository declares.

Unlike every other recipe here, it needs nothing already on the machine:

```sh
wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
  | guile --no-auto-compile -s /dev/stdin
```

A fresh Guix System has `wget`, `guile` and `nss-certs` but no `git`, `curl`,
`gnu-make` or OpenSSH client — so the entry point assumes only the first three
and provisions the rest. The pipe is safe because every prompt reads `/dev/tty`.

What it runs is declared by a `guix-personal.scm` file at the root of *your*
repository, not by anything in this one:

```scheme
(personal-config
  (version 1)
  (requires "git" "gnu-make" "zsh")
  (steps
    (step (name "home") (run "make apply")
          (description "guix home reconfigure") (default? #t))
    (step (name "keyd") (run "make setup-keyd")
          (description "Physical machines only"))))
```

Full specification: [../docs/PERSONAL_CONFIG_CONTRACT.md](../docs/PERSONAL_CONFIG_CONTRACT.md)

Other entry points, all offline and side-effect free:

```sh
--validate FILE   parse and check a contract
--plan DIR        show what an already-cloned repository would run
--init [DIR]      write a starter contract from what a repository contains
--self-test       check the pure helpers
```

Also reachable as option `p` in `cloudzy/postinstall/customize.scm`, and
documented for Oracle first boot in [../oracle/postinstall/README.md](../oracle/postinstall/README.md).

---

### add-spacemacs.sh

Installs Spacemacs, a community-driven Emacs distribution.

**What it does:**
- Adds Emacs package to config.scm
- Clones Spacemacs from GitHub
- Creates basic .spacemacs configuration
- Backs up existing .emacs.d if present

**Usage:**
```bash
# From customize tool
./customize  # then press 's'

# Standalone
./postinstall/recipes/add-spacemacs.sh
```

**Features:**
- Vim editing style (default)
- Common layers: helm, git, markdown, org, etc.
- Spacemacs dark theme
- Leader key: SPC

---

### add-development.sh

Installs common development tools and programming languages.

**What it adds:**
- git, vim, emacs
- make, gcc-toolchain
- python, node, go
- curl, wget
- ripgrep, fd
- tmux, htop

**Usage:**
```bash
# From customize tool
./customize  # then press 'd'

# Standalone
./postinstall/recipes/add-development.sh
```

---

### add-fonts.sh

Installs programming and general-purpose fonts.

**What it adds:**
- Fira Code (programming font with ligatures)
- JetBrains Mono (programming font)
- DejaVu (good Unicode coverage)
- Liberation (MS-compatible)
- GNU FreeFont
- Font Awesome (icons)
- Google Noto (comprehensive Unicode)

**Usage:**
```bash
# From customize tool
./customize  # then press 'f'

# Standalone
./postinstall/recipes/add-fonts.sh
```

**After installation:**
```bash
# Rebuild font cache
fc-cache -f -v
```

---

## How Recipes Work

### Directory Structure

```
postinstall/
└── recipes/
    ├── add-spacemacs.sh
    ├── add-development.sh
    ├── add-fonts.sh
    └── (more recipes...)
```

### Integration with Customize Tools

All platform customize tools source shared recipes:

```bash
# cloudzy/postinstall/customize
# framework/postinstall/customize
# framework-dual/postinstall/customize

case "$choice" in
  s) source "../../postinstall/recipes/add-spacemacs.sh" && add_spacemacs ;;
  d) source "../../postinstall/recipes/add-development.sh" && add_development ;;
  f) source "../../postinstall/recipes/add-fonts.sh" && add_fonts ;;
  # ...
esac
```

### Recipe Template

```bash
#!/usr/bin/env bash
# Shared recipe: Description
# Can be called from any platform's customize tool

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/config.scm}"

# Colors
info() { printf "  %s\n" "$*"; }
success() { printf "\n\033[1;32m[✓]\033[0m %s\n" "$*"; }

add_your_feature() {
  echo ""
  echo "=== Installing Your Feature ==="
  echo ""

  # Your implementation here
  # Modify $CONFIG_FILE as needed

  success "Feature installed!"
  info "Apply changes with: sudo guix system reconfigure /etc/config.scm"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  add_your_feature
fi
```

---

## Creating New Recipes

1. **Create the script:**
   ```bash
   touch postinstall/recipes/add-yourfeature.sh
   chmod +x postinstall/recipes/add-yourfeature.sh
   ```

2. **Follow the template** above

3. **Test standalone:**
   ```bash
   ./postinstall/recipes/add-yourfeature.sh
   ```

4. **Add to customize tools:**
   Edit `cloudzy/postinstall/customize`, `framework/postinstall/customize`, `framework-dual/postinstall/customize`:

   ```bash
   # In main_menu():
   echo "  y) Add your feature"

   # In case statement:
   y) source "../../postinstall/recipes/add-yourfeature.sh" && add_yourfeature; read -p "Press Enter..." ;;
   ```

5. **Document it** in this README

---

## Benefits of Shared Recipes

✅ **Write once, use everywhere**
- Same Spacemacs recipe works on VPS, Framework 13, any platform

✅ **Consistent experience**
- All users get the same Spacemacs setup, development tools, fonts

✅ **Easy to maintain**
- Fix bugs in one place
- Update all platforms at once

✅ **Discoverable**
- Users can browse recipes/ directory
- Visible in all customize tool menus

✅ **Extensible**
- Community can contribute new recipes
- Platform-specific tools can still exist alongside shared ones

---

## Platform-Specific vs Shared

**Use shared recipes for:**
- Development tools (git, vim, languages)
- Editors (Spacemacs, Neovim configs)
- Fonts
- Common packages
- General utilities

**Use platform-specific tools for:**
- SSH (critical for VPS, optional for laptop)
- Desktop environments (not needed on VPS)
- Hardware firmware (Framework WiFi, specific to laptop)
- Power management (laptop-specific)
- Dual-boot configuration (framework-dual only)

---

## Examples

### Install Spacemacs on Framework 13 laptop

```bash
cd framework/postinstall
./customize
# Press 4 to add WiFi firmware first
# Press 2 to add desktop (GNOME)
# Press s to install Spacemacs
# Press r to reconfigure
# Launch emacs to complete Spacemacs setup
```

### Install dev tools on VPS

```bash
cd cloudzy/postinstall
./customize
# Press 1 to add SSH (critical!)
# Press d to install development tools
# Press r to reconfigure
```

### Install fonts on dual-boot system

```bash
cd framework-dual/postinstall
./customize
# Press 4 to add WiFi firmware
# Press 2 to add desktop
# Press f to install fonts
# Press r to reconfigure
# Run: fc-cache -f -v
```

---

## See Also

- Platform-specific customization tools:
  - `cloudzy/postinstall/customize` - VPS/server focus
  - `framework/postinstall/customize` - Laptop single-boot
  - `framework-dual/postinstall/customize` - Laptop dual-boot
- Main customization guide: `CUSTOMIZATION.md`
- Repository structure: `../STRUCTURE.md`
