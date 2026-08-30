<!-- markdownlint-disable MD013 -->

# GIPS User Guide

Welcome to **GIPS (GNS + IPFS Package Substitutes)**! This guide will walk you through setting up GIPS to publish and download Guix substitutes over a decentralized, peer-to-peer network.

## Prerequisites

Before starting, ensure you have the following installed:

1. **Guix**: The package manager itself.
2. **IPFS (Kubo)**: The underlying content-addressed P2P swarm.
3. **GNUnet (`gnunet-gns`)**: The GNU Name System used for resolving stable publisher names.

## For Guix Users (Downloading Substitutes)

Instead of downloading Guix packages from a centralized build farm like `ci.guix.gnu.org`, you will fetch substitutes from an IPFS swarm using GIPS as a local proxy.

### 1. Start the Background Daemons

You need both IPFS and the GIPS daemon running.

```bash
# In terminal 1: Start IPFS
ipfs daemon

# In terminal 2: Start GIPS daemon
cd /path/to/GIPS
just daemon
```

*Note: `gipsd` listens on `127.0.0.1:8080` by default.*

### 2. Subscribe to a Publisher

Subscribing has two halves, and doing only one is the most common reason a machine keeps building from source.

First, tell your local `gipsd` to subscribe to the publisher's GNS name:

```bash
just subscribe publisher.gnu
```

Second, tell it to *trust* that publisher, by naming its feed public key in `<config dir>/gipsd.toml`. Subscribing fetches; trusting decides whether to believe what was fetched — with an empty `trusted_publishers` list, GIPS accepts nothing from the network. Copy [`examples/gipsd-consumer.toml`](../examples/gipsd-consumer.toml) (a commented, test-parsed `[[trust.trusted_publishers]]` block with `allow_unsigned = false`) and edit the name and key path, then restart `gipsd`.

The publisher gets that key from `gips key generate-feed` and prints it with `gips key export-feed`.

**There are two different keys**, and this is the one Guix never sees: the *feed* key (Ed25519 PEM, `[trust]`, checked by your `gipsd`) and the *Guix* key (`[guix_signing]`, authorized into `/etc/guix/acl`, checked by your `guix-daemon`) — see step 3 below and the end-to-end [Personal Sync Quickstart](personal-sync-quickstart.md), which walks both machines through both keys.

### 3. Authorize the Publisher's Key

Before Guix will accept substitutes from GIPS, you MUST authorize the publisher's public key. The key must be explicitly added to Guix's ACL.

You can fetch the publisher's public key directly from their GNS domain:

```bash
gips key fetch-gns --name publisher.gnu | sudo guix archive --authorize
```

Or authorize a previously exported key file:

```bash
guix archive --authorize < publisher-key.pub
```

The publisher generates this key with `gips key generate-guix` and advertises it to GNS with `gips key advertise-gns --name publisher.gnu` (or prints it with `gips key export-guix`); it is a `guix publish`-format key, so an unmodified Guix accepts substitutes signed with it once it is in the ACL. This is *not* the feed key from step 2 — the two formats are not interconvertible, and each machine needs both to be set up. The publisher's `gipsd` must have a `[guix_signing]` block configured (see [`examples/gipsd-builder.toml`](../examples/gipsd-builder.toml), which shows both keys side by side) — the [Personal Sync Quickstart](personal-sync-quickstart.md) is the full builder-and-consumer walkthrough. Keep verification on: nothing in GIPS requires (or should ever require) `--no-check-signature`.

### 4. Tell Guix to use GIPS

When installing a package, instruct Guix to use your local GIPS daemon as its substitute server. `gipsd` will transparently resolve the publisher's manifest via GNS and stream the artifacts directly from the IPFS swarm.

```bash
just install <package>
```

*(You can also set the substitute URL globally in your `guix-daemon` configuration).*

---

## For Guix Publishers (Uploading Substitutes)

If you have built Guix packages locally and want to share them with the swarm:

### 1. Create and Publish a Snapshot

Use the Guile snapshot script to upload your built `.nar` files to IPFS and publish the resulting "Fat Manifest" to your GNS identity.

```bash
just snapshot my-identity.gnu /gnu/store/...-hello-2.12 /gnu/store/...-foo-1.0
```

