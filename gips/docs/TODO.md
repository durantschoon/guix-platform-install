# GIPS TODOs and Roadmap

<!-- markdownlint-disable MD013 -->

This file summarizes the implementation plan from the GIPS architecture plan.

**Plan A** describes the first concrete version of GIPS: a minimal, usable
peer-to-peer substitute server (`gipsd` + `gips`) that can replace a
traditional Guix HTTP build farm. **Plans B and C** are intentionally kept
as extensions at the end of the file: they build on Plan A to add a
federated mirror/index network (Plan B) and an offline-first, capability-
oriented client and snapshot system (Plan C).

## Polylith and Scheme integration

- [x] Configure this repository in the style of Polylith (e.g. clear separation of components, bases, and development environment for Rust crates).
- [x] Create `docs/polylith_rust.md` to both:
  - Introduce users to our specific Polylith-style Rust setup.
  - Document learnings and gotchas when mixing Polylith principles with Rust crates and workspaces.
- [x] Include Guile Scheme integration so that core behaviors can be exercised and inspected from a REPL (e.g. driving `gipsd` configuration and basic operations via Scheme).

## Plan A – Minimal Viable GIPS Node & Publisher

- **Core daemon (`gipsd`)**
  - [x] Basic Axum HTTP server skeleton (`/publish`, `/narinfo`, `/nar`, `/status`).
  - [x] SQLite-backed mapping of store paths → IPFS CIDs, optional GNS names, narinfo metadata.
  - [x] IPFS integration over the HTTP API (`/api/v0/add`, pinned by default).
  - [x] GNS integration stub that shells out to `gnunet-gns` for record publication.
  - [x] Implement full Guix narinfo and nar serving semantics and wire `/narinfo` + `/nar` to IPFS content. (Real `NarHash`/`NarSize`, verify-while-streaming nar serving, Guix-native narinfo signatures — stages 16, 27, 29. `Deriver:`/`System:` fields are still omitted, which degrades `guix challenge`/`guix weather`.)
  - [x] Harden error handling, logging, and configuration validation. (Fail-closed trust and config, visible-by-default logging, input validation, timeouts and resource limits — stages 14–20.)

- **CLI (`gips`)**
  - [x] `publish <store-path> [--gns-name <name>]` → `POST /publish`.
  - [x] `status` → `GET /status`.
  - [x] Command stubs for `link-channel`, `pin`, `unpin` (print clear “not implemented” messages).
  - [x] Flesh out `link-channel`, `pin`, and `unpin` once daemon endpoints are defined. (Real CLI commands against authenticated endpoints; the Scheme REPL bindings are still stubs — see "Still open" below.)

- **Trust & signing**
  - [x] Data structures for signing configuration and trusted publishers (`gips-trust`).
  - [x] Implement narinfo signing and key loading in `gipsd`. (Ed25519 feed signing at publish — stage 15; Guix-native serve-time narinfo signing via `[guix_signing]` — stage 29.)
  - [x] Define how clients configure and verify trusted publishers (inspired by Guix keyrings). (`[trust]` config with fail-closed verification — stage 14; Guix-side ACL authorization ceremony — stages 29–30, `docs/personal-sync-quickstart.md`.)

- **Configuration (Rust + Guile Scheme)**
  - [x] TOML-based `GipsdConfig` (Rust) with `listen`, `db_path`, `ipfs_api`, `gns_command`, `guile_config`.
  - [x] Optional Guile Scheme config file: `guile -s <file>` prints TOML that overrides `GipsdConfig`.
  - [x] Define a stable Scheme config API (procedures, records) mirroring the Rust config fields. (`gipsd-configuration` in `scheme/gips/config.scm`, including `[trust]` and, since stage 30, `[guix_signing]` parity.)

## Testing user stories

- **Publisher stories**
  - *Story P1*: As a publisher, I can run `just daemon` and `just snapshot example.gnu /gnu/store/...-foo-1.0` so that the store path is added to IPFS, recorded in the DB, and resolvable via GNS.
  - *Story P2*: As a publisher, Guix configured with `substitute-urls` pointing at `gipsd` can fetch narinfos and nars for my published store paths without being aware of IPFS.

