# Stage 34 — Served Narinfo Metadata Completeness (`Deriver:` and `System:` headers)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

Served narinfos emitted by `gipsd` (`GET /:hash.narinfo` and `GET /narinfo`) currently omit the `Deriver:` and `System:` fields.
While basic `guix install` and `guix package` work with `StorePath:`, `NarHash:`, `NarSize:`, and `References:`, the omission of `Deriver:` and `System:` degrades Guix ecosystem tools:

- `guix challenge`: compares substitute hashes against local builds and requires `Deriver:` to correlate store items to build derivations (`.drv`).
- `guix weather`: assesses substitute availability for a given target architecture and expects `System:` (e.g. `x86_64-linux`, `aarch64-linux`).
- `docs/TODO.md` explicitly lists: *"Served narinfos omit `Deriver:` and `System:` fields, degrading `guix challenge` / `guix weather`"*.

> **Anchor by `fn`/struct name + quoted code, not line number.**

## The Change

1. **Schema Migration in `components/gips-db`**:
   - In `Database::migrate`, add `deriver` (`TEXT`) and `system` (`TEXT`) columns to the `substitutes` table if missing (additive, backward-compatible with older DB files where legacy rows have `NULL`).
   - Update `SubstituteRecord` and `Database` query/insert helpers to support optional `deriver` and `system`.
2. **Plumb `deriver` and `system` in `components/gips-http`**:
   - In `PublishRequest`, add optional fields `deriver: Option<String>` and `system: Option<String>`.
   - In `publish_substitute`, validate `deriver` (if provided, must be a valid store path ending with `.drv` or valid store path) and `system` (valid charset, no newlines/control characters), and persist them into the `substitutes` table.
   - In `get_native_narinfo` and `get_narinfo`, if `deriver` and/or `system` are present, emit `Deriver: <deriver>\n` and `System: <system>\n` in the served narinfo text before the `NarHash:`/`Signature:` block (or right after `Compression: none`).
   - When signing with `guix_signing` (libgcrypt), the canonical signed body includes any emitted `Deriver:`/`System:` lines before the `Signature:` line.
3. **CLI Options in `gips`**:
   - Add `--deriver <path>` and `--system <arch>` optional arguments to `gips publish`.
4. **Scheme REPL Integration in `scheme/gips/api.scm`**:
   - Extend `build-publish-json` and `(gips-publish ...)` to support `#:deriver` and `#:system` keyword arguments.
5. **Tests & Docs**:
   - Add unit tests in `gips-db` for `deriver` and `system` migration and persistence.
   - Add unit/integration tests in `gips-http` verifying that published substitutes with `deriver` and `system` render those fields in `/:hash.narinfo`, and verify that omitting them still works seamlessly.
   - Add tests in `test_api.scm` for `gips-publish` with `#:deriver` and `#:system`.
   - Update `docs/TODO.md` to check off the `Deriver:` and `System:` line.

## Non-goals (do not touch)

- No breaking changes to legacy substitute rows lacking `deriver`/`system` (they continue serving without those headers).
- No changes to IPFS transport or Merkle DAG feed ordering.

## Allowed Files Whitelist

- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **Database schema**: `Database::connect` runs migration and creates `deriver` and `system` columns; legacy rows keep `NULL`.
2. **Publish with metadata**: `POST /publish` with `deriver` and `system` stores them; `GET /<hash>.narinfo` renders `Deriver: <drv>` and `System: <sys>`.
3. **Publish without metadata**: `POST /publish` without `deriver` and `system` succeeds; `GET /<hash>.narinfo` omits those headers without emitting blanks or placeholders.
4. **Narinfo signing with metadata**: A narinfo carrying `Deriver:` and `System:` signs deterministically under `guix_signing` and verifies under Guix libgcrypt canonical rules.
5. **Scheme API round-trip**: `(build-publish-json "/gnu/store/..." "gns.gnu" #:deriver "/gnu/store/...-pkg.drv" #:system "x86_64-linux")` produces correct JSON.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-34] feat: store and serve Deriver and System metadata in narinfos, add CLI and Scheme bindings`
