# Stage 39 — Attenuable Capability Delegation Tokens (`gips vouch mint`, `verify`, `inspect`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In GIPS, trust is currently configured via static, binary `[trust]` configuration (`trusted_publishers`). While this secures personal sync and static publisher lists, scaling to a peer-to-peer substitute network without central gatekeepers requires a federated web of trust to prevent Sybil flooding and contain blast radius.

`docs/trust-economics.md` and `docs/federation.md` specify the foundation for this:

- **Local accountability, global amplification**: Groups vouch for their members using attenuable-capability delegation chains (UCAN/macaroon-style) rooted in signed identities.
- **Attenuable capabilities**: Delegation tokens specify bounded constraints (allowed store path prefixes, maximum delegation depth, bounded reputation/stake score, and explicit expiration).
- **Cryptographic verification**: Delegation chains `[T_1, T_2, ..., T_k]` must form an unbroken, attenuating cryptographic sequence from an accepted root of trust down to the target publisher.

Stage 39 implements the core delegation token format, cryptographic signing & verification, chain validation with strict attenuation rules, and CLI / Scheme REPL parity.

## The Change

1. **`components/gips-trust` (New `vouch` Module)**:
   - Define capability & token structures:

     ```rust
     #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
     pub struct VouchCapabilities {
         /// Allowed store path prefixes (e.g. `["/gnu/store/"]`)
         pub path_prefixes: Vec<String>,
         /// Maximum downstream delegation depth permitted (0 = leaf, cannot delegate further)
         pub max_depth: u32,
         /// Vouch weight / stake score (e.g. 1..100)
         pub stake_score: u32,
     }

     #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
     pub struct VouchPayload {
         pub issuer: String,
         pub subject: String,
         pub parent_token: Option<String>,
         pub issued_at: u64,
         pub expires_at: u64,
         pub capabilities: VouchCapabilities,
     }

     #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
     pub struct VouchToken {
         pub payload: VouchPayload,
         pub signature: String,
     }
     ```

   - Implement canonical payload serialization and Ed25519 signing (`mint_vouch_token`) using the issuer's private feed key.
   - Implement `verify_vouch_token` (checks payload canonical signature under issuer's public key, expiration against given timestamp).
   - Implement `verify_vouch_chain(root_pubkey: &str, chain: &[VouchToken], target_subject: Option<&str>, now: u64) -> Result<VouchCapabilities, VouchError>`:
     - Verifies `chain[0].payload.issuer == root_pubkey`.
     - Verifies each token's signature under its issuer's public key.
     - Verifies unbroken chain linkage (`chain[i].payload.issuer == chain[i-1].payload.subject`).
     - Verifies parent token reference linkage if `parent_token` is specified.
     - Verifies strict attenuation at every step:
       - `depth`: `chain[i].payload.capabilities.max_depth < chain[i-1].payload.capabilities.max_depth`.
       - `stake_score`: `chain[i].payload.capabilities.stake_score <= chain[i-1].payload.capabilities.stake_score`.
       - `expires_at`: `chain[i].payload.expires_at <= chain[i-1].payload.expires_at`.
       - `path_prefixes`: each prefix in `chain[i]` must start with one of `chain[i-1]`'s allowed prefixes.
     - Verifies no token in the chain is expired at `now`.
     - If `target_subject` is provided, verifies `chain.last().payload.subject == target_subject`.
     - Returns the effective attenuated capabilities.
   - Add unit tests covering single tokens, multi-hop chains, expired tokens, depth violation, prefix expansion rejection, stake inflation rejection, and signature tampering.

2. **`components/gips-http`**:
   - Add public verification endpoint `POST /vouch/verify` accepting `{ "root_key": String, "chain": Vec<VouchToken>, "target_subject": Option<String> }` returning the validated `VouchCapabilities` or error.
   - Add unit tests for endpoint routing and JSON serialization.

3. **`gips` CLI (`gips/src/main.rs`)**:
   - Add `gips vouch` command family:
     - `gips vouch mint --issuer-key <path> --subject <pubkey-or-path> --expires-in <secs> [--parent-token <json-or-file>] [--depth <d>] [--stake <s>] [--prefix <p>...]` -> emits JSON `VouchToken` to stdout.
     - `gips vouch verify --root-key <pubkey-path> --chain <json-or-file> [--target <subject-pubkey>]` -> verifies chain and prints effective capabilities.
     - `gips vouch inspect --token <json-or-file>` -> prints human-readable summary of token payload & status.

4. **`scheme/gips/api.scm` & `test_api.scm` (Invariant 1 Parity)**:
   - Export and implement:
     - `(gips-vouch-mint issuer-key-path subject-pubkey #:parent-token #f #:expires-in 86400 #:max-depth 2 #:stake-score 100 #:path-prefixes '("/gnu/store/"))`
     - `(gips-vouch-verify root-pubkey chain-json #:target-subject #f)`
     - `(gips-vouch-inspect token-json)`
   - Add unit tests in `test_api.scm`.

5. **Docs**:
   - Update `docs/TODO.md` with Stage 39 deliverables under the Federated Trust & Sybil Resistance milestone.

## Non-goals (deferred to subsequent stages)

- Objective fraud proof gossip and penalty slashing (Stage 40).
- SQLite persistence of vouch records in `gips-db` and dynamic trust scoring in substitute resolution (Stage 41).

## Allowed Files Whitelist

- `components/gips-trust/src/lib.rs`
- `components/gips-trust/src/vouch.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **Token Minting & Signature Verification**: Mint a `VouchToken` with an Ed25519 feed key, verify signature matches canonical payload bytes.
2. **Chain Linkage & Root Verification**: A 3-token chain rooted at `PubKey_Root` -> `PubKey_A` -> `PubKey_B` -> `PubKey_C` validates successfully when `root_key == PubKey_Root` and `target == PubKey_C`.
3. **Attenuation Enforcement**:
   - Depth expansion (e.g. parent depth 1, child depth 2) is rejected.
   - Stake score inflation (e.g. parent stake 50, child stake 80) is rejected.
   - Prefix widening (parent allows `/gnu/store/abc`, child requests `/gnu/store/`) is rejected.
   - Expiration extension (child expires after parent) is rejected.
4. **Temporal Expiration**: A token where `expires_at < now` is rejected.
5. **Tamper Resistance**: Modifying any field in payload invalidates the signature and fails verification.
6. **CLI & Scheme Parity**: `gips vouch mint`, `verify`, and `inspect` execute successfully via both CLI and Guile Scheme REPL bindings.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-39] feat: attenuable capability delegation tokens (gips vouch mint, verify, inspect)`
