# Stage 11: Offline Snapshots Subcommand

**Motivation**: To begin Plan C (Capability-Oriented, Offline-First Client), we need CLI tools to manage offline snapshots. A snapshot is a manifest of store paths, their narinfo metadata, and IPFS CIDs, stored as a JSON document in IPFS.

**The Change**:

1. Add a new `gips snapshot` subcommand family in `gips/src/main.rs`.
2. Add `create`, `list`, and `import` subcommands.
3. For `create <manifest.scm>`, write a stub that would theoretically compute the closure (mock this for now by just reading a hardcoded store path) and call a new `/snapshot/create` endpoint on `gipsd`.
4. Implement the `/snapshot/create` endpoint in `components/gips-http/src/lib.rs` that takes a list of store paths, looks up their CIDs in the `substitutes` table, constructs a snapshot manifest JSON, and adds it to IPFS via `state.ipfs.add_bytes`.
5. Return the snapshot manifest CID.

**Allowed Files Whitelist**:

- `gips/src/main.rs`
- `components/gips-http/src/lib.rs`
- `docs/TODO.md` (Check off the "Add a `gips snapshot` subcommand family" box)

**Enumerated Tests**:

1. `cargo run -p gips -- snapshot create foo.scm` successfully reaches the daemon and returns a CID.
2. The daemon correctly generates a JSON snapshot manifest containing at least one hardcoded/mocked store path if the DB is empty.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- The snapshot manifest is a valid JSON document stored in IPFS.

**Commit Message**: `[stage-11] feat: add offline snapshots CLI and daemon endpoints`

**Report Requirements**: Describe the JSON structure of the snapshot manifest that was generated.
