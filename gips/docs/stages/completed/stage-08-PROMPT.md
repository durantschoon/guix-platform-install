# Stage 08: Publisher Feed Writer (Plan B)

**Motivation**: To begin Plan B (Federated Mirror & Index Network), we need a publisher feed model. Every time a new substitute is published, `gipsd` should write a signed IPLD feed block to IPFS and update its GNS record to point to this new root block.

**The Change**:

1. Update `components/gips-ipfs/src/lib.rs` to include a method for adding raw JSON/bytes (e.g., `add_bytes(&self, data: &[u8]) -> Result<String>`).
2. Update the `publish_substitute` handler in `components/gips-http/src/lib.rs` to construct a minimal feed JSON object containing the `store_path`, `ipfs_cid`, and a timestamp.
3. Sign this feed JSON (using `gips_trust` and the configured publisher keys), write the feed object to IPFS, and then publish the *feed's* CID to GNS instead of the raw `narinfo` JSON.

**Allowed Files Whitelist**:

- `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `docs/TODO.md` (Check off the "Implement a minimal publisher feed writer" box)

**Enumerated Tests**:

1. Calling `/publish` returns the CID of the *feed object*, not just the file payload.
2. The GNS record is successfully updated with the feed CID.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- Architecture cleanly separates the feed logic from the basic narinfo generation.

**Commit Message**: `[stage-08] feat: implement publisher feed writer for Plan B`

**Report Requirements**: Provide a sample JSON of the feed object structure being created and written to IPFS.
