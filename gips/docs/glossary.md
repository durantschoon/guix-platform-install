# GIPS Glossary & Architecture Overview

<!-- markdownlint-disable MD013 -->

This document provides a comprehensive glossary for the GNU Name System (GNS) and InterPlanetary File System (IPFS) terms relevant to GIPS, followed by a high-level walkthrough of how the system works and the rationale behind its architectural decisions.

---

## 1. GNU Name System (GNS) Glossary

In GIPS, **GNS** provides decentralized, sovereign Public Key Infrastructure (PKI) and dynamic name resolution. It eliminates dependencies on centralized DNS root servers, domain registrars, TLS Certificate Authorities, and static IP addresses.

* **GNS Zone (Ego / Identity):**
  A sovereign cryptographic namespace controlled entirely by a private key pair (typically Ed25519 or ECDSA). In GNUnet, each user or service can generate multiple "egos" (zones). There is no central registry; owning the private key defines ownership of the zone.
* **GNS Name / Label:**
  A human-readable identifier within a zone (e.g., `alice.guix` or `hydra.build`). In GIPS, a GNS name serves as a persistent, user-friendly identifier for a package publisher or mirror channel.
* **GNS Record:**
  A cryptographically signed entry published to the decentralized GNUnet DHT/Namecache. In GIPS, this record stores the current IPFS **Content Identifier (CID)** of the publisher’s feed head.
* **Publisher Binding:**
  The strict cryptographic enforcement linking a substitute's signing key with its GNS identity. GIPS validates that the publisher name claimed in a signature line strictly matches the expected GNS origin, preventing cross-identity substitute injection attacks.
* **Dynamic Tip Resolution:**
  The mechanism by which consumers discover updates. When a publisher builds new packages, it updates its GNS record to point to the newest Merkle feed root CID on IPFS. Consumers periodically resolve the unchanging GNS name to track the newest tip.

---

## 2. InterPlanetary File System (IPFS) Glossary

In GIPS, **IPFS** acts as the immutable, content-addressed storage engine and peer-to-peer transport layer. It replaces centralized binary caches (like `ci.guix.gnu.org` and `bordeaux.guix.gnu.org`).

* **CID (Content Identifier):**
  A self-describing cryptographic multihash (e.g., CIDv0 starting with `Qm...` or CIDv1 starting with `bafy...`) that uniquely identifies an immutable block of data. Any change to the underlying bytes changes the CID.
* **NAR (Nix/Guix Archive):**
  The deterministic archive serialization format used by GNU Guix to serialize store items (regular files, directories, symlinks, permissions, and timestamps) into a reproducible byte stream.
* **Artifact CID (`artifact_cid`):**
  The IPFS CID that references the raw NAR archive bytes of a package build output.
* **NARINFO (`.narinfo`):**
  The metadata format required by the Guix substitute client. It specifies the store path, NAR hash, file size, references, dependencies, and digital signature.
* **Verify-While-Streaming (`NarHash` gate):**
  The serve-time integrity check: as nar bytes stream from IPFS to the client, `gipsd` hashes them against the signed `NarHash` and withholds the final chunk until the hash matches, so a tampered nar is never delivered complete. This protects consumers against compromised IPFS gateways or poisoned Bitswap peers. (An older whole-buffer helper, `verify_bytes_against_cid`, still exists in `gips-ipfs` but is no longer on the serving path — it is unsound for multi-block DAGs, as documented on the function.)
* **IPFS Swarm / Bitswap:**
  The peer-to-peer mesh protocol where nodes discover each other and exchange content blocks directly, avoiding the need for public IP addresses, port forwarding, or VPNs.
* **Pinning (`pin_add` / `pin_rm`):**
  Persisting a CID in the local IPFS node's blockstore so that it is never pruned by garbage collection and remains available to seed across the swarm.
* **Merkle DAG Feed (`PreviousCid`):**
  An append-only chain where each new feed update references the CID of the preceding update. This structure creates an immutable, verifiable causal history for each publisher.

---

## 3. High-Level System Architecture: How It Works

GIPS runs locally as a lightweight daemon (`gipsd`) that exposes a standard HTTP substitute server interface to the local GNU Guix daemon (via `--substitute-urls="http://127.0.0.1:8080"`).

### 1. Substitute Discovery (`GET /<hash>.narinfo`)

When Guix evaluates dependencies during package installation:

1. Guix queries `gipsd` for `/<hash>.narinfo`.
2. `gipsd` checks its local SQLite database (`substitutes` table) for an existing cached entry.
3. If not cached locally, `gipsd` looks up subscribed GNS publisher feeds, fetches the latest manifest feed from IPFS, verifies the cryptographic signature, extracts the `.narinfo`, and returns it to Guix.

### 2. Package Binary Download (`GET /nar/<hash>` or `/nar/<cid>`)

When Guix decides to download a pre-built binary substitute:

1. Guix requests the binary archive URL specified in the `.narinfo`.
2. `gipsd` resolves the corresponding `artifact_cid` and downloads the content blocks from the IPFS swarm via `ipfs.cat(cid)`.
3. `gipsd` re-hashes the downloaded bytes to verify they match the requested CID.
4. The verified byte stream is served directly to Guix, which unpacks the NAR archive into `/gnu/store`.

### 3. Package Publishing (`POST /publish`)

When a builder machine wants to share build outputs:

1. The builder invokes `gips publish <store-path> --gns-name=<name>`.
2. `gipsd` ingests the NAR archive into IPFS, obtaining an `artifact_cid`.
3. `gipsd` creates a signed manifest entry containing the store path, artifact CID, Unix timestamp, and `previous_cid`.
4. The signed feed entry is stored in IPFS, and the GNS record for the publisher is updated to point to this new feed root CID.

---

## 4. Design Rationale: Why Things Are Done This Way

### Why Pair GNS with IPFS?

* **Immutable Content Needs Dynamic Pointers:** IPFS is purely content-addressed and immutable; publishing a new package or updating a feed produces an entirely new CID. Without a naming layer, users would have to manually exchange new CIDs for every build. GNS provides a secure, decentralized pointer that can be updated dynamically while maintaining a persistent name.
* **Decentralized PKI vs. Centralized DNS/CA:** Traditional HTTP caches rely on domain names, DNS registrars, and Certificate Authorities—all of which introduce centralized points of failure, censorship vectors, and administrative overhead. GNS ties names directly to cryptographic keypairs without any central gatekeeper.

### Why Fail-Closed Trust?

* **Zero-Trust Defaults:** By default, GIPS rejects any unsigned, unverified, or mismatched substitute metadata. An explicit configuration flag (`allow_unsigned = true`) is required if unsigned content is ever permitted (e.g., during testing).
* **Strict Signature Binding:** The signature in a manifest covers both the store path and the artifact CID. This prevents bait-and-switch attacks where signed metadata is paired with malicious or swapped binary payloads.

### Why Merkle DAG Chains (`PreviousCid`) & Causal Consistency?

* **Clock Drift and Packet Reordering:** Relying solely on wall-clock timestamps for replication fails across decentralized networks where nodes have drifting clocks or network packets arrive out of order.
* **Causal Rollback Protection:** By explicitly referencing `previous_cid` in every feed entry, mirror nodes can walk backwards through the Merkle DAG, fetch missing causal ancestors, and apply updates in strict causal order without dropping intermediate package releases.