- **Mirror stories** (Plan B)
  - *Story M1*: As a mirror operator, I can subscribe to a publisher’s GNS name, mirror its feed into my node, and serve the same substitutes to my local Guix clients.
  - *Story M2*: As a mirror operator, if the publisher is unavailable, my node still serves previously mirrored substitutes to clients.

- **Search/index stories** (Plan B)
  - *Story I1*: As a user, I can run `gips search hello --system=x86_64-linux` and see which publishers/mirrors provide that substitute.

- **Offline snapshot stories** (Plan C)
  - *Story O1*: As an offline laptop user, I can create a named snapshot `workstation-2026-03` from a Scheme manifest on a connected machine, then copy/cache it so that I can install the same packages later without network access.
  - *Story O2*: As an offline laptop user, I can point Guix at a local `gipsd` backed only by snapshot CIDs and successfully install packages from that snapshot.

- **Guile config stories**
  - *Story S1*: As a Scheme user, I can maintain my `gipsd` configuration as a `.scm` file which, when run via `guile`, emits TOML that `gipsd` uses to override its Rust defaults.

- **Gossip / GNUnet alignment stories**
  - *Story G1*: As a GNUnet integrator, I can inspect the signed feed objects and gossip messages and map them cleanly onto a GNUnet transport without changing the feed/index formats.

## Scenario-based testing

- **P1 – Publish substitute via GIPS**
  - [x] Start `ipfs` daemon and ensure it is reachable at the configured `ipfs_api` URL.
  - [x] Start `gipsd` with a known `gipsd.toml` (or Scheme-generated TOML) pointing at a test SQLite DB.
  - [x] Run `just snapshot test.publisher.gnu /gnu/store/...-hello-2.12`.
  - [x] Verify the HTTP response contains a CID and that the `substitutes` table has a row for the store path.
  - [x] Use `ipfs pin ls` (or equivalent API) to confirm the CID is pinned.
  - [x] If GNS is available in the environment, verify that resolving `test.publisher.gnu` returns data referencing the published CID.

- **P2 – Guix substitute fetch via GIPS**
  - [x] Configure Guix `substitute-urls` to `http://127.0.0.1:8080` (or whatever `listen` is set to).
  - [x] Attempt to install a package whose store path has been published.
  - [x] Verify Guix fetches narinfos/nars via `gipsd` and the install completes.

- **M1 – Mirror subscription and serving**
  - [x] Start a publisher `gipsd` and publish a known store path.
  - [x] Start a mirror node configured to subscribe to the publisher’s GNS name.
  - [x] Trigger the mirror sync (e.g. `gips mirror add <publisher-gns>` once implemented).
  - [x] Verify the mirror pins the publisher’s CIDs and exposes them over its own HTTP substitute endpoint.

- **O1/O2 – Offline snapshot workflow**
  - [x] On a connected machine, create a Scheme manifest for a small profile.
  - [x] Use a `gips snapshot create` prototype (or manual steps) to compute the closure, fetch narinfos, and generate a snapshot manifest stored in IPFS.
  - [x] Export the snapshot (e.g. via `ipfs` or file copy) to an offline test machine.
  - [x] Start `gipsd` on the offline machine backed by the snapshot CIDs only.
  - [x] Configure Guix to use that local `gipsd` endpoint and verify installation from the snapshot works without external network.

- **S1 – Scheme-driven configuration**
  - [x] Write a minimal `gipsd.scm` that, when executed by `guile -s`, prints valid TOML setting a non-default `listen` port or DB path.
  - [x] Point `guile_config` in the base TOML at this file.
  - [x] Start `gipsd` and verify that the effective config reflects the Scheme overrides (e.g. listening on the new port).

- **G1 – Gossip proto compatibility**
  - [x] Capture some publisher feed and gossip messages on the wire.
  - [x] Validate that message types, signatures, and identities align with the conventions documented in `docs/federation.md`.
  - [x] Sketch or implement a proof-of-concept GNUnet transport that can carry the same messages unchanged.

## Plan B – Federated Mirror & Index Network

