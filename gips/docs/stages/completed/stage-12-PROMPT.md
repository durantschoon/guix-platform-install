# Stage 12: Snapshot Substitutes and Scheme Profiles

**Motivation**: To finalize Plan C, `gipsd` must be able to act as an offline substitute server backed by a snapshot manifest, and we must introduce Scheme-configurable snapshot profiles.

**The Change**:

1. Modify `components/gips-http/src/lib.rs` to allow the daemon to boot in "offline snapshot mode", taking a snapshot CID as its source of truth rather than the SQLite database.
2. Update the `/narinfo` and `/nar` endpoints to first check the loaded snapshot manifest before falling back to the database or GNS.
3. Update `scheme/gips/config.scm` and `bases/gips-config/src/lib.rs` to support `snapshot_cid` as an optional configuration property.
4. Update `gipsd/src/main.rs` to load the snapshot manifest into memory at startup if `snapshot_cid` is provided.

**Allowed Files Whitelist**:

- `components/gips-http/src/lib.rs`
- `scheme/gips/config.scm`
- `bases/gips-config/src/lib.rs`
- `gipsd/src/main.rs`
- `docs/TODO.md` (Check off the "Implement snapshot manifests" and "Design Scheme-configurable snapshot profiles" boxes)

**Enumerated Tests**:

1. The Scheme config API successfully serializes a `snapshot_cid` field.
2. `gipsd` successfully parses the TOML with the `snapshot_cid` and attempts to load it.
3. If a snapshot is loaded, `/narinfo` returns the metadata from the snapshot manifest.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- The Scheme API remains consistent with the Rust structs.

**Commit Message**: `[stage-12] feat: implement snapshot integration and scheme profiles`

**Report Requirements**: None.
