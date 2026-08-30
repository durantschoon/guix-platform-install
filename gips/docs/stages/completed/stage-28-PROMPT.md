# Stage 28 — Reindex on the spool pipeline: large legacy rows become repairable

**Motivation (measured):** Stage 27 removed the 10MB ceiling from `/publish` and `/nar`, but `/reindex` — the endpoint stage 25 built precisely to repair unusable legacy rows — still runs the buffered pre-27 pipeline. `reindex_row` calls

```rust
gips_nar::nar_and_integrity(&on_disk, STORE_DIR, gips_nar::DEFAULT_MAX_NAR_BYTES)
```

inside `spawn_blocking`, so any legacy row whose store object serializes past 10MB comes back `ReindexOutcome::TooLarge` and stays a permanent 404 — the exact condition reindex exists to fix, now inconsistent with the publish path it is supposed to mirror. Stage 25's own report also flagged that the `too_large` and `failed` outcomes have no tests. Separately, stage 27 left the `DEFAULT_MAX_NAR_BYTES` doc comment in `gips-nar` claiming it matches the `cat` ceiling "because publishing an object we could never fetch back would be a lie" — a rationale that is now stale, since the nar path fetches through the uncapped `cat_stream`.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. **`reindex_row` moves onto the stage-27 spool pipeline**, mirroring `publish_from_store` exactly: a `tempfile::Builder::prefix(...)` private temp dir per row, `gips_nar::nar_and_integrity_to_file(&on_disk, STORE_DIR, &nar_path, MAX_PUBLISH_NAR_BYTES)` (still on the blocking pool — the reason in the existing comment stands), then `state.ipfs.add_file(&nar_path)`, then the existing UPDATE. Drop the spool guard as soon as IPFS has the bytes, before the database write, as `publish_from_store` does. The `TooLarge` outcome variant stays — it now fires at `MAX_PUBLISH_NAR_BYTES` (8 GiB), same bound as publish.
2. **Keep every outcome an outcome.** The existing per-row exits (`AlreadyIndexed`, `Invalid`, `Missing`/`Pruned`, `Failed`, `TooLarge`, `Updated`) keep their meanings; the only behavioral change is *which* objects can reach `Updated`. A spool-directory creation failure is a `Failed` with a detail string, not a 500 for the whole pass.
3. **Fix the stale `DEFAULT_MAX_NAR_BYTES` doc comment** in `gips-nar`: the constant still bounds the buffered `nar_and_integrity`/`serialize_nar` convenience path and the test fixtures; it no longer describes any serving or publish ceiling. Say what is true now, one short paragraph, no behavioral change.

**Deliberate scope cuts (do not do these):** no unpinning of superseded CIDs (eviction stays ceremony per the guardrails — it has its own backlog entry), no reindex metrics counters, no Scheme binding, no pagination of the row scan (the reindex SELECT pulls only id/path/integrity columns, not `narinfo_json`; measure-first applies), and no change to the concurrent-delete `updated` misreport. If any of these turns out to be forced, that is a **Blocked** finding.

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs`
- `components/gips-nar/src/lib.rs` (doc comment of `DEFAULT_MAX_NAR_BYTES` only)
- `#[cfg(test)]` modules in the above
- member `Cargo.toml`/`Cargo.lock` only if a dev-dependency for tests is genuinely required (flag it)

**Enumerated Tests:**

1. A legacy row (no `nar_hash`) whose store object is **larger than 10MB** is repaired by `/reindex`: outcome `updated`, the new integrity columns match the object's spooled NAR exactly, and `/nar` for it then serves the full verified body (wire this through the existing fake-IPFS test server).
2. The `failed` outcome has a test: a store object that exists but cannot be serialized (e.g. an unreadable file inside the tree, or an unsupported file type such as a fifo) yields `failed` with a non-empty detail, and the row is left unmodified.
3. The `too_large` outcome has a test: with the bound made testable (e.g. a `#[cfg(test)]`-visible knob or a small-object fixture asserted against a deliberately tiny cap — executor's choice, disclosed in the report), an over-limit object yields `too_large` and leaves the row unmodified. If no honest way to test this without a test-only knob exists, say so in the report rather than shipping a vacuous test.
4. `already_indexed` rows are untouched by the new pipeline: no spool directory is created for them (assert by construction or by observation; state which).
5. The stage-27 publish/serve tests still pass unmodified (no existing test rewritten — if one must change, that is a disclosed deviation with the reason).

**Definition of Done:** All enumerated tests pass; `cargo check`, `just fmt-check`, `just test` green; `just lint` diffed against the base commit with zero new error lines (diff the sorted error list, don't compare totals); `just audit` vacuous here (note it ran); `just scheme-test` known-broken on this machine — out of scope.

**Commit Message:** `[stage-28] fix: reindex uses the spool pipeline — large legacy rows repairable, too_large/failed tested`

**Report Requirements:** State the spool lifecycle per row, how test 3 made the bound testable, which (if any) existing tests changed and why, and every whitelist deviation.

**Blocked protocol:** If mirroring `publish_from_store` forces a change to any path on the scope-cut list, or the fake-IPFS test server cannot carry a >10MB reindex round trip, STOP and report — do not substitute a smaller "representative" object for enumerated test 1 without coordinator sign-off.

---
