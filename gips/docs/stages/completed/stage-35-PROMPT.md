# Stage 35 — Signing-Key Lifecycle & Cache Invalidation (SIGHUP reload, key cache invalidation, `gips auth rotate`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In earlier stages, the serve-time signature cache in `components/gips-http` was configured with a fixed 1-hour TTL and had no invalidation on key file modifications. If an operator rotated or revoked their signing key on disk, `gipsd` would continue serving signatures generated with the old key for up to 1 hour. Furthermore, there was no CLI or Scheme path to rotate local authentication tokens (`gips auth rotate`), and `gipsd` lacked SIGHUP signal handling to reload tokens and flush key caches.

`docs/TODO.md` documents both items:

- *"Signing-key lifecycle: no rotation or revocation path; the serve-time signature cache is TTL-only (1 h) and is not invalidated if the key changes"*
- *"Auth-token rotation (`gips auth rotate`) and SIGHUP config reload wired to key-cache invalidation."*

> **Anchor by `fn`/struct name + quoted code, not line number.**

## The Change

1. **`bases/gips-config`**:
   - Implement `AuthToken::rotate(path: &Path) -> Result<Self, AuthTokenError>` which generates a fresh CSPRNG token, writes it with mode `0600` to a temporary sibling file, and renames it atomically over `path`.
   - Implement `AuthTokenHolder` (or `Arc<RwLock<AuthToken>>`) supporting concurrent reads and in-memory reload on rotation/SIGHUP.
2. **`components/gips-trust`**:
   - In `KeyCache`, add `pub fn clear(&self)` to purge cached private and public keys.
   - In `GuixSigner`, expose `secret_key_mtime(&self) -> Option<SystemTime>` and include key mtime in cache-key or freshness validation.
3. **`components/gips-http`**:
   - In `AppState`, add `pub fn invalidate_key_caches(&self)` to invalidate `narinfo_signatures`, `resolve_cache`, and clear `keys`.
   - In `narinfo_signature`, include key modification timestamp so any file modification to the secret key automatically invalidates cached signatures without waiting for 1h TTL.
   - Update `build_router` and `require_local_token` to read `AuthToken` from the shared holder/lock.
4. **`gips` CLI**:
   - Add `gips auth rotate [--token-file <path>]` subcommand.
5. **`scheme/gips/api.scm`**:
   - Add `(gips-auth-rotate #:token-file ...)` procedure and tests in `test_api.scm`.
6. **`gipsd`**:
   - Spawn SIGHUP signal handler on Unix platforms to reload the auth token from disk, invoke `invalidate_key_caches()`, and log the event.
7. **Tests & Docs**:
   - Add unit tests for `AuthToken::rotate`, key cache invalidation on file mtime change, SIGHUP reload, and `gips auth rotate` CLI parsing.
   - Update `docs/TODO.md`.

## Non-goals (do not touch)

- No changes to IPFS CID hashing or substitute payload formats.
- No network-wide key revocation protocol (local file lifecycle and SIGHUP only).

## Allowed Files Whitelist

- `bases/gips-config/src/lib.rs`
- `components/gips-trust/src/lib.rs`
- `components/gips-trust/src/guix.rs`
- `components/gips-http/src/lib.rs`
- `gipsd/src/main.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **`AuthToken::rotate`**: Rotates token atomically, ensuring old token is replaced, new token has 0600 permissions and valid 64-hex format.
2. **Key cache invalidation on disk change**: Modifying a `.sec` key file on disk causes `narinfo_signature` to detect mtime change and immediately produce a signature from the new key.
3. **`KeyCache::clear`**: Clears in-memory keys, forcing subsequent requests to re-read from disk.
4. **CLI `gips auth rotate`**: Successfully parses subcommand and rotates target token file.
5. **Scheme `(gips-auth-rotate)`**: Generates new token file and updates token.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-35] feat: signing key cache invalidation on file change, SIGHUP daemon reload, and gips auth rotate command`
