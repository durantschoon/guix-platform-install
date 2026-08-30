# Stage 41 — Transitive Web-of-Trust Evaluation & Dynamic Substitute Resolution (`gips trust evaluate`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

With Attenuable Delegation Tokens (Stage 39) and Objective Fraud Proofs (Stage 40) in place, GIPS can now evaluate the effective trustworthiness of arbitrary publishers dynamically. Instead of relying strictly on a static list of hardcoded keys in `[trust]`, `gipsd` can verify multi-hop vouch chains, apply reputation decay over delegation depth, verify no vouchers in the chain have been revoked by fraud proofs, and determine whether to accept substitutes and index feeds.

## The Change

1. **`components/gips-trust` (New `evaluator` Module)**:
   - Implement `TrustEvaluator` combining:
     - Configured root anchors (`TrustConfig.trusted_publishers`).
     - Ingested/provided `VouchToken` chains.
     - Revocation blacklist from verified fraud proofs.
   - Scoring & decision algorithm:
     - Root publishers start with base stake (e.g. 100).
     - Each hop in a valid vouch chain decays the effective stake score: `hop_score = min(token.capabilities.stake_score, parent_score * decay_factor)`.
     - If any publisher in the vouch chain has an active revocation record, the effective score is immediately `0` (the entire downstream chain is severed).
     - If the target store path does not match the token's `path_prefixes`, return `0`.
     - Expose `evaluate_publisher(&self, publisher_key: &str, store_path: &str, chain: &[VouchToken], now: u64) -> TrustEvaluationResult { score: u32, trusted: bool, reason: String }`.
   - Add unit tests for scoring decay, depth limiting, fraud-proof severing, prefix enforcement, and expiration.

2. **`components/gips-db` (Vouch Storage)**:
   - Add SQLite table migration:

     ```sql
     CREATE TABLE IF NOT EXISTS vouch_chains (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         subject_key TEXT NOT NULL,
         root_key TEXT NOT NULL,
         chain_json TEXT NOT NULL,
         expires_at INTEGER NOT NULL,
         stake_score INTEGER NOT NULL
     );
     CREATE INDEX IF NOT EXISTS idx_vouch_chains_subject ON vouch_chains(subject_key);
     ```

   - Implement queries in `Database`:
     - `record_vouch_chain(&self, root_key: &str, subject_key: &str, chain: &[VouchToken]) -> Result<()>`
     - `get_vouch_chains_for_subject(&self, subject_key: &str) -> Result<Vec<Vec<VouchToken>>>`
     - `prune_expired_vouches(&self, now: u64) -> Result<usize>`

3. **`components/gips-http`**:
   - Integrate `TrustEvaluator` into `resolve_manifest_entry` and `process_feed`:
     - When an untrusted publisher is encountered, query `Database::get_vouch_chains_for_subject`.
     - Evaluate the vouch chains against configured root anchors and fraud proof revocations.
     - If `score >= min_trust_score` (default 50), accept the substitute; otherwise reject.
   - Add endpoint `POST /trust/evaluate` returning `{ "score": u32, "trusted": bool, "reason": String }`.
   - Add endpoint `POST /vouch/ingest` (authenticated) to register received vouch chains.

4. **`gips` CLI (`gips/src/main.rs`)**:
   - Add `gips trust evaluate --publisher <key> [--path <store-path>] [--chain <file-or-json>]` -> prints evaluation score and breakdown.
   - Add `gips vouch ingest --chain <file-or-json>` -> submits vouch chain to daemon database.

5. **`scheme/gips/api.scm` & `test_api.scm` (Invariant 1 Parity)**:
   - Export and implement:
     - `(gips-trust-evaluate publisher-pubkey #:store-path #f #:chain #f)`
     - `(gips-vouch-ingest chain-json)`
   - Add unit tests in `test_api.scm`.

6. **Docs**:
   - Update `docs/TODO.md`, `docs/trust-economics.md`, and `docs/federation.md` reflecting the completion of the Federated Trust & Sybil Resistance milestone.

## Allowed Files Whitelist

- `components/gips-trust/src/lib.rs`
- `components/gips-trust/src/evaluator.rs`
- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`
- `docs/trust-economics.md`
- `docs/federation.md`

## Enumerated Tests

1. **Scoring & Decay**: 1-hop and 2-hop vouch chains compute decaying scores according to formula.
2. **Fraud Severing**: Recording a fraud proof against an intermediary voucher instantly drops downstream subject score to 0.
3. **Prefix Filtering**: Vouch valid only for `/gnu/store/aaa` scores 0 when evaluated for `/gnu/store/bbb`.
4. **Daemon Integration**: Daemon accepts substitutes from a non-root publisher when accompanied by a valid stored vouch chain with score >= threshold.
5. **CLI & Scheme Parity**: `gips trust evaluate` and `(gips-trust-evaluate)` return identical evaluation reports.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` and trust docs updated.

## Commit Message

`[stage-41] feat: transitive web-of-trust evaluation and dynamic substitute resolution (gips trust evaluate)`