See `docs/federation.md` for the protocol sketch.

- [x] Describe a publisher feed model (signed IPLD feed in IPFS, root CID in GNS).
- [x] Describe mirror subscription behavior (walk feed DAG, pin referenced CIDs, maintain local index).
- [x] Describe an indexer role and on-disk schema (SQLite/FTS).
- [x] Specify that the initial gossip network uses a simple Rust/libp2p-style pubsub over IPFS topics.
- [x] Call out that message structure and identities should be GNUnet-aligned so the transport can be swapped later.
- [x] Implement a minimal publisher feed writer in `gipsd`.
- [x] Implement a mirror daemon that subscribes to a publisher and mirrors content.
- [x] Implement an indexer process and a `gips search` CLI that talks to it.

## Plan C – Capability-Oriented, Offline-First Client

See `docs/offline-snapshots.md` for the snapshot design.

- [x] Specify what a snapshot is: manifest of store paths + narinfo metadata + IPFS CIDs, stored in IPFS and optionally referenced from GNS.
- [x] Describe the preparation phase (compute closure from a Scheme manifest, fetch narinfos, write manifest, pin).
- [x] Describe offline use (local `gipsd` as substitute server backed by snapshot CIDs).
- [x] Describe capability-style sharing via GNS names for snapshots.
- [x] Add a `gips snapshot` subcommand family (create, list, export/import).
- [x] Implement snapshot manifests and integration with `gipsd`’s HTTP substitute interface.
- [x] Design Scheme-configurable snapshot profiles (inspired by Guix manifests).

## Still open (recorded 2026-08-18)

- [x] **Scheme REPL parity (invariant 1) restored**: Full parity in `scheme/gips/api.scm` with all CLI commands (`gips-subscribe`, `gips-link-channel`, `gips-pin`, `gips-unpin`, `gips-reindex`, `gips-search`, `gips-key-generate-guix`, `gips-key-export-guix`, `gips-key-generate-feed`, `gips-key-export-feed`, `gips-snapshot-create`). Shipped in Stage 33.
- [x] `just sync-push` cannot complete: `gips snapshot create` fails loudly as unimplemented (deliberately, until real closure/CID computation lands). **Done in stage 31**: `gips snapshot create <manifest> [--gns-name <name>]` computes the closure with `guix build -m` + `guix gc --requisites`, publishes it, and has the daemon create, pin and (optionally) GNS-publish the snapshot; `just sync-push` calls it. The guix invocations are exercised only through a test seam here — a Guix machine still has to confirm the flags.
- [x] Signing-key lifecycle: no rotation or revocation path; the serve-time signature cache is TTL-only (1 h) and is not invalidated if the key changes; no key distribution over GNS. **Fixed in Stage 35**: `GuixSigner` detects key file mtime changes and invalidates the cache on disk modifications or SIGHUP flush.
- [x] Served narinfos omit `Deriver:` and `System:` fields, degrading `guix challenge` / `guix weather`. **Fixed in Stage 34**: `substitutes` table stores optional `deriver` and `system`, plumbed through `/publish` CLI and Scheme API, and rendered in served narinfos.
- [x] The Scheme client passes the auth token on the `curl` argv, so it is visible in `ps` while a request is in flight. **Fixed in Stage 33**: `scheme/gips/api.scm` passes bearer tokens via private temporary `0600` curl config files (`curl -K`) unlinked immediately after request execution via `dynamic-wind`.
- [x] Auth-token rotation (`gips auth rotate`) and SIGHUP config reload wired to key-cache invalidation. **Shipped in Stage 35**: added `gips auth rotate` CLI and `(gips-auth-rotate)` Scheme procedure, plus SIGHUP reload in `gipsd`.
- [x] **Guix ACL Tooling (`/etc/guix/acl`)**: Native commands to inspect, check, authorize, revoke, and diff keys in the Guix daemon ACL (`gips key acl list|check|authorize|revoke|diff`), with Guile Scheme REPL parity (`gips-key-acl-*`) and full test suite in `test_api.scm` and `components/gips-trust/src/acl.rs`.

## Future Milestones

