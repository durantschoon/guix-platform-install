# Stage 27 — Streaming NAR serve + publish: remove the 10MB ceiling

**Motivation (measured):** Any store object over 10MB cannot pass through GIPS today, which rules out most real closures (glibc, gcc, browsers). Three code sites impose the ceiling:

1. `gips_ipfs::IpfsClient::cat` buffers the entire object and bails at `10 * 1024 * 1024` twice (Content-Length pre-check and mid-stream re-check) — the quoted guard is `if bytes.len() + chunk.len() > 10 * 1024 * 1024`.
2. `gips_nar::serialize_nar(root, max_bytes)` builds the whole NAR in a `Vec<u8>` and `check_size` errors past `DEFAULT_MAX_NAR_BYTES: u64 = 10 * 1024 * 1024`, so `publish_substitute` returns `PAYLOAD_TOO_LARGE` for big paths.
3. `fetch_verified_nar` in `gips-http` fetches the full body into memory, verifies, then serves — O(NarSize) RAM per concurrent request even when under the cap.

The stage-19 DoS bounds must survive this change: the fix is not "raise the cap", it is "bound each fetch by its own signed size record and stop buffering".

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. **`gips-nar` — sink-generic serialization.** Refactor `write_node` (and `check_size`) to write into a generic `std::io::Write` sink with a running byte count, instead of appending to a `Vec<u8>`. Keep the existing public API `serialize_nar(root, max_bytes) -> Result<Vec<u8>, NarError>` and `nar_and_integrity(...)` as thin wrappers over the sink version — every existing caller and test must compile unchanged. Add a spooling variant (suggested name `nar_and_integrity_to_file(root, store_dir, sink_path, max_bytes)`) that streams the NAR to a file while computing `NarIntegrity` (hash + size + references) in the same single pass — O(disk), not O(RAM). `DEFAULT_MAX_NAR_BYTES` stays defined, but see item 4 for the new publish bound.
2. **`gips-ipfs` — streaming cat, streaming add.**
   - Add `cat_stream(&self, cid) -> Result<impl Stream<Item = reqwest::Result<bytes::Bytes>>>` (shape may differ; the point is chunks, no accumulation, no blanket cap). **Do not remove or uncap the existing `cat`** — `process_feed` and `resolve_manifest_entry` still fetch feeds/manifests through it and its 10MB bound is a deliberate stage-19 protection.
   - Add a file-backed add (suggested `add_file(&self, path)`) using a streamed multipart body (`reqwest::Body::wrap_stream` over a `tokio::fs::File`/`ReaderStream`), so publishing never holds the NAR in memory. `add_bytes` stays for small callers (feeds, manifests, snapshots).
