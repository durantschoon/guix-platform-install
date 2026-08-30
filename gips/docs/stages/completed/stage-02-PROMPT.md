# Stage 02: Polylith Documentation

**Motivation**: According to `docs/TODO.md` (Plan A), we need to create `docs/polylith_rust.md` to introduce users to our specific Polylith-style Rust setup and document learnings/gotchas.

**The Change**:

1. Create `docs/polylith_rust.md`.
2. Document the separation between `bases/`, `components/`, and the top-level deployables (`gips`, `gipsd`).
3. Document any gotchas when mixing Polylith principles with Cargo workspaces (e.g. dependency resolution, path dependencies).

**Allowed Files Whitelist**:

- `docs/polylith_rust.md` (NEW)

**Enumerated Tests**:

1. Markdown renders correctly (no broken headers).

**Definition of Done**:

- File is created and contains the required sections.
- `cargo check` and `cargo fmt --check` still pass.

**Commit Message**: `[stage-02] docs: document Polylith Rust architecture`

**Report Requirements**: Provide a summary of the sections added to the document.