This command will:

1. Pin the store paths to your local IPFS node.
2. Generate a JSON manifest mapping those paths to their CIDs.
3. Publish that manifest's CID to your GNS name using the custom `65536` record type.

*Note: As long as your IPFS daemon is running, other peers in the swarm will be able to download these substitutes from you.*

---

## Shipped Beyond the MVP

Features that started as roadmap items and now work:

* **Guix-native narinfo signing**: `gipsd` signs served narinfos with a `guix publish`-format key that an unmodified Guix verifies against its ACL (see "Authorize the Publisher's Key" above).
* **GNS key distribution & discovery**: publishers can advertise keys to GNS TXT records (`gips key advertise-gns`) and consumers can fetch and authorize them directly (`gips key fetch-gns`).
* **Fail-closed trust & integrity**: with an empty `trusted_publishers` list, GIPS accepts nothing from the network; content integrity is enforced end to end with real `NarHash` verification.
* **Federated Web of Trust & Capability Delegation**: UCAN-style delegation tokens (`gips vouch mint`, `verify`, `inspect`, `ingest`) allow transitive vouching with monotonic capability attenuation (depth, stake, prefixes, expiry).
* **Objective Cryptographic Fraud Proofs & Revocation**: objective, portable fraud proofs (`gips fraud-proof generate`, `verify`, `submit`, `list`) for `HashMismatch` and `Equivocation` mathematically slash and blacklist rogue publishers without central authorities.
* **Transitive WoT Evaluation**: `gips trust evaluate` dynamically calculates reputation scores across multi-hop delegation chains with stake decay and instant fraud proof severing.
* **Automated PubSub Gossip Propagation**: background gossip daemon broadcasts and ingests vouches over `gips.vouch.v1` and fraud proofs over `gips.fraud.v1` (`gips gossip status`).
* **Live Swarm & Node Monitor**: terminal monitoring dashboard (`gips monitor [--once] [--watch] [--json]`) for real-time peering, message throughput, and substitute latency.
* **Privacy-Preserving Substitute Queries**: $k$-anonymity store path prefix queries (`gips search-prefix <prefix>`) and compact Bloom filter substitute summaries (`/substitute/filter`).
* **Direct UnixFS Directory Publishing**: native support for publishing `/gnu/store/` directory trees to IPFS directly as UnixFS DAG hierarchies (`gips publish-tree`) with on-the-fly streaming NAR synthesis.
* **Complete Offline Snapshot Lifecycle (Plan C)**: `gips snapshot create` (from Guix manifests), `gips snapshot list`, `gips snapshot import` (by CID), and `gips snapshot export` (streaming `.tar` bundles for air-gapped transport).
* **Key lifecycle & auth rotation**: signing key file mtime detection invalidates signature caches; auth token rotation via `gips auth rotate` and SIGHUP reload in `gipsd`.
* **Federated mirrors (Plan B)**: nodes subscribe to a publisher's GNS name (`just subscribe`), mirror its feed, and seed the substitutes onward.
* **Decentralized indexing (Plan B)**: `gips search` queries a local SQLite FTS index of known publishers.
* **`link-channel`, `pin`, `unpin`**: real CLI commands backed by authenticated daemon endpoints.
* **Guix System Service Definition**: declarative `(gips service)` module providing `<gips-configuration>` and `gips-service-type` for Shepherd daemon management in `/etc/config.scm`.
* **Standalone GNU Guix Package (`gips.scm`)**: declarative `(gips package)` module and root `gips.scm` entrypoint for building via `guix build -f gips.scm` or `guix shell -f gips.scm`.

## Upcoming Features & Roadmap

* **Capability-oriented sharing (Plan C)**: unguessable GNS subdomains to privately share specific subsets of substitutes.

---

## General Usage (Beyond Guix)

While GIPS is tailored for resolving and downloading Guix substitutes via its `gipsd` proxy, the underlying architectural pattern is fully generic.

Any user can use a GNS identity as a distributed front-end to an IPFS Kubo back-end. You can publish static websites, file archives, or arbitrary datasets to IPFS and link their root CIDs to a GNS name. Other users can then resolve the latest CIDs via GNUnet and fetch the raw data directly over IPFS.