- **Sybil Resistance & Federated Trust (Stage 23 → progressive implementation starting Stage 39)**:
  - [x] **Attenuable Capability Delegation Tokens (`gips vouch mint`, `verify`, `inspect`) (Stage 39)**: Core UCAN/macaroon-style capability delegation tokens with store path prefixes, delegation depth, bounded stake score, and expiration attenuation. Cryptographic Ed25519 signing and unbroken chain validation (`components/gips-trust/src/vouch.rs`), public HTTP endpoint `POST /vouch/verify` (`components/gips-http`), CLI subcommands `gips vouch mint|verify|inspect` (`gips/src/main.rs`), and Guile Scheme REPL parity (`scheme/gips/api.scm`, `test_api.scm`).
  - [x] **Objective Cryptographic Fraud Proofs & Revocation Engine (`gips fraud-proof`) (Stage 40)**: Self-contained objective cryptographic fraud proofs (`HashMismatch` and `Equivocation`) with mathematical verification without external RPCs (`components/gips-trust/src/fraud.rs`), SQLite persistence and index in `fraud_proofs` with `is_publisher_revoked` (`components/gips-db`), daemon endpoints `POST /fraud-proof/submit` and `GET /fraud-proof/list` with substitute resolution guard (`components/gips-http`), CLI commands `gips fraud-proof generate|verify|submit|list` (`gips/src/main.rs`), and Guile Scheme REPL parity and test suite (`scheme/gips/api.scm`, `test_api.scm`).
  - [x] **Transitive Web-of-Trust Evaluation & Dynamic Substitute Resolution (`gips trust evaluate`, `gips vouch ingest`) (Stage 41)**: Transitive reputation scoring with delegation hop decay (`floor(parent_score * 0.85)`), fraud proof revocation severing, prefix filtering authorization, and chain validation (`components/gips-trust/src/evaluator.rs`), SQLite persistence and index in `vouch_chains` table with automated expiration pruning (`components/gips-db`), dynamic substitute and feed evaluation with HTTP endpoints `POST /trust/evaluate` and `POST /vouch/ingest` (`components/gips-http`), CLI subcommands `gips trust evaluate` and `gips vouch ingest` (`gips/src/main.rs`), and Guile Scheme REPL parity and test suite (`scheme/gips/api.scm`, `test_api.scm`).
  - [x] **Complete Offline Snapshot Lifecycle (`gips snapshot list`, `import`, `export`) (Stage 42)**: SQLite metadata persistence and schema for snapshots table (`components/gips-db`), HTTP daemon endpoints `GET /snapshot/list`, `POST /snapshot/import` (pins manifest and constituent NAR artifacts in IPFS, registers substitute mappings in SQLite), and `GET /snapshot/export/:cid` (tar archive packaging) (`components/gips-http`), CLI subcommands `gips snapshot list`, `gips snapshot import <cid>`, and `gips snapshot export <cid> [-o output.tar]` (`gips/src/main.rs`), and Guile Scheme REPL parity and test suite (`scheme/gips/api.scm`, `test_api.scm`).
  - [x] **Automated Gossip Propagation for Web-of-Trust Vouches and Fraud Proofs (`gips gossip`) (Stage 43)**: Automated pubsub broadcast and background gossip worker subscribing to `gips.vouch.v1` and `gips.fraud.v1` over IPFS PubSub (`components/gips-ipfs`), real-time ingestion, mathematical verification, database persistence, and key-cache invalidation (`components/gips-http`), `GET /gossip/status` daemon endpoint and `gips gossip status` CLI command (`gips/src/main.rs`), and Guile Scheme REPL procedure `(gips-gossip-status)` with test suite (`scheme/gips/api.scm`, `test_api.scm`).
  - [x] **Multi-Node E2E Integration Simulation Harness (`tests/e2e_federation.rs`) (Stage 44)**: Hermetic in-process multi-node simulation harness spinning up isolated `gipsd` daemons on ephemeral loopback ports (`127.0.0.1:0`), mock IPFS network with pubsub channels, and mock GNS namestore. End-to-end integration tests verifying multi-hop vouch delegation and substitute serving, objective fraud proof generation, pubsub gossip propagation, peer blacklisting, and air-gapped snapshot tarball export/import.
  - [x] **Pluggable Gossip Transport Abstraction (`GossipTransport`) (Stage 46)**: Clean async trait `GossipTransport` in `components/gips-ipfs/src/transport.rs` with `IpfsPubsubTransport`, `MemoryMeshTransport` (in-memory multi-peer broadcast fabric), and `GnunetCadetTransport` (CADET channel abstraction). Unified router subscription and broadcast in `components/gips-http`.
  - [x] **Live GNUnet CADET Transport Driver & Multi-Transport Aggregator (`CompositeGossipTransport`) (Stage 48)**: Live CADET message framing envelope (`CadetMessageEnvelope`), bidirectional mesh pipeline, and `CompositeGossipTransport` combining IPFS PubSub and GNUnet CADET channels concurrently with unified status reporting.
  - [x] **Privacy-Preserving Substitute Queries & Bloom Filter Summaries (Stage 49)**: $k$-anonymity store path prefix lookups (`GET /substitute/prefix/:prefix`, `gips search-prefix`), Bloom filter substitute set summaries (`components/gips-trust/src/bloom.rs`, `GET /substitute/filter`), and Guile Scheme REPL procedure `(gips-search-prefix)`.
  - [x] **Store Directory Direct UnixFS Ingestion (`gips publish-tree`) (Stage 50)**: Recursive UnixFS directory tree ingestion into IPFS (`POST /publish-tree`), on-the-fly streaming NAR synthesis, CLI subcommand `gips publish-tree <store-path>`, and Guile Scheme REPL procedure `(gips-publish-tree)`.
  - [x] **Guix System Service Definition (`(gips service)`) (Stage 51)**: Idiomatic GNU Guix System service module (`scheme/gips/service.scm`) declaring `<gips-configuration>`, Shepherd service specs (`gips-shepherd-service-spec`), activation permission hooks (`gips-activation-script`), and `gips-service-type` for `/etc/config.scm`.
  - [x] **Standalone GNU Guix Package (`(gips package)` & `gips.scm`) (Stage 52)**: Standalone GNU Guix package definition record (`scheme/gips/package.scm`), top-level `gips.scm` entrypoint for `guix build -f gips.scm`, `just package` recipe, and Scheme test harness validation.

