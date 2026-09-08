# GIPS Multi-Machine Binary Sync Guide

Accelerate package installations and share build artifacts across your personal Guix devices (e.g., between two Oracle Cloud instances, or between a home Docker host and a remote VPS) using **GNU Guix IPFS Package Substitutes (GIPS)**.

---

## The Problem GIPS Solves

Compiling large packages on a resource-constrained machine (like Oracle's 1-core Always Free micro instance) is slow and risks running out of memory.

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
- **x86_64 machines** (e.g. Oracle `VM.Standard.E2.1.Micro`, Framework laptops, x86_64 VPS) share x86_64 binaries.
- **ARM64 machines** (e.g. Apple Silicon Macs, Oracle `VM.Standard.A1.Flex` Ampere instances, Raspberry Pi) share aarch64 binaries natively.

---

## Step-by-Step Setup

### Step 1: Install GIPS Tooling on Both Machines

> [!NOTE]
> **IPFS Package Name in GNU Guix:**
> In GNU Guix, the IPFS (Kubo) package is named **`go-ipfs`** (`gnu/packages/ipfs.scm`). Running `guix install ipfs` will fail with `unknown package`.

To install all GIPS build, runtime, and cryptographic dependencies in one shot (`go-ipfs`, `rust`, `cargo`, `pkg-config`, `openssl`, `sqlite`, `guile-gcrypt`, `just`, `curl`, `jq`), run on each machine:

```bash
# From repository root:
make gips-bundle
# Or directly via Guix:
guix package -m gips/manifest.scm
```

---

### Step 2: Initialize the Hub (Node 1 - Builder / Producer)

On your primary build machine:

```bash
make gips-hub
```

This single command:
1. Generates private/public narinfo signing keys (mode `0600`) and configures `~/.config/gips/gipsd.toml`.
2. Starts `ipfs daemon` and `gipsd` in the background with logging to `~/.config/gips/`.
3. Displays the Hub's public key with instructions for connecting any Spoke node.

---

### Step 3: Connect Spoke Nodes (Node 2, 3, etc. - Consumers)

On each consumer machine:

```bash
make gips-spoke
```

When prompted:
1. Paste the Hub's signing public key (from Step 2).
2. The script automatically authorizes the key in Guix's `/etc/guix/acl` via `sudo guix archive --authorize`.
3. Configures `gipsd.toml` for consumer mode and starts `ipfs daemon` and `gipsd` in the background.

*(For automated scripts, you can also pass `make gips-spoke HUB_KEY='(public-key ...)'` or `make gips-spoke HUB_KEY_FILE=hub.pub` without interactive prompts).*

---

### Step 4: Share and Substitute Packages

- **On Machine 1 (Producer)**:
  Publish your current profile snapshot to IPFS:
  ```bash
  make gips-push GNS_NAME=cluster.gnu
  ```

- **On Machine 2 (Consumer)**:
  Install packages using your local GIPS proxy:
  ```bash
  guix install <package> --substitute-urls="http://127.0.0.1:8080 https://ci.guix.gnu.org"
  ```
  Or pull an entire manifest:
  ```bash
  make gips-pull MANIFEST=sync-manifest.scm
  ```

Substitutes will be downloaded peer-to-peer over the IPFS swarm in seconds without compiling from source!

---

## Convenience Makefile Targets

| Target | Description |
|---|---|
| `make gips-bundle` | Installs complete GIPS tooling bundle (`go-ipfs`, `rust`, `guile-gcrypt`, etc.) via `gips/manifest.scm`. |
| `make gips-hub` | Initializes this node as the Hub (builder): sets up keys, starts daemons, and outputs Spoke connection info. |
| `make gips-spoke` | Connects this node as a Spoke (consumer): authorizes Hub key in `/etc/guix/acl` and starts daemons. |
| `make gips-setup` | Runs the post-install recipe: creates secure config dir, generates keys (`0600`/`0700`), and writes default config. |
| `make gips-start` | Starts `ipfs daemon` and `gipsd` in the background with logging to `~/.config/gips/`. |
| `make gips-stop` | Stops background `gipsd` and `ipfs daemon` processes cleanly. |
| `make gips-status` | Inspects IPFS swarm connections, daemon health, metrics, and Guix ACL state. |
| `make gips-push` | Exports active Guix profile to a manifest and creates a GIPS snapshot on IPFS. |
| `make gips-pull` | Installs packages substituting from local GIPS proxy (`http://127.0.0.1:8080`). |
| `make gips-daemon` | Starts the local GIPS daemon (`gipsd`) in the foreground. |
| `make ipfs-docker` | Starts a persistent `ipfs/kubo` container (for non-Guix Docker hosts). |
| `make gips-test` | Runs the offline Scheme API & signing test suite. |
| `make gips-rust-test` | Runs all Rust workspace unit and integration tests. |
| `make gips-check` | Runs both Scheme and Rust test suites verifying parity. |

For deep technical details and protocol invariants, see [`gips/docs/personal-sync-quickstart.md`](../gips/docs/personal-sync-quickstart.md) and [`gips/docs/architecture.md`](../gips/docs/architecture.md).

