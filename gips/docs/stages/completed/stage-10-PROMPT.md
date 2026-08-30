# Stage 10: Indexer Process and CLI Search

**Motivation**: To complete Plan B (Federated Mirror & Index Network), users need the ability to search across mirrored feeds for specific substitutes. We need a background indexer in `gipsd` that indexes `substitutes` into an FTS (Full Text Search) table, and a `gips search` CLI command to query it.

**The Change**:

1. Update `components/gips-db/src/lib.rs` to create an FTS5 virtual table for searching substitutes (e.g., `CREATE VIRTUAL TABLE IF NOT EXISTS substitutes_fts USING fts5(store_path, gns_name, content='substitutes', content_rowid='id');`).
2. Update the background mirror worker in `components/gips-http/src/lib.rs` to insert new entries into `substitutes_fts`.
3. Add a `GET /search?q=...` endpoint to `gipsd` that queries the FTS table and returns matching results.
4. Add a `gips search <query>` subcommand in `gips/src/main.rs` that calls the `/search` endpoint and prints the results in a readable format.

**Allowed Files Whitelist**:

- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`
- `docs/TODO.md` (Check off the "Implement an indexer process" box)

**Enumerated Tests**:

1. `cargo run -p gips -- search hello` successfully sends a query to the daemon.
2. The daemon successfully queries the FTS table and returns results (even if empty).

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- FTS table triggers or manual insertions keep the index synchronized with the `substitutes` table.

**Commit Message**: `[stage-10] feat: implement substitute indexer and search CLI`

**Report Requirements**: Show the output of a mock `gips search` command in your final summary.
