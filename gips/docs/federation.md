# GIPS Federated Gossip & Indexing (Plan B Skeleton)

This document sketches the metadata feed and gossip protocol with the aim
of being simple today and compatible with a future migration to GNUnet.

- **Publisher feed**: each publisher maintains an append-only feed of
  signed updates (channel snapshots, narinfos) encoded as IPLD objects
  in IPFS. A GNS record points at the root CID of this feed DAG.
- **Mirror subscription**: mirrors resolve a publisher's GNS name to the
  feed root, walk the DAG to discover unseen updates, and pin referenced
  substitute CIDs locally.
- **Gossip network**: initially implemented as a lightweight Rust service
  using libp2p-style pubsub over IPFS topics where each publisher topic
  announces new feed heads. Message formats and keys are chosen to mirror
  GNUnet conventions where reasonable (clear separation of identities,
  signatures on messages, versioned message types).
- **Indexer role**: indexer nodes ingest feeds from many publishers and
  build a local search index for `gips search`. The on-disk index is a
  simple SQLite/FTS database keyed by (name, version, system, hash),
  with metadata about which publishers and mirrors advertise each CID.

Over time, the pubsub transport can be swapped for GNUnet messaging
while preserving the signed feed objects and indexer schema.

## Trust and Membership

GIPS relies on a federated web of trust to contain the blast radius of malicious actors. See [Federated Trust Economics](trust-economics.md) for the full design.

To support this model, the Gossip Network and Daemon handle delegation chains and fraud proofs:

- **Vouch records (Delegation Chains)**: A cryptographic assertion (an attenuable capability, e.g., UCAN/macaroon-style) signed by a Local Cell or a larger group, staking a bounded portion of their reputation on a specific publisher's public key. Mirrors and Indexers ingest these Vouch records (`POST /vouch/ingest` or gossip) and persist them in SQLite (`vouch_chains` table).
- **Transitive Substitute Resolution**: When resolving substitute manifests or ingesting channel feeds signed by a non-root publisher key:
  1. The node queries `get_vouch_chains_for_subject` for the publisher's public key.
  2. The `TrustEvaluator` verifies the chain linkage against configured root anchors (`config.trust.trusted_publishers`).
  3. The evaluator applies a 15% stake score decay per delegation hop (`floor(parent_score * 0.85)`).
  4. The evaluator verifies that neither the publisher nor any upstream voucher is listed in the active fraud proof revocation database (`fraud_proofs`).
  5. The evaluator verifies that the requested store path is authorized under the chain's attenuated `path_prefixes`.
  6. If `effective_score >= min_trust_score` (default 50) and signature verification succeeds, the substitute or feed update is accepted. Otherwise, it is rejected before caching or pinning.
- **Objective Fraud Proofs & Revocations**: Cryptographic mismatch and equivocation proofs (`POST /fraud-proof/submit`) propagate across peers to instantly sever malicious publishers and their downstream delegates from the web of trust without subjective voting or central coordinators.
- **Automated Gossip Propagation (`gips.vouch.v1`, `gips.fraud.v1`)**:
  - Validated vouches ingested via `POST /vouch/ingest` are automatically broadcast to topic `gips.vouch.v1`.
  - Cryptographic fraud proofs submitted via `POST /fraud-proof/submit` are automatically broadcast to topic `gips.fraud.v1`.
  - The background gossip worker in `gipsd` subscribes to both topics, continuously streaming and validating incoming gossip envelopes.
  - Valid chains and fraud proofs are automatically committed to the local SQLite database and immediately invalidate key and signature caches.
  - Gossip subscription status and counters are observable via `GET /gossip/status`, the CLI (`gips gossip status`), and Guile Scheme (`(gips-gossip-status)`).
