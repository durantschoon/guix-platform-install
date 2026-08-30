# Stage 09: Mirror Daemon Subscription Worker

**Motivation**: Plan B requires a mirror daemon that subscribes to a publisher and automatically mirrors its content. Currently, the `/subscribe` endpoint just inserts a GNS name into the DB. We need a background worker to act on those subscriptions.

**The Change**:

1. Create a new background worker task in `gipsd` (e.g., spawned in `gipsd/src/main.rs` or `components/gips-http/src/lib.rs`) that periodically polls the `subscriptions` table.
2. For each subscribed GNS name, resolve it to get the feed root CID.
3. Fetch the feed JSON from IPFS, verify its signature, and extract the `artifact_cid` and narinfo.
4. Call `state.ipfs.pin_add` on the `artifact_cid` to mirror the actual archive.
5. Insert the metadata into the local `substitutes` table so it can be served natively.

**Allowed Files Whitelist**:

- `components/gips-http/src/lib.rs`
- `gipsd/src/main.rs`
- `docs/TODO.md` (Check off the "Implement a mirror daemon that subscribes" box)

**Enumerated Tests**:

1. Daemon compiles and starts a background task successfully.
2. Inserting a fake subscription triggers the resolution logic (even if it fails due to lack of a real GNS environment).

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- Mirroring logic is robust against network failures (e.g., uses retries or continues on error).

**Commit Message**: `[stage-09] feat: implement background mirror worker for subscriptions`

**Report Requirements**: Describe how the polling interval is configured and how errors during the feed resolution are logged/handled.
