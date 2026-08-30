# Stage 19 — Input validation, resource limits, and subprocess hardening

**Motivation:** Beyond trust, the service is trivially DoS-able and has argument-injection and path-traversal exposure: no canonicalization/symlink handling on `/publish` (`is_valid_store_path` ≈`gips-http:721`, called at ≈`:154`/`:631`, + `gips-ipfs:31-36` metadata→read TOCTOU), unvalidated `gns_name`/`cid` reaching `gnunet-gns` argv (flag injection, `gips-gns:48` in `resolve`, **and `:26`/`:30` in `publish`**), unescaped LIKE wildcards + the empty-hash match on **two** code paths, log injection via un-sanitized names, no HTTP/subprocess timeouts, and unbounded in-memory reads.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. **Path safety — on BOTH the publish and the ingestion path.** Canonicalize the store path, reject symlink escape and any resolved path not under `/gnu/store/`, add a length/charset check for the store-hash format. **`is_valid_store_path` runs only on `/publish` and `create_snapshot` today — NOT on the mirror ingestion path.** `process_feed` reads `store_path` from attacker-supplied feed JSON (≈`:778-782`) and inserts it verbatim into `substitutes` (≈`:846-857`), which `get_native_narinfo` then interpolates into the Guix narinfo text (≈`:520-531`) — a response/header-injection vector since nothing strips `\n`. Apply the same validation (and newline stripping) to `process_feed`'s ingested `store_path`. Close the metadata→read TOCTOU in `gips-ipfs::add_path` (open once, fstat the handle).
2. **Name/CID validation at BOTH boundaries.** Validate `gns_name` and `ipfs_cid` against a strict charset and reject a leading `-`; pass `--` separators to `gnunet-gns` in **both** `resolve` (≈`gips-gns:48`) and `publish` (≈`:26`,`:30`); resolve `gnunet-gns`/`guile` via absolute/configured paths rather than bare `$PATH` where feasible. **Also validate the subprocess OUTPUT boundary:** `gnunet-gns` stdout is currently used raw as a manifest CID (≈`gips-gns:59-71`, `stdout_str.trim()`) and passed straight to `IpfsClient::cat`/`pin_add` — validate it against the multibase/CID charset and a length bound before use.
3. **SQL surface — fix the empty-hash bug on BOTH paths.** Escape `%`/`_` in the LIKE pattern with an `ESCAPE` clause (`let like_pattern = format!("%/{}%", hash)` ≈`:487`) and fix the empty/arbitrary-hash extraction (≈`:471-474`); switch the `.narinfo` DB lookup to exact-hash matching. **Separately**, `get_native_narinfo`'s snapshot branch does `if path.contains(hash)` (≈`:479`) — with `hash == ""` (from `GET /.narinfo`) this matches **every** entry and returns an arbitrary one by HashMap iteration order. Fix the snapshot `contains()` path too, or Stage 19 test #3 will pass on the SQL path while this one still leaks. Keep FTS `MATCH` but sanitize/limit the query language exposure.
4. **Resource limits & timeouts:** add `tower-http` `TimeoutLayer`, `DefaultBodyLimit` (tuned), and a concurrency limit; add `reqwest` connect/read timeouts + a redirect policy pin on the IPFS client; add timeouts to both subprocess calls (`gnunet-gns`, `guile`); stream or size-cap `cat`/`add` so a single large object can't OOM the daemon.
5. **Log-injection:** sanitize user-controlled fields (`store_path`, `gns_name`, `cid`) before they reach `tracing` (strip/escape newlines).
6. Rate-limit or cache `resolve_manifest_entry` so an unauthenticated `/narinfo` can't fan out into N subprocess spawns + N unbounded fetches per request.
7. **Bound remote-triggered pinning.** `process_feed` calls `state.ipfs.pin_add(&artifact_cid)` (≈`:838`) for whatever any subscribed publisher advertises, on a 60s loop, with no size/count/quota cap — an authenticated-`/pin`-bypass disk-fill (Stage 18's token does not touch this worker path). Add a per-publisher pin budget / total-quota alongside the size caps in item 4.

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs`
- `components/gips-ipfs/src/lib.rs`
- `components/gips-gns/src/lib.rs`
- `components/gips-scheme-config/src/lib.rs` (guile subprocess timeout)
- relevant `Cargo.toml` (add `tower-http`)
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. A symlink under `/gnu/store/` pointing outside is rejected by `/publish` **and** by the `process_feed` ingestion path.
2. `gns_name = "--config=/tmp/evil"` is rejected before reaching `gnunet-gns` — for both `resolve` and `publish` argv.
3. `GET /.narinfo` (empty hash) returns 404 on **both** the SQL branch and the snapshot `contains()` branch; `%`/`_` in the hash do not act as wildcards.
4. An IPFS client stubbed to hang causes a bounded timeout error, not an indefinite hang.
5. A store-path with an embedded newline does not inject a forged log line, and does not inject into the served narinfo text (assert sanitized on the ingestion path).
6. A malformed `gnunet-gns` stdout (non-CID / oversized) is rejected before reaching `cat`/`pin_add`.

**Definition of Done:** Malformed/hostile inputs are rejected at every boundary (request, ingestion, and subprocess-output); no outbound call or subprocess can hang the daemon; no unbounded read or unbounded remote-pin path remains. Gates pass.

**Commit Message:** `[stage-19] fix: path/name/CID validation (both boundaries), LIKE+snapshot empty-hash, timeouts, size+pin limits, log-injection`

**Report Requirements:** List every input now validated (request, ingestion, subprocess-output) and the limit/timeout/pin-budget values chosen.

---
