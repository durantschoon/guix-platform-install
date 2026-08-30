# Stage 42 — Complete Offline Snapshot Lifecycle (`gips snapshot list`, `import`, `export`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

Plan C specifies capability-oriented, offline-first substitute distribution. In Stage 31, `gips snapshot create` was implemented to compute closures from Scheme manifests, publish them, and generate signed snapshot manifests in IPFS. However, `gips snapshot list`, `import`, and `export` were left as stubs that fail loudly (`docs/TODO.md` lines 130-132).

To enable fully offline or air-gapped workflows (such as exporting a data science environment from a connected workstation and loading it onto an offline server), GIPS needs the complete lifecycle:

1. **List snapshots** known to the local daemon.
2. **Import snapshots** by CID: fetching the manifest, validating nar integrity, pinning all artifact CIDs locally, and registering substitutes into the database.
3. **Export snapshots** into a portable `.tar` archive bundling the manifest and all constituent NAR archives for air-gapped file transfers.

## The Change

1. **`components/gips-db` (Snapshot Metadata Persistence)**:
   - Add SQLite migration:

     ```sql
     CREATE TABLE IF NOT EXISTS snapshots (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         snapshot_cid TEXT NOT NULL UNIQUE,
         gns_name TEXT,
         store_paths_json TEXT NOT NULL,
         created_at INTEGER NOT NULL
     );
     CREATE INDEX IF NOT EXISTS idx_snapshots_cid ON snapshots(snapshot_cid);
     ```

   - Implement `SnapshotRecord` struct (`snapshot_cid`, `gns_name`, `store_paths: Vec<String>`, `created_at`).
   - Implement database methods:
     - `record_snapshot(&self, snapshot: &SnapshotRecord) -> Result<()>`
     - `list_snapshots(&self) -> Result<Vec<SnapshotRecord>>`
     - `get_snapshot(&self, cid: &str) -> Result<Option<SnapshotRecord>>`

2. **`components/gips-http` (Endpoints & Import/Export Engine)**:
   - In `create_snapshot`: persist the newly created snapshot into the `snapshots` DB table.
   - Add route `GET /snapshot/list`: returns JSON array of `SnapshotRecord`s.
   - Add authenticated route `POST /snapshot/import`:
     - Accepts `{ "cid": String }`.
     - Fetches manifest from IPFS via `state.ipfs.cat(&cid)`.
     - Parses `SnapshotWrapper` (or bare manifest).
     - Validates that each entry contains valid `artifact_cid`, `NarHash`, and `StorePath`.
     - Pins each `artifact_cid` in IPFS (`state.ipfs.pin_add(&entry.artifact_cid)`).
     - Inserts each substitute mapping (`store_path`, `ipfs_cid`, `narinfo_json`) into `substitutes` table.
     - Persists the imported snapshot in `snapshots` table.
     - Returns `{ "snapshot_cid": String, "imported_entries": usize }`.
   - Add route `GET /snapshot/export/:cid`:
     - Fetches manifest from IPFS.
     - Streams an uncompressed POSIX `.tar` archive (using `tar` or `tokio-tar` crate) containing `manifest.json` and each constituent `nar/<cid>` artifact.

3. **`gips` CLI (`gips/src/main.rs`)**:
   - Implement `SnapshotCommands::List`: calls `GET /snapshot/list` and prints formatted table/list of snapshots.
   - Implement `SnapshotCommands::Import { cid }`: calls `POST /snapshot/import` with auth token, prints progress and summary.
   - Add `SnapshotCommands::Export { cid, output: Option<PathBuf> }`: downloads the `.tar` archive from `GET /snapshot/export/:cid` and saves to `--output <file>` (defaulting to `<cid>.tar`).

4. **`scheme/gips/api.scm` & `test_api.scm` (Invariant 1 Parity)**:
   - Export and implement:
     - `(gips-snapshot-list)`
     - `(gips-snapshot-import cid)`
     - `(gips-snapshot-export cid #:output-file #f)`
   - Add unit tests in `test_api.scm`.

5. **Docs**:
   - Update `docs/TODO.md` and `docs/offline-snapshots.md` marking snapshot `list`, `import`, and `export` completed.

## Allowed Files Whitelist

- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `components/gips-http/Cargo.toml` (if `tar` or `async-tar` is added)
- `Cargo.toml` (root, for workspace dependency if needed)
- `Cargo.lock`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`
- `docs/offline-snapshots.md`

## Enumerated Tests

1. **Snapshot DB Persistence**: Creating and importing snapshots inserts into `snapshots` table and `list_snapshots` retrieves them in reverse chronological order.
2. **Snapshot Import Flow**: `POST /snapshot/import` successfully parses manifest, pins CIDs, inserts substitutes, and allows immediate `/narinfo` and `/nar` serving for imported store paths.
3. **Snapshot Export Flow**: `GET /snapshot/export/:cid` produces a valid tar archive containing `manifest.json` and all referenced NAR payloads.
4. **CLI & Scheme Parity**: `gips snapshot list`, `import`, `export` execute identically across CLI and Guile Scheme.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` and `docs/offline-snapshots.md` updated.

## Commit Message

`[stage-42] feat: complete offline snapshot lifecycle (gips snapshot list, import, export)`