3. **`gips-http` — verify-while-streaming serve path.** Replace the body construction in `get_nar` and `get_native_nar` (both currently `fetch_verified_nar(...)` → `Body::from(bytes)`) with a streaming responder with these exact semantics:
   - **NarSize is enforced exactly**: the response declares `Content-Length: <integrity.nar_size>`; the stream aborts with an error the moment cumulative bytes would exceed `nar_size`, and a stream that ends short of `nar_size` is a failure (counted in `nar_rejected`), never a padded or silently-short success.
   - **NarHash gates completion**: hash incrementally as chunks pass through, and **hold back the final chunk** until the full-body hash has been checked against `integrity.nar_hash`. On match, release the final chunk (response completes at exactly Content-Length). On mismatch, drop the connection short of Content-Length and increment `nar_rejected` — a client can then never observe a byte-complete response whose body was not hash-verified. Guix independently recomputes NarHash client-side; this invariant keeps GIPS's own "no unverified complete response" guarantee without buffering.
   - Keep the `nar_fetch_ipfs` / `nar_verify` metrics split as close to its current meaning as streaming allows; if the two phases genuinely fuse, say so in the report rather than inventing a fake split.
   - **On the CID re-check**: `IpfsClient::verify_bytes_against_cid` compares sha256(bytes) against the CID multihash, which is only sound for single-block objects (kubo chunks larger adds into a DAG whose root hash is not the content hash) — it cannot be applied to the streamed path and the signed `NarHash`/`NarSize` record is the authoritative gate there. Leave the buffered paths that still use it untouched, and record in the report what you observed about its validity for multi-block objects (disclose, don't silently fix).
4. **`gips-http` — streaming publish path.** `publish_substitute` currently calls `nar_and_integrity(..., DEFAULT_MAX_NAR_BYTES)` then `add_bytes`. Switch it to the spool-to-temp-file + `add_file` pipeline (temp file in a private temp dir, cleaned up on every exit path). Replace the 10MB bound with a named sanity constant `MAX_PUBLISH_NAR_BYTES` of **8 GiB** — a guard against runaway serialization, not a product limit. No new config field (that is a deliberate scope cut; a config knob is a future stage if anyone asks).
5. **Untouched on purpose:** `process_feed`, pin budgets, `create_snapshot`/`add_path`, the `/reindex` path, and the capped `cat`. If any of them turns out to need modification to compile, that is a **Blocked** finding.

**Ground rules:** Dependencies: `futures-util` is already in `gips-ipfs`; you may add `tokio-util` (for `ReaderStream`) and enable needed `tokio`/`reqwest` features in member `Cargo.toml`s — nothing else new. No schema changes, no new endpoints, no config fields. No `git push` — the coordinator pushes.

**Allowed Files Whitelist:**

- `components/gips-nar/src/lib.rs`
- `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `#[cfg(test)]` modules in the above
- member `Cargo.toml`/`Cargo.lock` for the dependencies named in Ground rules and dev-deps of tests

**Enumerated Tests:**

1. (gips-nar) The sink-based serializer produces **byte-identical** output to the buffered `serialize_nar` on the existing golden fixtures (file / dir / symlink), and the spooling variant's `NarIntegrity` (hash, size, references) equals the buffered one's.
2. (gips-http) `/publish` of a synthetic store object **larger than 10MB** (e.g. a ~12MB file in a temp store dir) succeeds — no `PAYLOAD_TOO_LARGE` — and the recorded `nar_size` matches the spooled NAR exactly.
3. (gips-http) `/nar` for a >10MB object (stub IPFS) returns 200 with `Content-Length == nar_size` and a body whose hash equals the recorded NarHash, delivered without any single allocation holding the whole NAR (structure the responder so this is true by construction; assert what is assertable — length and hash).
4. (gips-http) Stub IPFS serving bytes whose hash does **not** match the recorded NarHash: the client observes a connection/body error short of Content-Length (never a byte-complete 200 body), and `nar_rejected` increments.
5. (gips-http) Stub IPFS serving **more** bytes than `nar_size`: the stream aborts at the size bound (no unbounded read), and `nar_rejected` increments. A stream ending **short** of `nar_size` is likewise a counted failure.
6. (gips-http) The feed-ingestion path still refuses oversized feeds: a stubbed >10MB feed body still fails `process_feed`'s fetch (the capped `cat` is intact).

**Definition of Done:** All enumerated tests pass; `cargo check`, `just fmt-check`, `just test` green; `just lint` diffed against the base commit with zero new error lines (the baseline is 440 error lines on this machine — diff the list, don't compare totals); `just audit` vacuous here (note it ran); `just scheme-test` known-broken (guile-gcrypt absent) — out of scope.

**Commit Message:** `[stage-27] feat: stream NAR serve+publish — NarSize-exact bounds replace the 10MB ceiling`

**Report Requirements:** State the final streaming semantics (chunk size, where the held-back final chunk lives, what happens on each failure mode), the observed validity of `verify_bytes_against_cid` for multi-block objects, the temp-file lifecycle on the publish path, and every whitelist deviation.

**Blocked protocol:** If the hold-back-final-chunk invariant cannot be implemented with axum's `Body::from_stream` (or the pinned axum version lacks what's needed), or any deliberately-untouched path must change to compile, STOP and report — do not weaken the "no byte-complete unverified response" guarantee or uncap the feed path without coordinator sign-off.

---
