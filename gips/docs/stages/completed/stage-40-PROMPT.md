# Stage 40 — Objective Cryptographic Fraud Proofs & Revocation Engine (`gips fraud-proof`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In a federated peer-to-peer substitute network with attenuable capability delegations (Stage 39), bad actors who cheat or equivocate must be held accountable. As specified in `docs/trust-economics.md`, grounds for removal must ride on **objective, cryptographically provable evidence**, never subjective accusation, to prevent censorship and false flagging.

Stage 40 implements objective fraud proofs for the two primary substitute fraud modes:

1. **`HashMismatch`**: A publisher signs a narinfo asserting a specific `NarHash`, but the delivered bytes do not hash to that value.
2. **`Equivocation`**: A publisher signs two conflicting feed heads (different CIDs for the same store path and timestamp/version).

Fraud proofs must be self-contained, portable, independently verifiable by any peer, and explicitly stripped of client-identifying metadata (IP addresses, request headers, client timestamps).

## The Change

1. **`components/gips-trust` (New `fraud` Module)**:
   - Define data structures:

     ```rust
     #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
     pub enum FraudProofType {
         HashMismatch {
             narinfo_body: String,
             signature: String,
             artifact_bytes_base64: String,
         },
         Equivocation {
             feed_entry_a: String,
             feed_entry_b: String,
         },
     }

     #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
     pub struct FraudProof {
         pub publisher_key: String,
         pub proof_type: FraudProofType,
         pub created_at: u64,
     }
     ```

   - Implement `verify_fraud_proof(proof: &FraudProof) -> Result<(), FraudError>`:
     - For `HashMismatch`:
       - Verify signature of `narinfo_body` against `proof.publisher_key`.
       - Recompute NarHash (Nix-base32 SHA-256) of decoded `artifact_bytes`.
       - Extract `NarHash:` from `narinfo_body`.
       - Succeeds (proof is valid) iff the computed hash differs from the signed hash.
       - Returns `FraudError::NoFraudDetected` if the artifact bytes legitimately match the signed hash.
     - For `Equivocation`:
       - Verify both feed entries are validly signed by `proof.publisher_key`.
       - Parse store path and timestamp from both entries.
       - Succeeds (proof is valid) iff store paths / timestamps match but the advertised `artifact_cid` differs.
       - Returns `FraudError::NoFraudDetected` if the entries are identical or non-conflicting.
   - Add unit tests for both proof types with positive fraud vectors and negative (benign / non-fraud / forged signature) cases.

2. **`components/gips-db` (Revocation Storage)**:
   - Add SQLite table migration:

     ```sql
     CREATE TABLE IF NOT EXISTS fraud_proofs (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         publisher_key TEXT NOT NULL,
         proof_type TEXT NOT NULL,
         proof_json TEXT NOT NULL,
         verified_at INTEGER NOT NULL
     );
     CREATE INDEX IF NOT EXISTS idx_fraud_proofs_pubkey ON fraud_proofs(publisher_key);
     ```

   - Implement queries in `Database`:
     - `record_fraud_proof(&self, proof: &FraudProof) -> Result<()>`
     - `is_publisher_revoked(&self, publisher_key: &str) -> Result<bool>`
     - `list_fraud_proofs(&self) -> Result<Vec<FraudProof>>`

3. **`components/gips-http`**:
   - Add endpoint `POST /fraud-proof/submit` (verifies proof, and if valid, records to DB and invalidates caches).
   - Add endpoint `GET /fraud-proof/list` (public query of active revocations).
   - In substitute resolution (`resolve_manifest_entry`), check `is_publisher_revoked` and refuse to serve from revoked publishers.

4. **`gips` CLI (`gips/src/main.rs`)**:
   - Add `gips fraud-proof` command family:
     - `gips fraud-proof generate hash-mismatch --narinfo <file> --signature <sig> --artifact <file> --publisher <key> -> emits FraudProof JSON`
     - `gips fraud-proof generate equivocation --feed-a <file> --feed-b <file> --publisher <key> -> emits FraudProof JSON`
     - `gips fraud-proof verify --proof <file-or-json>` -> independently checks proof validity.
     - `gips fraud-proof submit --proof <file-or-json>` -> sends proof to daemon.
     - `gips fraud-proof list` -> lists revoked publishers.

5. **`scheme/gips/api.scm` & `test_api.scm` (Invariant 1 Parity)**:
   - Export and implement:
     - `(gips-fraud-proof-verify proof-json)`
     - `(gips-fraud-proof-submit proof-json)`
     - `(gips-fraud-proof-list)`
   - Add unit tests in `test_api.scm`.

6. **Docs**:
   - Update `docs/TODO.md` with Stage 40 deliverables.

## Non-goals

- Transitive vouch-graph trust scoring and reputation decay (Stage 41).

## Allowed Files Whitelist

- `components/gips-trust/src/lib.rs`
- `components/gips-trust/src/fraud.rs`
- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **`HashMismatch` Proof Verification**:
   - Valid proof (tampered artifact bytes + signed narinfo) verifies as true fraud.
   - Genuine artifact matching signed narinfo returns `NoFraudDetected`.
   - Tampered signature or invalid publisher key is rejected.
2. **`Equivocation` Proof Verification**:
   - Two conflicting signed feeds for the same store path verify as true fraud.
   - Identical feed entries return `NoFraudDetected`.
3. **Database Revocation & Daemon Guard**:
   - Submitting a verified fraud proof inserts into `fraud_proofs` table.
   - `is_publisher_revoked` returns `true`.
   - `GET /narinfo` or substitute resolution rejects content from the revoked publisher.
4. **CLI & Scheme Parity**:
   - `gips fraud-proof verify`, `submit`, `list` work across CLI and Guile Scheme.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-40] feat: objective cryptographic fraud proofs and revocation engine (gips fraud-proof)`
