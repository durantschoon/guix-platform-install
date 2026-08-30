# Stage 43 — Automated Gossip Propagation for WoT & Fraud Proofs (`gips.vouch.v1`, `gips.fraud.v1`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In Plan B federation and Stages 39–41, GIPS established cryptographic vouch chains (Stage 39), objective fraud proofs (Stage 40), and transitive web-of-trust scoring (Stage 41). However, new vouches and fraud proofs currently rely on local HTTP ingestion (`POST /vouch/ingest`, `POST /fraud-proof/submit`).

In a decentralized substitute network, nodes must automatically announce and receive:

1. **Delegation Vouches** over pubsub topic `gips.vouch.v1`: so that when a cell vouches for a new publisher, peering mirrors and indexers learn of the vouch chain without manual coordination.
2. **Objective Fraud Proofs** over pubsub topic `gips.fraud.v1`: so that when one peer mathematically detects an invalid NarHash or equivocation, the fraud proof instantly propagates across the network to sever trust and slash rogue publishers.

## The Change

1. **`components/gips-ipfs` (PubSub API Support)**:
   - Implement `pubsub_pub(&self, topic: &str, data: &[u8]) -> Result<()>` calling IPFS `/api/v0/pubsub/pub?arg=<topic>` via `reqwest` multipart/raw body.
   - Implement `pubsub_sub(&self, topic: &str) -> Result<reqwest::Response>` to stream newline-delimited JSON pubsub messages from `/api/v0/pubsub/sub?arg=<topic>`.
   - Add unit tests with stubbed IPFS responses.

2. **`components/gips-http` (Gossip Broadcast & Ingestion Worker)**:
   - **Broadcast on Ingest**:
     - In `vouch_ingest` handler: after recording a valid vouch chain, asynchronously broadcast the JSON payload to topic `gips.vouch.v1`.
     - In `fraud_proof_submit` handler: after verifying and recording a valid fraud proof, asynchronously broadcast the JSON payload to topic `gips.fraud.v1`.
   - **Background Gossip Subscriber**:
     - Implement `start_gossip_worker(state: Arc<AppState>)`:
       - Subscribes to `gips.vouch.v1`: parses incoming `Vec<VouchToken>`, verifies chain linkage and capabilities; if valid and meets `min_trust_score`, records into SQLite `vouch_chains`.
       - Subscribes to `gips.fraud.v1`: parses incoming `FraudProof`, verifies mathematical proof with `verify_fraud_proof`; if valid, records into SQLite `fraud_proofs` and invalidates caches.
   - Add endpoint `GET /gossip/status` returning active pubsub topics and message counters.

3. **`gips` CLI (`gips/src/main.rs`)**:
   - Add `gips gossip status` command to display current gossip subscription status and statistics.

4. **`scheme/gips/api.scm` & `test_api.scm` (Invariant 1 Parity)**:
   - Export and implement `(gips-gossip-status)`.
   - Add unit tests in `test_api.scm`.

5. **Docs**:
   - Update `docs/TODO.md`, `docs/federation.md`, and `docs/trust-economics.md`.

## Allowed Files Whitelist

- `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gipsd/src/main.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`
- `docs/federation.md`
- `docs/trust-economics.md`

## Enumerated Tests

1. **IPFS PubSub Publishing**: `pubsub_pub` correctly formats request to `/api/v0/pubsub/pub`.
2. **Vouch Gossip Propagation**: Incoming message on `gips.vouch.v1` with valid vouch chain is automatically verified and stored in `vouch_chains`. Tampered chain is discarded without error.
3. **Fraud Proof Gossip Propagation**: Incoming message on `gips.fraud.v1` with valid fraud proof is mathematically verified, stored in `fraud_proofs`, and immediately revokes the target publisher.
4. **CLI & Scheme Parity**: `gips gossip status` and `(gips-gossip-status)` return identical status representations.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` and federation docs updated.

## Commit Message

`[stage-43] feat: automated gossip propagation for web-of-trust vouches and fraud proofs (gips gossip)`
