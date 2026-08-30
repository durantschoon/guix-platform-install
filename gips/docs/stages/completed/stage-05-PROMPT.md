# Stage 05: Native Guix Narinfo Endpoint

**Motivation**: Plan A requires implementing full Guix narinfo serving semantics. Native Guix substitute clients expect to fetch narinfos by making a request to `GET /<hash>.narinfo` rather than using query parameters like `?store_path=...`.

**The Change**:

1. Update `components/gips-http/src/lib.rs` to add a new route: `.route("/:hash.narinfo", get(get_native_narinfo))`.
2. The `get_native_narinfo` handler should extract the `:hash` path parameter.
3. Query the `substitutes` table for a row where `store_path` contains the hash (e.g. `LIKE '%/hash-%'`). *Alternatively*, if necessary, update the SQLite database creation script to add a `store_hash` column and migrate the insert logic in `publish_substitute`. For this stage, a `LIKE` query or simple string matching on the `store_path` is acceptable if a hash column doesn't exist.
4. Return the `narinfo_json` in the same format as the existing `get_narinfo` handler, ensuring it's served as `text/plain` so Guix can parse it.

**Allowed Files Whitelist**:

- `components/gips-http/src/lib.rs`
- `components/gips-db/src/lib.rs` (if schema changes are needed)

**Enumerated Tests**:

1. Requesting `GET /1234abcd.narinfo` returns the associated narinfo payload.
2. The response content type is appropriate for Guix (`text/plain` or `application/x-nix-archive`).

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- A simulated `curl` against the new endpoint succeeds.

**Commit Message**: `[stage-05] feat: implement native Guix narinfo endpoint`

**Report Requirements**: Specify whether you used a `LIKE` query or altered the schema, and provide the rationale.
