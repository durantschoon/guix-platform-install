# Stage 06: Native Guix Nar Endpoint and Format Update

**Motivation**: Building upon Stage 05, Guix clients not only need `/:hash.narinfo` but also expect the returned payload to be in the native Guix narinfo text format (not JSON). They then fetch the actual archive via the path specified in the `URL:` field, commonly `GET /nar/<hash>-<name>` or similar.

**The Change**:

1. Update `publish_substitute` in `components/gips-http/src/lib.rs` to construct a native Guix narinfo text block instead of JSON (or map the JSON to text when serving). The narinfo should include `StorePath`, `URL` (pointing to our `/nar/<cid>` endpoint), `Compression: none`, and `NarHash`.
2. Update `components/gips-http/src/lib.rs` to add a new route `.route("/nar/:cid", get(get_native_nar))`.
3. The `get_native_nar` handler should extract the `:cid` parameter, fetch the raw bytes from IPFS (using `state.ipfs.cat(&cid)`), and serve it with the `application/x-nix-archive` content type.

**Allowed Files Whitelist**:

- `components/gips-http/src/lib.rs`

**Enumerated Tests**:

1. Requesting the `.narinfo` endpoint returns a plain-text payload formatted with `StorePath: ...` and `URL: nar/...`.
2. Requesting the returned `/nar/<cid>` URL successfully fetches the IPFS data and serves it as an archive.

**Definition of Done**:

- `cargo check` and `cargo fmt --check` pass.
- Endpoints return data that resembles what a standard Guix client expects.

**Commit Message**: `[stage-06] feat: implement native Guix nar serving and text narinfos`

**Report Requirements**: Show a curl of the new `.narinfo` endpoint demonstrating the standard Guix text format, and briefly explain how the `/nar/` routing maps to the IPFS CID.
