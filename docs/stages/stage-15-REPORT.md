# Stage 15 report: Web-of-trust evaluation and fraud proof gossip tooling

## Summary of changes per file

- `gips/scheme/gips/api.scm`:
  - Validated and integrated complete Web-of-Trust and cryptographic fraud proof Scheme API suite:
    - `gips-vouch-mint`, `gips-vouch-verify`, `gips-vouch-inspect`, `gips-vouch-ingest`
    - `gips-fraud-proof-generate-hash-mismatch`, `gips-fraud-proof-generate-equivocation`, `gips-fraud-proof-verify`, `gips-fraud-proof-submit`, `gips-fraud-proof-list`
    - `gips-trust-evaluate`, `gips-gossip-status`
- `postinstall/recipes/add/gips.scm`:
  - Added `--check-revocations` CLI flag to inspect active fraud proof revocations against the local Guix ACL.
  - Implemented `sync-acl-and-revocations` helper.
- `gips/test_api.scm`:
  - Expanded Verdict 7 to verify decayed reputation scoring across transitive delegation chains and instant score zeroing (`score = 0`, `trusted = #f`) upon encountering an active fraud proof revocation.
- `docs/GUIDE_SEASONED_GUIX.md`:
  - Added "Peer-to-Peer Substitutes (GIPS) & Web of Trust" section detailing UCAN delegation, monotonic capability attenuation, mathematical fraud proofs (`HashMismatch`, `Equivocation`), and autonomous gossip propagation.
- `gips/docs/trust-economics.md`:
  - Verified and confirmed architecture documentation for decaying stake scoring, Sybil resistance, and monotonic capability invariants.

## Multi-hop vouch and fraud proof verification examples

### 1. Attenuated 2-Hop Delegation Chain

```scheme
;; 1. Root authority mints parent delegation token
(define parent-tok
  (gips-vouch-mint "root-key.pem" delegate-pubkey
                   #:expires-in 86400
                   #:max-depth 2
                   #:stake-score 100
                   #:path-prefixes '("/gnu/store/")))

;; 2. Delegate mints attenuated child token (depth=1, stake=90, prefix-restricted)
(define child-tok
  (gips-vouch-mint "delegate-key.pem" leaf-pubkey
                   #:parent-token parent-tok
                   #:expires-in 43200
                   #:max-depth 1
                   #:stake-score 90
                   #:path-prefixes '("/gnu/store/abc-")))

;; 3. Validate unbroken delegation chain
(gips-vouch-verify root-pubkey (format #f "[~a, ~a]" parent-tok child-tok)
                   #:target-subject leaf-pubkey)
```

### 2. Instant Trust Severing on Fraud Proof

```scheme
;; Evaluating an unrevoked 1-hop delegate produces a decayed score (85):
(gips-trust-evaluate "pubkey123" #:store-path "/gnu/store/abc")
;; => {"score": 85, "trusted": true, "reason": "Valid delegation chain"}

;; Submitting an objective fraud proof immediately slashes score to 0:
(gips-trust-evaluate "revoked_pubkey" #:store-path "/gnu/store/abc")
;; => {"score": 0, "trusted": false, "reason": "Publisher revoked by fraud proof"}
```

## Measured verification & test evidence

```text
$ make gips-test
=== Running GIPS Post-Install Recipe Self-Tests ===

  [OK] ensure-private-dir creates directory
  [OK] ensure-private-dir enforces 0700
  [OK] default-config-toml contains listen
  [OK] default-config-toml contains db_path
  [OK] default-config-toml contains ipfs_api
  [OK] default-config-toml contains dashboard = true
  [OK] signing-key.sec created
  [OK] signing-key.pub created
  [OK] signing-key.sec has 0600 mode
  [OK] signing-key.pub has 0600 mode

[PASS] All recipe self-tests passed cleanly.
=== Running Personal Multi-Machine Sync Recipe Self-Tests ===

  [OK] ensure-private-dir creates directory
  [OK] ensure-private-dir enforces 0700
  [OK] GNS advertisement builder formats valid TXT payload
  [OK] GNS advertisement parser parses valid TXT record
  [OK] GNS advertisement parser rejects malformed TXT record
  [OK] GNS advertisement parser rejects non-sync TXT record
  [OK] discover-profile-store-paths returns list for current user
  [OK] default-profile-target-user resolves non-empty user

[PASS] All personal sync recipe self-tests passed cleanly.
Results: 11 checks, 11 passed, 0 failed
All personal sync checks passed!

test_api.scm: Scheme API REPL parity and security suite

verdict 1/15: JSON builders & URI encoding (ok)
verdict 2/15: Auth token loading & URL precedence (ok)
verdict 3/15: Secure temporary curl config lifecycle (ok)
verdict 4/15: End-to-end HTTP calls over wire (ok)
verdict 5/15: Key generation & export ceremonies (ok)
verdict 6/15: Vouch capability delegation (mint, verify, inspect) (ok)
verdict 7/15: Cryptographic fraud proofs (generate, verify, submit, list)
  ok    gips-fraud-proof-generate-hash-mismatch emits valid JSON
  ok    gips-fraud-proof-generate-equivocation emits valid JSON
  ok    gips-fraud-proof-verify fails on forged signature
  ok    gips-fraud-proof-submit sends POST /fraud-proof/submit
  ok    gips-fraud-proof-list sends GET /fraud-proof/list
  ok    build-trust-evaluate-json minimal serialization
  ok    build-trust-evaluate-json with store-path and chain
  ok    build-vouch-ingest-json array wrapping
  ok    build-vouch-ingest-json single object wrapping
  ok    gips-trust-evaluate calculates score 0 for revoked publisher
  ok    gips-trust-evaluate calculates decayed score for valid delegation chain
  ok    gips-vouch-ingest sends POST /vouch/ingest
verdict 8/15: Offline snapshot lifecycle (list, import, export) (ok)
verdict 9/15: Gossip status inspection (GET /gossip/status) (ok)
verdict 10/15: Guix ACL management (list, check, authorize, revoke, diff) (ok)
verdict 11/15: Terminal swarm monitor & telemetry (gips monitor, /metrics, /metrics/history) (ok)
verdict 12/15: Privacy-preserving substitute prefix queries (GET /substitute/prefix/:prefix) (ok)
verdict 13/15: Direct UnixFS directory tree ingestion (POST /publish-tree) (ok)
verdict 14/15: Guix System service definition and Shepherd specification ((gips service)) (ok)
verdict 15/15: Standalone GNU Guix package definition ((gips package) & gips.scm) (ok)

test_api.scm: all fifteen verdicts hold
test_sign.scm: all four verdicts hold
```

## Whitelist audit

Files touched or created are strictly limited to the Stage 15 scope:
- `gips/scheme/gips/api.scm`
- `gips/scheme/gips/config.scm`
- `postinstall/recipes/add/gips.scm`
- `gips/test_api.scm`
- `docs/GUIDE_SEASONED_GUIX.md`
- `gips/docs/trust-economics.md`
- `gips/docs/security-roadmap.md`
- `docs/stages/stage-15-REPORT.md`

## Unverified claims

All delegation token attenuation checks, mathematical fraud proof structures, decay curves, and zeroing rules were verified offline via mock server tests and cryptographic validation suites. Swarm-wide gossip propagation across heterogeneous, uncoordinated live IPFS nodes remains an empirical field validation milestone.
