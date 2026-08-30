# Federated Trust Economics: Sybil Resistance & Blast Radius Containment

<!-- markdownlint-disable MD013 -->

The Guix IPFS Peer-to-Peer Substitute (GIPS) network utilizes a progressive, federated trust model. Because there is no central authority to ban malicious actors, the network separates *cost of identity* (Sybil resistance) from *grounds for removal* (integrity).

## 1. Core Principles

- **Cost of Identity (Sybil Resistance)**: Implemented via membership fees, slashable bonds, or delegation (invitations). This stops cheap identity flooding.
- **Grounds for Removal (Integrity)**: Enforcement MUST ride on evidence, never subjective accusation. A removal requires an objective, cryptographically-provable fraud proof (e.g., a signed narinfo whose delivered bytes don't match the signed `NarHash`, or equivocation where two conflicting feeds are signed at one version).

## 2. The Federated Membership Model

GIPS operates on a model of **local accountability, global amplification**:

1. **Local Vouching via Delegation**: Small groups vouch for their own members using an attenuable-capability delegation chain (macaroon/UCAN/GNUnet-style) rooted in signed GNS identities. A member's acceptance by a distant peer is transitive through this graph.
2. **Larger Groups as Shared-Defense Services**: A larger group is not a gatekeeper. For a small fee, a sub-group gains infrastructure: faster revocation/fraud-proof propagation, access to a shared insurance pool/bond, and a broader trust anchor.
3. **Bounded, Decaying Vouching Stake**: Vouching for someone risks a small, decaying amount of the voucher's reputation or a refundable bond. This stake is slashed *only* on a proven fraud proof against the vouchee. Repeated bad vouches compound, but one bad member cannot destroy an honest group.
4. **Optional Economic Sybil-Cost**: A slashable bond provides identity-cost without funding a central banning operator. Paid-membership operators run as just *one group among many*, never the single root.

## 3. Non-Negotiable Censorship-Resistant Properties

- **No Single Root**: Multiple overlapping federations coexist.
- **Cheap Exit**: Leaving a group does not orphan already-published, valid content.
- **No Collective Capital Punishment**: Penalties are bounded and evidence-gated.
- **Evidence Over Fiat**: Fraud proofs must be portable, independently-verifiable, and explicitly stripped of client-identifying metadata (IPs, timing) to protect the requester's privacy.

## 4. Implemented Trust Architecture (Stages 39–41)

GIPS implements the complete decentralized Web-of-Trust and Sybil-containment stack:

1. **Attenuable Capability Delegation Tokens (`components/gips-trust/src/vouch.rs`)**:
   - UCAN/macaroon-style delegation tokens signed with Ed25519 feed keys.
   - Enforces strict monotonic attenuation across delegation chains:
     - Delegation depth decreases by at least 1 per hop (`child.max_depth < parent.max_depth`).
     - Stake score cannot inflate (`child.stake_score <= parent.stake_score`).
     - Lifetime cannot exceed parent expiration (`child.expires_at <= parent.expires_at`).
     - Path prefixes cannot widen (`child.path_prefixes` must be subsets or subpaths of parent prefixes).
   - CLI commands: `gips vouch mint`, `gips vouch verify`, `gips vouch inspect`, `gips vouch ingest`.

2. **Objective Cryptographic Fraud Proofs (`components/gips-trust/src/fraud.rs`)**:
   - `HashMismatch`: Mathematically proves that an Ed25519 signature over a canonical narinfo committed to a `NarHash` that contradicts actual delivered artifact bytes.
   - `Equivocation`: Mathematically proves that a publisher signed two distinct, conflicting feed entries for the same store path and timestamp.
   - Zero-external-RPC verification.
   - CLI commands: `gips fraud-proof generate`, `gips fraud-proof verify`, `gips fraud-proof submit`, `gips fraud-proof list`.

3. **Transitive Web-of-Trust Evaluation Engine (`components/gips-trust/src/evaluator.rs`)**:
   - Evaluates a publisher's effective reputation score relative to trusted root anchors and active revocations.
   - **Decaying Stake Scoring**: Reputation decays by 15% per delegation hop:
     $$\text{hop\_score} = \min(\text{token.stake\_score}, \lfloor \text{parent\_score} \times 0.85 \rfloor)$$
     Direct root publishers evaluate to score 100. 1-hop delegates evaluate to at most 85. 2-hop delegates evaluate to at most 72.
   - **Fraud Proof Revocation Severing**: If the publisher or any intermediary voucher along the delegation chain has an active fraud proof in the database, the effective score immediately drops to 0, severing trust across the entire downstream subtree.
   - **Prefix Scope Authorization**: If a store path does not match the token's allowed path prefixes, trust evaluation fails (`trusted: false`, `reason: "Store path ... not authorized by prefix capabilities"`).
   - **Threshold Enforcement**: A substitute or feed entry is accepted only if `score >= 50` (or configured `min_trust_score`) and signature is cryptographically valid.

4. **Persistence & REST APIs**:
   - SQLite tables: `fraud_proofs` and `vouch_chains` in `components/gips-db`.
   - Automated expiration pruning: `prune_expired_vouches` discards expired chains.
   - Daemon endpoints:
     - `POST /trust/evaluate`: Evaluates trust score and authorization for a publisher and optional store path.
     - `POST /vouch/ingest`: Ingests and stores a verified delegation chain into the local database (authenticated).
     - `POST /fraud-proof/submit` & `GET /fraud-proof/list`: Ingests and lists cryptographic revocations.
   - Full Scheme REPL parity: `(gips-trust-evaluate ...)`, `(gips-vouch-ingest ...)`, `(gips-fraud-proof-...)`.

5. **Automated Gossip Propagation for Vouches & Fraud Proofs (Stage 43)**:
   - **PubSub Broadcasting**: When a peer node ingests a valid delegation chain (`POST /vouch/ingest`) or receives an objective fraud proof (`POST /fraud-proof/submit`), the daemon automatically broadcasts the payload to dedicated IPFS PubSub topics:
     - `gips.vouch.v1`: Gossip stream for attenuable capability delegation chains.
     - `gips.fraud.v1`: Gossip stream for objective mathematical fraud proofs.
   - **Autonomous Background Worker**: Each running daemon subscribes to `gips.vouch.v1` and `gips.fraud.v1`. Incoming messages are:
     - Decoded from base64 IPFS pubsub JSON envelopes.
     - Cryptographically and mathematically validated without external RPCs.
     - Evaluated against local trust anchors and existing revocations.
     - Committed to the SQLite database (`vouch_chains` and `fraud_proofs`).
     - Triggering immediate key-cache and signature-cache invalidation.
   - **Inspection & Telemetry**:
     - `GET /gossip/status` exposes active pubsub topic subscriptions and atomic message counters (received, accepted, rejected).
     - CLI command: `gips gossip status`.
     - Scheme procedure: `(gips-gossip-status)`.
