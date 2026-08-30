# Stage 33 — Scheme REPL Parity (`scheme/gips/api.scm`) and Secure Auth Token Handling

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

Two major issues exist in the Guile Scheme REPL integration (`scheme/gips/api.scm`):

1. **Broken Scheme REPL Parity (Invariant #1)**:
   - Invariant 1 states: *"Any command that can be run on the command line should also be available in the guile scheme repl"*.
   - In `scheme/gips/api.scm`, `gips-link-channel`, `gips-pin`, and `gips-unpin` are stubs returning `"not yet implemented"`.
   - Essential commands added across recent stages have no Scheme bindings at all:
     - `subscribe` (`POST /subscribe`)
     - `reindex` (`POST /reindex`)
     - `search` (`GET /search?q=...`)
     - `key generate-guix` / `key export-guix`
     - `key generate-feed` / `key export-feed`
     - `snapshot create`
2. **Security Defect — Auth Token Process Exposure**:
   - `http-post-json` in `scheme/gips/api.scm` passes `-H "Authorization: Bearer <token>"` directly on `curl`'s command-line argument vector (`argv`).
   - Every local user or unprivileged process on the host running `ps aux` or inspecting `/proc` can observe the daemon's local authentication token in plain text while a request is in flight.

> **Anchor by `fn`/procedure name + quoted code, not line number.**

## The Change

1. **Secure Auth Token Handling in `scheme/gips/api.scm`**:
   - Eliminate all bearer tokens from `curl`'s command-line arguments.
   - Pass the `Authorization` header via a temporary `curl` configuration file (e.g. `header = "Authorization: Bearer <token>\n"`) with permissions `0600` in a `0700` directory, using `curl -K <config-file>`.
   - Ensure the temporary config file is reliably deleted immediately after the curl process completes (using `dynamic-wind` or equivalent error guards so temporary files never leak on error or interrupt).
2. **Complete CLI $\leftrightarrow$ Scheme REPL Parity in `scheme/gips/api.scm`**:
   - `gips-subscribe`: `(gips-subscribe gns-name)` $\rightarrow$ `POST /subscribe` with `{"gns_name": "<name>"}` (authenticated).
   - `gips-link-channel`: `(gips-link-channel channel-name gns-name #:key (allow-repoint? #f))` $\rightarrow$ `POST /link-channel` with `{"channel_name": "...", "gns_name": "...", "allow_repoint": bool}` (authenticated).
   - `gips-pin`: `(gips-pin ipfs-cid)` $\rightarrow$ `POST /pin` with `{"ipfs_cid": "<cid>"}` (authenticated).
   - `gips-unpin`: `(gips-unpin ipfs-cid)` $\rightarrow$ `POST /unpin` with `{"ipfs_cid": "<cid>"}` (authenticated).
   - `gips-reindex`: `(gips-reindex #:key (prune-missing? #f) (store-paths '()))` $\rightarrow$ `POST /reindex` with `{"prune_missing": bool, "store_paths": [...]}` (authenticated; omit `store_paths` if empty).
   - `gips-search`: `(gips-search query)` $\rightarrow$ `GET /search?q=<query>` (unauthenticated).
   - `gips-key-generate-guix`: `(gips-key-generate-guix #:key (path #f) (guile #f))` $\rightarrow$ invokes key generation helper `components/gips-trust/guile/guix-keygen.scm` (or equivalent) to write the pair with `0600` permissions.
   - `gips-key-export-guix`: `(gips-key-export-guix #:key (path #f))` $\rightarrow$ reads and returns the public key s-expression (`.pub` sibling).
   - `gips-key-generate-feed`: `(gips-key-generate-feed #:key (path #f))` $\rightarrow$ calls key generation for Ed25519 feed keys (via `gips key generate-feed` or helper).
   - `gips-key-export-feed`: `(gips-key-export-feed #:key (path #f))` $\rightarrow$ reads and returns the public PEM.
   - `gips-snapshot-create`: `(gips-snapshot-create manifest #:key (gns-name #f))` $\rightarrow$ computes closure, publishes paths, and posts `/snapshot/create` (or invokes `gips snapshot create`).
   - Export all newly added procedures from `(gips api)` module definition.
3. **Comprehensive Scheme API Test Suite (`test_api.scm`)**:
   - Create `test_api.scm` testing every procedure in `(gips api)`:
     - Argument serialization and JSON payload building.
     - Auth token loading, precedence, and refusal on missing token.
     - Confirmation that temporary curl config files are created with `0600` permissions and unlinked after request execution.
     - Key generation and export helpers round-trip.
   - Wire `test_api.scm` into `just scheme-test` alongside `test_sign.scm`.
4. **Documentation**:
   - Update `scheme/README.md` to document the full procedures table, updated examples, and secure auth mechanism.
   - Update `docs/TODO.md` to check off the Scheme REPL parity and auth token argv exposure items.

## Non-goals (do not touch)

- No changes to daemon HTTP routing, authentication middleware, or verification logic (`components/gips-http`).
- No changes to `GipsdConfig` or TOML serialization in `bases/gips-config`.
- No modification of the Guix libgcrypt signing formats or cryptographic primitives in `gips-trust`.

## Allowed Files Whitelist

- `scheme/gips/api.scm`
- `test_api.scm` (new)
- `justfile` (`scheme-test` recipe update only)
- `scheme/README.md`
- `docs/TODO.md`

## Enumerated Tests

1. **Secure curl invocation**: Authenticated HTTP requests (`gips-publish`, `gips-subscribe`, `gips-pin`, etc.) do **not** pass `Authorization: Bearer` on curl's argv; token is passed via a `0600` config file and the config file is cleaned up after execution (verified by inspecting argv / filesystem state during test).
2. **JSON and query construction**:
   - `build-reindex-json` correctly encodes `prune_missing` and omits `store_paths` when empty.
   - `build-link-channel-json` correctly encodes `channel_name`, `gns_name`, and `allow_repoint`.
   - `build-pin-json` / `build-unpin-json` correctly encode `ipfs_cid`.
   - `build-subscribe-json` correctly encodes `gns_name`.
   - `gips-search` properly URL-encodes query parameters and executes `GET /search?q=...`.
3. **Key management helpers**:
   - `gips-key-generate-guix` writes both `.sec` and `.pub` with `0600` permissions; `gips-key-export-guix` returns the `.pub` contents.
   - `gips-key-generate-feed` writes secret and `.pub.pem` keys with `0600` permissions; `gips-key-export-feed` returns the public PEM.
4. **All Scheme tests pass**: `just scheme-test` runs both `test_sign.scm` and `test_api.scm` and exits 0.

## Definition of Done

- All enumerated tests implemented and green in `test_api.scm`.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- Invariant 1 restored: full REPL parity with all CLI commands.
- Auth token never appears in `ps` argv.

## Commit Message

`[stage-33] feat: Scheme REPL parity in scheme/gips/api.scm, secure curl token passing, test_api.scm suite`

## Report Requirements

- List of all exported Scheme procedures added/updated.
- Description of the secure temporary curl config mechanism.
- Test coverage summary from `test_api.scm`.
- Any deviations or notes.

## Blocked Protocol

If ground truth contradicts this prompt — Guile standard modules cannot safely create `0600` temporary files or invoke curl with `-K`, or CLI arguments disagree with the Scheme API contract — STOP. Commit nothing beyond your branch, document the evidence, and end BLOCKED.
