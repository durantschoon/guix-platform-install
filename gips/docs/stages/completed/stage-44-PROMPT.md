# Stage 44 — Multi-Node E2E Integration Simulation Harness (`tests/e2e_federation.rs`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In `docs/TODO.md` lines 71–108, scenario-based testing stories are defined for publishers (P1, P2), mirrors (M1, M2), search/indexers (I1), offline capability snapshots (O1, O2), and gossip/federation (G1).

While previous stages implemented and verified unit and component-level behavior, we need a unified, hermetic multi-node end-to-end simulation harness in pure Rust. This harness boots multiple concurrent `gipsd` nodes on ephemeral loopback ports (`127.0.0.1:0`), backed by temporary databases and mock IPFS/GNS services, and validates the entire distributed protocol end-to-end.

## The Change

1. **`tests/e2e_federation.rs` (New Multi-Node Test Suite)**:
   - Implement `TestNode` test harness:
     - Creates isolated temp directory for SQLite database, private auth tokens, and key pairs.
     - Generates Ed25519 feed keys and Guix libgcrypt signing keys.
     - Mounts mock IPFS storage (`/api/v0/add`, `/api/v0/cat`, `/api/v0/pin/add`, `/api/v0/pubsub/*`).
     - Starts `axum` router on `127.0.0.1:0` (ephemeral TCP port).
     - Provides helper methods: `publish_substitute`, `mint_vouch_chain`, `ingest_vouch_chain`, `export_snapshot_tar`, `import_snapshot_tar`, `submit_fraud_proof`, and `fetch_substitute`.
   - Implement the following comprehensive end-to-end integration scenarios:
     1. **Scenario 1: Multi-Hop Vouch Delegation & Dynamic Substitute Serving**:
        - Node A (Root Authority) mints vouch token for Node B with path prefix `/gnu/store/` and depth 2.
        - Node B mints child vouch token for Node C (Leaf Publisher) with depth 1.
        - Node C publishes substitute `/gnu/store/aaa-hello-1.0` with real NarHash.
        - Node D (Consumer node configured with Node A as trusted root) ingests vouch chain `[A -> B -> C]`.
        - Node D evaluates trust score for Node C (decayed score >= 50).
        - Node D fetches `/narinfo` and `/nar` for `/gnu/store/aaa-hello-1.0` and verifies content integrity.
     2. **Scenario 2: Objective Fraud Proof Generation, Gossip, & Instant Peer Blacklisting**:
        - Rogue Node X publishes a tampered substitute with forged NarHash.
        - Consumer Node D detects `HashMismatch` fraud and generates an objective `FraudProof`.
        - Node D submits `FraudProof` to its daemon (`POST /fraud-proof/submit`).
        - Node D's daemon records the proof in SQLite, immediately blacklists Node X, and broadcasts to `gips.fraud.v1`.
        - Node E receives the gossiped fraud proof, verifies it mathematically, and blacklists Node X.
        - Subsequent substitute requests to Node D and Node E for Node X's packages return 404 / untrusted.
     3. **Scenario 3: Offline Air-Gapped Snapshot Export & Import**:
        - Node C creates a snapshot `data-science-2026` containing multiple store paths.
        - Node C exports `.tar` snapshot via `GET /snapshot/export/:cid`.
        - Isolated Node F imports the `.tar` snapshot via `POST /snapshot/import`.
        - Node F successfully serves `/narinfo` and `/nar` for all snapshot store paths without network access.

2. **Docs**:
   - Update `docs/TODO.md` marking Scenario-based testing stories verified.

## Allowed Files Whitelist

- `tests/e2e_federation.rs`
- `Cargo.toml` (root, if dev-dependencies are added)
- `Cargo.lock`
- `docs/TODO.md`

## Enumerated Tests

1. **`scenario_multi_hop_vouch_and_substitute_serving`**: Full multi-hop delegation chain validation and substitute fetching across independent nodes.
2. **`scenario_fraud_proof_generation_and_peer_revocation`**: End-to-end detection of hash tampering, fraud proof generation, submission, and multi-node peer blacklisting.
3. **`scenario_offline_snapshot_export_and_import`**: Full snapshot creation, `.tar` archive streaming export, isolated node import, and offline substitute serving.

## Definition of Done

- `cargo test --test e2e_federation` passes 100% green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-44] test: multi-node e2e integration simulation harness (tests/e2e_federation.rs)`
