# Stage 04: IPFS Pin and Unpin Operations

**Motivation**: Stage 03 added the HTTP stubs for the `/pin` and `/unpin` daemon endpoints. To fulfill Plan A's requirement of deep IPFS integration, the daemon needs to actually communicate with the IPFS node to pin and unpin these CIDs.

**The Change**:

1. Update `components/gips-ipfs/src/lib.rs` to implement `pin_add(&self, cid: &str)` and `pin_rm(&self, cid: &str)` methods on `IpfsClient`. These should call out to the IPFS HTTP API (`/api/v0/pin/add` and `/api/v0/pin/rm`).
2. Update `components/gips-http/src/lib.rs`'s `pin_cid` and `unpin_cid` route handlers to call these new IPFS methods. Return an error (e.g. `502 Bad Gateway`) if the IPFS daemon fails.

**Allowed Files Whitelist**:

- `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`

**Enumerated Tests**:

1. Running `cargo check` and `cargo test` succeeds.
2. If IPFS is running locally, posting a valid CID to `/pin` succeeds.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- IPFS API calls are correctly structured and errors are handled.

**Commit Message**: `[stage-04] feat: implement IPFS pin and unpin operations`

**Report Requirements**: Describe how you implemented the `pin_add` and `pin_rm` methods and any challenges with the reqwest integration.
