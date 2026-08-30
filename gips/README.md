# GIPS

<!-- markdownlint-disable MD013 -->

**GIPS (GNS + IPFS Package Substitutes)** provides a peer-to-peer alternative to traditional Guix substitute servers. It replaces centralized HTTP build farms with an IPFS swarm, using GNS to provide stable, human-readable, and distributed pointers to shifting package hashes.

> [!NOTE]
> **Early Use Case: Personal Multi-Machine Sync**
> Before opening up to a fully public, adversarial network, the initial intended use case for GIPS is **personal synchronization**. You can run GIPS to seamlessly sync your own built packages between your desktop, laptop, and home server natively over the IPFS swarm—without needing to configure VPNs, open router ports, or maintain static IPs.
>
> 👉 **[See the Personal Sync Quickstart](docs/personal-sync-quickstart.md)**

## Swarm Distribution & Reproducible Environments (Offline Snapshots)

GIPS provides a native way to freeze an entire package environment and distribute it over IPFS for perfect reproducibility.

A **Snapshot Manifest** is a JSON file stored in IPFS that bundles a specific set of package CIDs (for example, a standardized data science environment, a company-wide developer toolchain, or a **reproducible science experiment**). It acts exactly like a torrent file for an entire operating system.

When you share this snapshot CID (or a GNS name pointing to it), two amazing things happen:

1. **Perfect Reproducibility (Science/Research):** Every single person gets the exact same bytes for every package. There is zero risk of "it works on my machine" drift. A researcher can publish a snapshot CID in their paper, and peer reviewers can download the exact environment natively.
2. **Peer-to-Peer Swarming:** Because this runs over IPFS, as soon as the first few people import the snapshot, they automatically start seeding it to the rest of the group. The more people who want that same group of packages, the faster and more resilient the downloads become, completely offloading the central publisher!

For more details on how to generate and use these, see [Offline Snapshots](docs/offline-snapshots.md).

## Quickstart: Sharing your packages

1. Generate an environment:

   ```bash
   guix shell -D -f guix.scm
   ```

2. Ensure your IPFS and GIPS daemons are running:

   ```bash
   ipfs daemon &
   just daemon &
   ```

3. Publish everything! For example, to publish every package currently in your user profile to your GNU Name System identity:

   ```bash
   just snapshot your-name.gnu $(guix gc --references ~/.guix-profile)
   ```

Your packages are now pinned to your local IPFS node, and a manifest is published to GNS. Anyone can now subscribe to `your-name.gnu` and download your substitutes directly from the swarm.

See the [User Guide](docs/user_guide.md) for full instructions on setting up subscriptions and downloading substitutes.

## Repository layout

The codebase is organized in a **Polylith-style** structure:

- **`bases/`** – Shared foundations with no workspace-internal dependencies.
  - `gips-config` – Daemon configuration types (`GipsdConfig`), defaults, and TOML loading.
- **`components/`** – Reusable libraries that depend on bases and/or other components.
  - `gips-ipfs` – IPFS HTTP API client (add, cat, pin, pubsub).
  - `gips-gns` – GNS client (record publishing and resolution).
  - `gips-trust` – Trust configuration, narinfo signing/verification (Ed25519 feed keys and Guix-native libgcrypt signing via Guile), capability delegation tokens (`VouchToken`), objective fraud proofs, and transitive Web-of-Trust evaluator.
  - `gips-nar` – Nar serialization and Guix-format `NarHash` computation.
  - `gips-db` – SQLite database for substitutes, FTS5 search index, vouch chains, fraud proofs, snapshots, and metrics history.
  - `gips-scheme-config` – Guile Scheme config merge (TOML overrides).
  - `gips-http` – Axum router and HTTP handlers (`/publish`, `/narinfo`, `/nar`, `/search`, `/metrics`, `/dashboard`, `/status`, `/vouch/*`, `/fraud-proof/*`, `/snapshot/*`, `/trust/*`, `/gossip/*`).
  - `gips-dashboard` – Self-contained telemetry dashboard served at `/dashboard`.
- **Top-level apps** – Deployable binaries.
  - `gipsd` – Daemon: loads config, connects DB, builds router, serves HTTP, runs background mirror & gossip workers.
  - `gips` – CLI client for interacting with `gipsd`.
- **`scheme/`** – Guile module `(gips api)` with full REPL parity for the `gips` CLI across all command families. See [scheme/README.md](scheme/README.md).

For diagrams of how these pieces fit together and how requests flow through the system, see [docs/architecture.md](docs/architecture.md).

## What exists today

The repository contains a fully working, peer-to-peer substitute network:

- **Daemon (`gipsd`)**
  - Binds an HTTP listener (via Axum/Tokio) and exposes substitute publishing, serving, search, telemetry, delegation verification, fraud proof submission, and offline snapshot distribution.
  - On nar retrieval, serves bit-for-bit verified streaming NAR archives backed by IPFS.
  - Automatically runs background mirror synchronization and pubsub gossip workers over IPFS topics `gips.vouch.v1` and `gips.fraud.v1`.
  - Enforces fail-closed security, private `0600` secret storage, token authorization on mutating endpoints, and zeroizing in-memory keys.

