# GIPS Multi-Machine Binary Sync Guide

Accelerate package installations and share build artifacts across your personal Guix devices (e.g., a home Docker host / Mac Mini and a remote Oracle Cloud instance) using **GNU Guix IPFS Package Substitutes (GIPS)**.

---

## The Problem GIPS Solves

Compiling large packages on a resource-constrained cloud machine (like Oracle's 1-core Always Free micro instance) is slow and risks running out of memory.

Traditional binary-sharing tools have friction:
- `guix publish` requires fixed public IPs, VPNs (like Tailscale), or router port-forwarding.
- `guix copy` is a manual SSH-based push.

**With GIPS:**
- Uses the global **IPFS libp2p swarm** for automatic NAT hole-punching and peer discovery across home firewalls and cloud data centers.
- Runs a local substitute HTTP proxy (`http://127.0.0.1:8080`) that `guix-daemon` queries transparently.
- When one of your machines builds or downloads a package, your other machines fetch that exact substitute binary directly via IPFS instead of compiling from source.

---

## Architecture Compatibility

Guix store paths are content-addressed and architecture-specific:
- **x86_64 machines** (e.g. Intel/AMD Docker host and Oracle `VM.Standard.E2.1.Micro`) share x86_64 binaries.
- **ARM64 machines** (e.g. Apple Silicon M-series Mac Mini running ARM64 Docker and Oracle `VM.Standard.A1.Flex` Ampere instances) share aarch64 binaries natively with zero emulation overhead.

---

## Step-by-Step Setup

### Step 1: Start IPFS & GIPS on Your Home Seeder (e.g. Mac Mini / Docker)

From the root of this repository on your home machine:

```bash
# 1. Start the IPFS (Kubo) container with swarm ports mapped
make ipfs-docker

# 2. Start the GIPS daemon
make gips-daemon
```

In a second terminal, export your public signing keys:

```bash
cd gips
cargo run -p gips -- key export-feed > ~/feed-signing.pub
cargo run -p gips -- key export-guix > ~/guix-signing.pub
```

- **`feed-signing.pub`**: Authorizes your feed updates over IPFS.
- **`guix-signing.pub`**: Authorizes your binary substitutes inside Guix's `/etc/guix/acl`.

---

### Step 2: Set Up GIPS on Your Oracle Cloud Instance

Connect to your Oracle instance:

```bash
make ssh
```

Run the automated GIPS post-install recipe on the instance:

```bash
wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/gips.scm | guile --no-auto-compile -s /dev/stdin
```

Or start the IPFS and GIPS daemon manually:
```bash
ipfs daemon &
gipsd &
```

---

### Step 3: Authorize Keys & Subscribe

1. **Authorize the seeder's Guix key** on the Oracle instance so `guix-daemon` trusts its binaries:
   ```bash
   sudo guix archive --authorize < guix-signing.pub
   ```

2. **Add the seeder's feed key to your `~/.config/gips/gipsd.toml`** under `[[trust.trusted_publishers]]`:
   ```toml
   [[trust.trusted_publishers]]
   gns_name = "home-builder.gnu"
   public_key = "/path/to/feed-signing.pub"
   ```

3. **Subscribe to the feed**:
   ```bash
   gips subscribe home-builder.gnu
   ```

---

### Step 4: Verify Connectivity & Accelerated Installs

Check that your nodes have discovered each other:

```bash
# On your local machine or Oracle instance:
make gips-status
```

Now, whenever you install packages on your Oracle instance, point Guix to your local GIPS proxy:

```bash
guix install <package> --substitute-urls="http://127.0.0.1:8080 https://ci.guix.gnu.org"
```

If the package was already built on your home machine, it downloads directly over IPFS in seconds!

---

## Convenience Makefile Targets

| Target | Description |
|---|---|
| `make ipfs-docker` | Starts a persistent `ipfs/kubo` container exposing swarm port `4001` and local API `5001`. |
| `make gips-daemon` | Starts the local GIPS daemon (`gipsd`) connected to IPFS. |
| `make gips-status` | Inspects daemon health, peer connections, and trusted subscriptions. |
| `make gips-test` | Runs the offline Scheme API & signing test suite. |
| `make gips-rust-test` | Runs all Rust unit and integration tests. |

For deep technical details and protocol invariants, see [`gips/docs/personal-sync-quickstart.md`](../gips/docs/personal-sync-quickstart.md) and [`gips/docs/architecture.md`](../gips/docs/architecture.md).
