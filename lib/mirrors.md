# Mirror Configuration for Guix Installations

This repository automatically optimizes download speeds by selecting the best mirrors based on your geographic region.

## How It Works

The installation scripts automatically detect your region and configure:
- **Git repository URLs** (for `guix pull`)
- **Substitute servers** (for binary downloads)
- **Channel configurations** (for post-boot customization)

## Supported Regions

### Asia / China
**Region codes:** `asia`, `china`, `cn`

**Mirrors used:**
- Git: `https://mirror.sjtu.edu.cn/git/guix.git` (Shanghai Jiao Tong University)
- Substitutes:
  - `https://mirror.sjtu.edu.cn/guix`
  - `https://mirrors.tuna.tsinghua.edu.cn/guix` (Tsinghua University)
  - `https://ci.guix.gnu.org` (fallback)
  - `https://bordeaux.guix.gnu.org` (fallback)

### Europe
**Region codes:** `europe`, `eu`

**Mirrors used:**
- Git: `https://git.savannah.gnu.org/git/guix.git` (official)
- Substitutes:
  - `https://bordeaux.guix.gnu.org` (primary)
  - `https://ci.guix.gnu.org` (fallback)

### Americas
**Region codes:** `americas`, `us`, `na`

**Mirrors used:**
- Git: `https://git.savannah.gnu.org/git/guix.git` (official)
- Substitutes:
  - `https://ci.guix.gnu.org` (primary)
  - `https://bordeaux.guix.gnu.org` (fallback)

### Global (Default)
**Region code:** `global`

Uses official Guix mirrors worldwide.

---

## Manual Region Selection

Set the region before installation:

```bash
export GUIX_REGION="asia"
./run-remote-steps.sh
```

Or set during customization:

```bash
export GUIX_REGION="europe"
./customize
```

---

## Custom Mirror Configuration

### Override Individual URLs

```bash
# Use a custom Guix Git mirror
export GUIX_GIT_URL="https://your-mirror.example.com/guix.git"

# Use a custom Nonguix mirror
export NONGUIX_GIT_URL="https://your-mirror.example.com/nonguix.git"

# Use custom substitute servers
export SUBSTITUTE_URLS="https://your-mirror.example.com/substitutes https://ci.guix.gnu.org"
```

### Override All Mirrors

```bash
export GUIX_REGION="custom"
export GUIX_GIT_URL="https://mirror1.example.com/guix.git"
export NONGUIX_GIT_URL="https://mirror2.example.com/nonguix.git"
export SUBSTITUTE_URLS="https://mirror1.example.com/substitutes https://mirror2.example.com/substitutes"

./run-remote-steps.sh
```

---

## Auto-Detection

If you don't set `GUIX_REGION`, the scripts will auto-detect based on your timezone:

| Timezone Pattern | Detected Region |
|-----------------|-----------------|
| `Asia/Shanghai`, `Asia/Hong_Kong`, etc. | `asia` |
| `Europe/*`, `Africa/*` | `europe` |
| `America/*`, `US/*` | `americas` |
| Other | `global` |

---

## Known Mirrors

### Chinese Mirrors

**Shanghai Jiao Tong University (SJTU)**
- Git: `https://mirror.sjtu.edu.cn/git/guix.git`
- Substitutes: `https://mirror.sjtu.edu.cn/guix`
- Documentation: https://mirror.sjtu.edu.cn/

**Tsinghua University (TUNA)**
- Substitutes: `https://mirrors.tuna.tsinghua.edu.cn/guix`
- Documentation: https://mirrors.tuna.tsinghua.edu.cn/

### Official Mirrors

**GNU Savannah**
- Git: `https://git.savannah.gnu.org/git/guix.git`
- Official Guix repository

**CI Server**
- Substitutes: `https://ci.guix.gnu.org`
- Primary binary cache

**Bordeaux Build Farm**
- Substitutes: `https://bordeaux.guix.gnu.org`
- European build farm

### Nonguix

**GitLab**
- Git: `https://gitlab.com/nonguix/nonguix.git`
- Primary Nonguix repository (no mirrors known)

---

## Adding New Mirrors

To add a new mirror to the configuration:

1. Edit `lib/mirrors.sh`

2. Add your region/mirror in the `get_mirrors()` function:

   ```bash
   your_region)
     echo "Detected region: Your Region - using your mirrors"
     GUIX_GIT_URL="${GUIX_GIT_URL:-https://your-mirror.com/guix.git}"
     NONGUIX_GIT_URL="${NONGUIX_GIT_URL:-https://gitlab.com/nonguix/nonguix.git}"
     SUBSTITUTE_URLS=(
       "https://your-mirror.com/substitutes"
       "https://ci.guix.gnu.org"
     )
     ;;
   ```

3. Submit a pull request!

---

## Troubleshooting

### Mirror is slow or unreachable

Override with a different region:

```bash
export GUIX_REGION="global"
./run-remote-steps.sh
```

### Wrong region detected

Manually specify your region:

```bash
export GUIX_REGION="asia"
./run-remote-steps.sh
```

### Want to see which mirrors are being used

```bash
# Source the mirror configuration
source lib/mirrors.sh

# Get mirrors for your region
get_mirrors

# Show configuration
show_mirror_info
```

---

## Performance Tips

1. **Use regional mirrors** when available (especially in Asia/China)
2. **Test mirror speed** before installation if unsure
3. **Use substitute servers** to avoid building from source
4. **Set GUIX_REGION** explicitly for consistent behavior

---

## Peer-to-Peer Substitutes: GIPS (IPFS Swarm)

In addition to traditional centralized HTTP substitute mirrors (`ci.guix.gnu.org`, `bordeaux.guix.gnu.org`), this repository supports **GIPS (GNU Guix IPFS Package Substitutes)**.

GIPS distributes substitute binaries over a local IPFS swarm with GNS addressing, transitive web-of-trust capability delegation, and offline snapshot distribution.

### When to use GIPS
- **Personal multi-machine synchronization:** Share binaries built on your desktop/laptop directly with your cloud VPS (Oracle / Cloudzy) over IPFS without maintaining public build farms or VPNs.
- **Resilience:** Fall back to peer-to-peer substitute mirrors during upstream build farm outages or rate limits.
- **Offline & reproducible environments:** Distribute frozen snapshot manifests (.tar bundles or CIDs) across nodes.

### Enabling GIPS Substitutes
Run the post-install recipe:
```bash
guile -s postinstall/recipes/add/gips.scm
```
Then configure your `guix-daemon` to include `http://127.0.0.1:8080`:
```bash
guix-daemon --substitute-urls="http://127.0.0.1:8080 https://ci.guix.gnu.org"
```

---

## References

- [Guix Substitute Servers](https://guix.gnu.org/manual/en/html_node/Substitutes.html)
- [Guix Channels](https://guix.gnu.org/manual/en/html_node/Channels.html)
- [Nonguix Channel](https://gitlab.com/nonguix/nonguix)
- [SJTU Mirror Help](https://mirror.sjtu.edu.cn/)
- [TUNA Mirror Help](https://mirrors.tuna.tsinghua.edu.cn/)
- [GIPS Documentation](file:///Users/durant/Repos/ds/guix-platform-install/gips/README.md)