- **CLI (`gips`)**
  - Comprehensive command families:
    - `publish <store-path> [--gns-name <name>]` – publishes store path to IPFS and local DB.
    - `publish-tree <store-path> [--gns-name <name>]` – ingests store directory tree directly as a UnixFS DAG.
    - `status` – health check and daemon status.
    - `search <query> [--system <sys>]` – FTS5 search across local and indexed substitutes.
    - `search-prefix <hash-prefix>` – privacy-preserving $k$-anonymity substitute query.
    - `metrics` & `metrics history` – live histograms and 7-day latency trends.
    - `key` – `generate-guix`, `export-guix`, `generate-feed`, `export-feed`, `advertise-gns`, `fetch-gns`, `acl` (`list`, `check`, `authorize`, `revoke`, `diff`).
    - `snapshot` – `create`, `list`, `import`, `export` (streaming `.tar` bundles).
    - `vouch` – `mint`, `verify`, `inspect`, `ingest` for capability delegation chains.
    - `fraud-proof` – `generate`, `verify`, `submit`, `list` for objective cryptographic fraud proofs.
    - `trust evaluate` – transitive web-of-trust scoring with reputation decay.
    - `gossip status` – pubsub peering and propagation statistics.
    - `monitor [--once] [--watch] [--json]` – live terminal swarm monitor for peering health, message event rates, and latency histograms.

- **Configuration**
  - `gipsd` loads a Rust `GipsdConfig` structure with sane defaults (listen address, database path under the user’s configuration directory, IPFS API endpoint, GNS command).
  - The configuration can be **augmented by Guile Scheme**:
    - A `guile_config` field in `GipsdConfig` points to a Scheme file.
    - When present, the Scheme script is executed and expected to print a TOML document to stdout.
    - Only the keys present in that TOML are merged into the existing config; unspecified fields keep their Rust defaults.
    - If the Scheme script fails, times out, or prints malformed TOML, `gipsd` refuses to start (fail-closed) rather than silently falling back to defaults.

- **Storage & indexing**
  - Uses SQLite (via `sqlx`) as an embedded database for substitute metadata.
  - Ensures the parent directory for the database file is created before connecting.
  - Tracks relationships between:
    - Guix store paths.
    - IPFS content identifiers (CIDs) for substitute archives.
    - JSON metadata needed by the HTTP interface.

- **IPFS client**
  - Wraps the IPFS HTTP API using `reqwest`:
    - `add_path(path)`:
      - Reads file contents asynchronously and uploads them using the `/api/v0/add` endpoint with `multipart/form-data`.
      - Correctly parses newline-delimited JSON responses and returns the root CID.
    - `cat(cid)`:
      - Uses the `/api/v0/cat` endpoint and relies on `reqwest`’s `query` method, ensuring the CID is properly URL-encoded.

- **GNS integration**
  - Provides a small `GnsClient` abstraction that shells out to a configurable command (e.g. `gnunet-gns`) to publish records.
  - Returns structured errors when the external command fails, allowing the HTTP layer to report accurate status codes to clients.

Overall, GIPS already behaves as a **publish-and-serve substitute node**: you can run a daemon, publish a Guix store artifact into IPFS (with optional GNS publication), persist the mapping in SQLite, and query basic health and content paths through the CLI and HTTP API. On top of that minimal path, the daemon is hardened: trust is fail-closed (an empty `trusted_publishers` list accepts nothing), every mutating endpoint requires a local auth token, nar content is verified against its real `NarHash` while streaming, and served narinfos can be signed with a Guix-native key an unmodified `guix` accepts. See [SECURITY.md](SECURITY.md) for the threat model and current limits.

## Further documentation

- [docs/user_guide.md](docs/user_guide.md) – getting started guide for users and publishers, including upcoming features.
- [docs/glossary.md](docs/glossary.md) – comprehensive GNS & IPFS glossary, system architecture walkthrough, and design rationale.
- [docs/TODO.md](docs/TODO.md) – central roadmap for Plan A (current daemon + CLI), plus future Plans B and C and their testing stories.
- [docs/architecture.md](docs/architecture.md) – detailed architecture and request-flow diagrams for the current implementation.
- [docs/polylith_rust.md](docs/polylith_rust.md) – Polylith-style Rust layout (bases, components, apps), dependency rules, and learnings/gotchas.
- [docs/jargon.md](docs/jargon.md) – glossary of concepts (nar, narinfo, CID, GNS, substitute, etc.) for newcomers.
- [docs/invariant.md](docs/invariant.md) – invariants to check before each commit (CLI ↔ Scheme REPL parity, doc updates).
- [scheme/README.md](scheme/README.md) – Scheme API for REPL parity with the gips CLI.
- [docs/federation.md](docs/federation.md) – design notes for the planned federated mirror and index network (Plan B).
- [docs/offline-snapshots.md](docs/offline-snapshots.md) – design notes for the planned capability-oriented, offline-first client and snapshot system (Plan C).
