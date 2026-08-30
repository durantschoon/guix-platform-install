# Stage 03: Pin and Unpin CLI Stubs

**Motivation**: According to `docs/TODO.md` (Plan A), we need to flesh out `pin` and `unpin` CLI commands now that the daemon foundations are laid.

**The Change**:

1. Update `gips/src/main.rs` to parse `pin <cid>` and `unpin <cid>` subcommands.
2. Update `components/gips-http/src/lib.rs` to expose `POST /pin` and `POST /unpin` endpoints.
3. Wire the CLI commands to send HTTP requests to these new daemon endpoints.
4. *Note: The daemon endpoints can just print a log and return 200 OK for now; deep IPFS integration for pinning existing CIDs can be a follow-up.*

**Allowed Files Whitelist**:

- `gips/src/main.rs`
- `components/gips-http/src/lib.rs`

**Enumerated Tests**:

1. Running `cargo run -p gips -- pin Qm123` executes without crashing.
2. The daemon logs the pin request.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- CLI subcommands are documented in `--help`.

**Commit Message**: `[stage-03] feat: add pin and unpin CLI and HTTP stubs`

**Report Requirements**: Show the output of `cargo run -p gips -- help` confirming the new subcommands exist.
