# Stage 26 — SQLite durability/concurrency pragmas (WAL, busy_timeout, synchronous)

**Motivation (measured):** `Database::connect_at` opens the pool with

```rust
let opts = SqliteConnectOptions::new()
    .filename(db_path)
    .create_if_missing(true);
SqlitePoolOptions::new()
    .max_connections(5)
    .connect_with(opts)
```

and no pragma is configured anywhere in the workspace — `grep -rE 'journal_mode|busy_timeout|synchronous|foreign_keys' components/ bases/ gipsd/ gips/` matches only a comment in `gips-db`. The daemon therefore runs on SQLite defaults: rollback journal, `busy_timeout = 0`, `synchronous = FULL`. Two concurrent writer paths share the 5-connection pool — the Axum handlers (`/publish`, `/subscribe`, `/link-channel`, `/reindex`) and the mirror worker that ticks every 60s inserting substitutes and upserting `publisher_state`. With a rollback journal and zero busy timeout, a reader or second writer that collides with a write returns `SQLITE_BUSY` immediately instead of waiting, surfacing as spurious 500s under exactly the burst-read load (`guix-daemon` narinfo storms) the benchmarks measure.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change (all in `components/gips-db/src/lib.rs`, inside `connect_at`):**

1. Configure the connection via sqlx's typed `SqliteConnectOptions` builder methods (not raw `PRAGMA` query strings):
   - `journal_mode(SqliteJournalMode::Wal)`
   - `synchronous(SqliteSynchronous::Normal)` — safe with WAL: a power loss may lose the last transactions but cannot corrupt the database; this DB is a rebuildable index over IPFS-carried truth.
   - `busy_timeout(Duration::from_secs(5))`
   - `foreign_keys(true)` — the schema has no FK constraints today; this future-proofs, costs nothing, and must not break any existing statement (verify).
2. **Preserve the permissions invariant.** The comment above `connect_at` ("SQLite copies the database file's mode onto its journal and WAL") is now load-bearing: with WAL enabled, `gipsd.sqlite-wal` and `gipsd.sqlite-shm` appear next to the DB. Assert by test — not by comment — that after a write both sidecar files are owner-only (0600), since the DB is treated as key-equivalent secret material. If the assertion fails on this platform, that is a **Blocked** finding, not something to paper over.
3. **Migration safety.** `connect` must upgrade a database created by an older gipsd (rollback-journal mode) in place: opening an existing non-WAL file must transparently switch it to WAL. No schema change, no new columns — `migrate` is untouched.
4. Update the comment block above `connect_at` to document the chosen pragmas and why (one short paragraph, same voice as the existing comments).

**Ground rules:** This is a configuration stage — no schema changes, no query rewrites, no new dependencies beyond what `sqlx` already exposes (the `SqliteJournalMode`/`SqliteSynchronous` types are in `sqlx::sqlite`). Do not touch `gips-http`, the mirror worker, or `run_reindex` (its full-table scan is a separate backlog item). No `git push` — the coordinator pushes.

**Allowed Files Whitelist:**

- `components/gips-db/src/lib.rs`
- `#[cfg(test)]` modules (in `gips-db`; a concurrency test may live in gips-db's existing test module)
- member `Cargo.toml`/`Cargo.lock` only if a dev-dependency for tests is genuinely required (flag it in the report)

**Enumerated Tests:**

1. After `Database::connect`, `PRAGMA journal_mode` returns `wal`, `PRAGMA synchronous` returns `1` (NORMAL), `PRAGMA busy_timeout` returns `5000`, and `PRAGMA foreign_keys` returns `1` — queried through the pool itself.
2. Interleaved concurrent writers: two tokio tasks each performing N inserts through the same pool complete without any `SQLITE_BUSY`/"database is locked" error.
3. (unix) After at least one write, the `-wal` and `-shm` sidecar files exist and are mode 0600.
4. A database file created with default (rollback-journal) options, then reopened via `Database::connect`, ends up in WAL mode with all rows intact.

**Definition of Done:** All enumerated tests pass; `cargo check`, `just fmt-check`, `just test` green; `just lint` compared against the base commit (422 pre-existing markdown errors are the known baseline — no new errors); `just audit` is vacuous on this machine (cargo-deny/cargo-audit absent) — note it ran, don't chase it; `just scheme-test` is known-broken on this environment (`guile-gcrypt` missing) and is out of scope.

**Commit Message:** `[stage-26] perf: enable WAL, synchronous=NORMAL, busy_timeout=5s, foreign_keys on SQLite connect`

**Report Requirements:** List each pragma with its chosen value and one-line rationale; confirm sidecar-file permissions observed in test 3; state whether test 4 required any special handling (e.g. WAL switch needing an exclusive lock); disclose any whitelist deviation.

**Blocked protocol:** If a pragma cannot be set through `SqliteConnectOptions` on the pinned sqlx 0.8.1, or the sidecar permissions assertion fails, STOP and report — do not substitute raw `PRAGMA` execution or loosen the assertion without coordinator sign-off.

---
