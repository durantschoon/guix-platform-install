# Stage 50 — Store Directory Direct UnixFS Ingestion & Streaming NAR Synthesizer

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

Currently, publishing a store path serializes the entire directory into a single opaque `.nar` archive before pinning to IPFS. While compliant with Guix substitute protocols, it prevents cross-package file-level deduplication and prevents standard IPFS tooling / UnixFS gateways from browsing directory contents directly.

Stage 50 introduces **Direct UnixFS Ingestion & Streaming NAR Synthesis**:

1. **Directory Tree Ingestion (`gips publish-tree`)**: Ingests store paths directly as UnixFS directory hierarchies into IPFS, capturing file metadata (regular files, symlinks, directories, executable permissions).
2. **On-the-Fly Streaming NAR Synthesizer (`components/gips-nar`)**: Traverses a UnixFS directory tree and synthesizes a bit-for-bit deterministic Guix Normalized Archive (NAR) byte stream on the fly.
3. **HTTP Serving Endpoint (`components/gips-http`)**: `POST /publish-tree` and on-demand streaming for UnixFS trees.
4. **CLI & Guile Scheme Parity**: `gips publish-tree <store-path>`, `(gips-publish-tree "<store-path>")`, and Verdict 13 in `test_api.scm`.

## The Change

1. **Tree Nar Serialization in `components/gips-nar`**:
   - Implement `dump_dir_to_nar(path: &Path, writer: &mut W) -> Result<()>` or `synthesize_nar_from_directory(path: &Path) -> Result<Vec<u8>>` ensuring identical byte output to `guix archive --export` / `nix-store --dump`.
   - Unit tests verifying exact NAR format determinism against standard fixtures.

2. **HTTP Daemon Endpoints (`components/gips-http`)**:
   - Add `POST /publish-tree` endpoint accepting store paths, uploading directory contents to IPFS, and indexing them in SQLite.
   - Add streaming support for UnixFS synthesized NARs.

3. **CLI & Scheme REPL Integration (`gips/src/main.rs`, `scheme/gips/api.scm`, `test_api.scm`)**:
   - Implement `gips publish-tree <store-path> [--gns-name <name>]`.
   - Implement `(gips-publish-tree store-path #:gns-name name)` in Guile Scheme REPL.
   - Add Verdict 13 in `test_api.scm`.

4. **Documentation**:
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md`.

## Allowed Files Whitelist

- `components/gips-nar/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `README.md`
- `docs/user_guide.md`
- `docs/TODO.md`
- `docs/stages/stage-50-PROMPT.md` (or completed)

## Enumerated Tests

1. `test_nar_directory_tree_synthesis_determinism`
2. `test_publish_tree_http_endpoint`
3. `test_api.scm` Verdict 13 (`gips-publish-tree` parity)
4. `cargo test --all` and `just scheme-test`

## Definition of Done

- All 13 verdicts in `test_api.scm` hold.
- `cargo test --all` passes 100% green with zero warnings.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-50] feat: direct unixfs directory tree publishing and streaming nar synthesis`
