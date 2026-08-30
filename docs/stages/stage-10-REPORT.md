# Stage 10 report: GIPS subsystem integration

## Changes per file

- `gips/`: Ingested complete GIPS subsystem (bases, components, `gipsd` daemon, `gips` CLI, Guile Scheme modules, TLA+ models, and comprehensive protocol/architecture documentation).
- `gips/scheme/gips/api.scm`: Updated `find-gips-binary` and `locate-guix-keygen` to dynamically resolve paths from parent repo root or subfolder contexts.
- `postinstall/recipes/add/gips.scm`: Created post-install configuration recipe for GIPS with interactive, headless, status, and self-test execution modes.
- `postinstall/recipes/add/gips_purpose.txt`: Documented justifications, security boundaries, and statements of omission for `gips.scm`.
- `docs/PERSONAL_CONFIG_CONTRACT.md`: Added personal multi-machine binary synchronization contract examples.
- `lib/mirrors.md`: Documented GIPS P2P substitute mirror configuration and IPFS swarm integration.
- `Makefile`: Added `gips-test`, `gips-rust-test`, and `gips-check` targets.
- `Makefile_purpose.txt`: Documented the new Makefile targets.
- `run-tests.sh`: Registered GIPS post-install recipe self-test, Scheme API test suite, and narinfo signing suite.
- `SOURCE_MANIFEST.txt`: Refreshed with 79 verified files.
- `docs/stages/stage-10-PROMPT.md`: Authored stage prompt.

## Measured verification & test evidence

1. **GIPS Post-Install Recipe Self-Test (`postinstall/recipes/add/gips.scm --self-test`)**:
   - `ensure-private-dir` verified: directory created with `0700` mode.
   - `default-config-toml` verified: serializes `listen`, `db_path`, `ipfs_api`.
   - `generate-signing-key-if-missing` verified: generates `signing-key.sec` and `signing-key.pub` with `0600` mode.
   - Result: All recipe self-tests passed.

2. **GIPS Scheme API Test Suite (`gips/test_api.scm`)**:
   - Verdict 1/15: JSON builders & URI encoding (13/13 ok)
   - Verdict 2/15: Auth token loading & URL precedence (10/10 ok)
   - Verdict 3/15: Secure temporary curl config lifecycle (6/6 ok)
   - Verdict 4/15: End-to-end HTTP calls over wire (1/1 ok)
   - Verdict 5/15: Key generation & export ceremonies (6/6 ok)
   - Verdict 6/15: Vouch capability delegation (7/7 ok)
   - Verdict 7/15: Cryptographic fraud proofs (11/11 ok)
   - Verdict 8/15: Offline snapshot lifecycle (3/3 ok)
   - Verdict 9/15: Gossip status inspection (1/1 ok)
   - Verdict 10/15: Guix ACL management (10/10 ok)
   - Verdict 11/15: Terminal swarm monitor (2/2 ok)
   - Verdict 12/15: Privacy-preserving substitute prefix queries (1/1 ok)
   - Verdict 13/15: Direct UnixFS directory tree ingestion (1/1 ok)
   - Verdict 14/15: Guix System service definition ((gips service)) (4/4 ok)
   - Verdict 15/15: Standalone GNU Guix package definition ((gips package) & gips.scm) (4/4 ok)
   - Result: All 15 verdicts hold.

3. **GIPS Narinfo Signing Suite (`gips/test_sign.scm`)**:
   - Verdict 1/4: Valid signature round-trip (4/4 ok)
   - Verdict 2/4: Tampered-body rejected as hash-mismatch (3/3 ok)
   - Verdict 3/4: Wrong-key rejected as unauthorized-key (4/4 ok)
   - Verdict 4/4: Helper self-check exercised (7/7 ok)
   - Result: All 4 verdicts hold.

4. **GIPS Rust Workspace Suite (`cargo test --workspace` in `gips/`)**:
   - `gips-config`: unit tests passed
   - `gips-db`: unit tests passed
   - `gips-gns`: unit tests passed
   - `gips-http`: unit tests passed
   - `gips-ipfs`: unit tests passed
   - `gips-nar`: 17 unit tests passed
   - `gips-scheme-config`: 14 unit tests passed
   - `gips-trust`: 38 unit tests passed
   - `guix_signing`: 4 integration tests passed
   - `e2e_federation`: 3 federation simulation tests passed
   - `gipsd`: 8 unit tests passed
   - Result: 0 failed across all crates.

5. **Oracle Offline Suites (`make oracle-test`)**:
   - All 24 capacity checks passed.
   - All 105 validation checks passed.

6. **Static Pre-Deployment Validation (`lib/validate-before-deploy.sh --verbose`)**:
   - Passed: 6, Warnings: 15 (inherited baseline), Failed: 0.
   - 79 files verified against `SOURCE_MANIFEST.txt`.

## Whitelist audit

All files touched or added are strictly within the Stage 10 whitelist.

## Unverified claims

The integration has been verified offline across all Guile Scheme and Rust test harnesses. Live multi-node cloud sync between live Oracle Always Free instances and bare-metal Framework laptops remains a subsequent live acceptance milestone.