## Telemetry and Benchmarking (Stage 24)

- [x] Instrument the serving path with fire-and-forget latency histograms (`components/gips-http/src/metrics.rs`): narinfo response time, IPFS nar fetch, local snapshot resolve, CID+NarHash verification, signature verification, GNS resolve, subscription manifest resolve, and SQLite reads.
- [x] Expose `GET /metrics` as JSON (schema `gips.metrics.v1`) behind the Stage 18 auth token, carrying no store paths, CIDs, GNS names, keys or tokens.
- [x] Serve a self-contained telemetry dashboard at `GET /dashboard` from `components/gips-dashboard/index.html`, compiled in with `include_str!` and locked to `default-src 'none'; connect-src 'self'` by CSP.
- [x] Add `scripts/benchmark-sync.sh` to time substitute lookups through GIPS against a central substitute server, emitting `gips.benchmark.v1` JSON the dashboard can load.
- [x] Export the mirror worker's metrics too — `start_mirror_worker` builds its own registry that nothing reads (kept separate so background passes do not distort the serving numbers). **Shipped in Stage 36**: exported in JSON under `mirror` and Prometheus under `gips_mirror_*`.
- [x] Persist a rolling latency history across restarts. Histograms are in-memory and cumulative since startup, so the dashboard's trend view resets when the daemon does. **Shipped in Stage 37**: SQLite `metrics_history` table with automated 7-day retention pruning, periodic snapshot task, and `GET /metrics/history` endpoint with CLI and Scheme API.
- [x] **Terminal Swarm Monitor (`gips monitor`) (Stage 47)**: Real-time terminal inspection of swarm peering, active topics, message event rates, and substitute latency histograms with `--once`, continuous `--watch`, structured `--json`, and Guile Scheme REPL procedure `(gips-monitor)`.
