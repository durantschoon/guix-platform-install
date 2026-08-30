# Stage 07: Link Channel Implementation

**Motivation**: To complete Plan A's CLI requirements, we need to flesh out the `link-channel` command. This will allow users to associate a local channel alias with a remote GNS name.

**The Change**:

1. Update the database schema initialization (either in `components/gips-db/src/lib.rs` or the relevant SQLite setup) to include a `channels` table mapping `channel_name` (TEXT PRIMARY KEY) to `gns_name` (TEXT).
2. Update `components/gips-http/src/lib.rs` to expose a `POST /link-channel` endpoint that inserts or updates a row in the `channels` table.
3. Update `gips/src/main.rs` to wire the `link-channel` command to send a request to the daemon's new endpoint.

**Allowed Files Whitelist**:

- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs`

**Enumerated Tests**:

1. Running `cargo run -p gips -- link-channel my-channel example.gnu` successfully updates the daemon.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- The command executes successfully against a running daemon.

**Commit Message**: `[stage-07] feat: implement link-channel CLI and daemon endpoint`

**Report Requirements**: Show the output of the CLI command and confirm the daemon logs the action.
