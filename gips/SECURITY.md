<!-- markdownlint-disable MD013 -->
# Security and Threat Model

This document outlines the security assumptions, threat model, and capabilities of GIPS.

## Threat Model

GIPS operates in a decentralized, peer-to-peer context. We assume the following adversaries:

- **Malicious Publisher**: A publisher attempting to serve tampered substitutes, exhaust mirror storage, or lie about dependencies.
- **Hostile IPFS Node / Gateway**: An IPFS peer returning garbage or malicious data for a requested CID.
- **GNS Zone Compromise**: An attacker who takes over or spoofs a GNS identity.
- **Network Attacker**: An adversary intercepting or modifying traffic between a client and a mirror, or between a mirror and IPFS/GNS.
- **Local Unprivileged Process**: An attacker on the same machine attempting to read sensitive configuration or disrupt `gipsd`.

## What GIPS Protects Against

As of the current hardening stages, GIPS provides the following protections:

- **Data Integrity**: All data retrieved from IPFS is strictly verified against its cryptographic CID and computed `NarHash` before serving. A hostile IPFS peer cannot serve modified bytes without failing the hash check.
- **Input Validation**: All store paths, GNS names, and hash parameters are validated against strict character and length constraints.
- **SQL Injection**: Database queries use parameterized statements (`sqlx`) to prevent SQL injection.
- **Subprocess Hardening**: Subprocesses (e.g., `gnunet-gns`, `guile`) are invoked with strict timeouts, separated arguments (using `--`), and restricted execution times.
- **Path Traversal / Local Storage**: `gipsd` validates paths and does not blindly resolve configuration or DB paths relative to the current working directory.
- **Resource Exhaustion & DoS Limits**: Ingestion of feeds and IPFS data bounds chunk sizes, NAR payload ceilings, and subprocess runtimes to prevent OOMs or infinite fan-out.
- **Fail-Closed Trust**: Default configuration refuses all unsigned substitutes and rejects unauthenticated mutations.
- **Web-of-Trust & Capability Attenuation (Stages 39, 41)**: UCAN/macaroon-style delegation tokens (`VouchToken`) enforce monotonic capability attenuation (decreasing depth, non-increasing stake, bounded validity, and narrow path prefixes) with 15% stake decay per delegation hop.
- **Objective Mathematical Revocations (Stage 40)**: Cryptographic fraud proofs (`HashMismatch` and `Equivocation`) allow immediate, autonomous, zero-external-RPC peer revocation and downstream trust severing without central coordinators.
- **Authenticated Gossip Propagation (Stage 43)**: Pubsub gossip streams (`gips.vouch.v1`, `gips.fraud.v1`) cryptographically validate all incoming delegation tokens and fraud proofs prior to SQLite persistence and key-cache invalidation.
- **Guix ACL Tooling**: Built-in commands (`gips key acl list|check|authorize|revoke|diff`) to inspect, check, authorize, revoke, and diff keys directly against `/etc/guix/acl`.

## Known Limitations & What GIPS Does NOT Protect Against Yet

GIPS is an evolving project. Note the following design constraints and current boundaries:

- **Guix Keyring Integration & Key Lifecycle**: Serving-side signing, GNS key advertising/discovery, SIGHUP/mtime cache invalidation, and `/etc/guix/acl` inspection/management are implemented. Multi-key retroactive substitute re-signing (retroactively signing previously published substitutes when a node key rotates) remains out of scope.
- **Privacy Leakage**: Your HTTP requests (`/publish`, `/search`, `/nar`) are visible to the peer node you communicate with and disclose package requests to that node.
- **Sybil Resistance via Financial Staking**: While transitive trust decay and bounded delegation stake contain blast radius, full economic slashable bonds and on-chain deposit pools remain optional higher-layer extensions (see [docs/trust-economics.md](docs/trust-economics.md)).
- **Store-Path Ownership is First-Writer-Wins**: `substitutes` has no `UNIQUE(store_path)` constraint across distinct publishers, and `process_feed` deduplicates without checking the original publisher. The first subscription to advertise a valid path owns it locally.
- **Pipeline Trust Boundary**: The pipeline itself is a trust boundary. Stage prompts and changes arriving over decentralized remotes must be audited prior to running merge verification gates.

## Reporting a Vulnerability

If you discover a security issue, please do **not** open a public issue. Instead, contact the maintainers privately via the project's designated security contact (TBD). Include a detailed description of the vulnerability and steps to reproduce.
