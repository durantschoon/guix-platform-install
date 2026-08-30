# Stage 25 — `gips reindex`: backfill integrity for legacy rows

**Motivation (measured, not hypothetical):** Stage 16 made every serving
route refuse a `substitutes` row that carries no usable integrity triple
(`resolve_verified_target` returns `None`; `get_native_narinfo` 404s; see
the stage 16 tests `legacy_row_without_hash_is_unknown_not_fabricated`).
That is the correct fail-closed outcome, but it left operators with no
recovery path: a row published before stage 16 is a permanent 404 unless
the operator manually re-publishes each store path. The stage 16 report
named `gips reindex` as the natural follow-up. This stage builds it.

> **Anchor by `fn` name + quoted code, not line number.** The publish
> pipeline to mirror is `publish_substitute` (`gips-http`): it calls
> `gips_nar::nar_and_integrity(...)`, uploads with
> `state.ipfs.add_bytes(&nar_bytes)`, and records the row with
> `StoredNarinfo::new` plus the `nar_hash`/`nar_size`/`nar_references`
> columns in one INSERT. Reindex must produce rows of exactly that shape.

**The Change:**

1. **New authenticated endpoint `POST /reindex`** on the *mutating*
   sub-router in `build_router` (`gips-http`), so it is behind the stage
   18 token layer by construction. Request body: optional
   `{"prune_missing": bool}` (default `false`), optional
   `{"store_paths": [..]}` to limit scope (absent = all legacy rows).
2. **For each `substitutes` row lacking a usable integrity triple** (the
   same predicate the serving path uses — reuse `integrity_from_row`,
   do not invent a second definition):
   - Validate the row's `store_path` with `is_valid_store_path` before
     touching the filesystem; a malformed row is reported `invalid`.
   - If the path exists on disk: serialize with
     `gips_nar::nar_and_integrity(path, STORE_DIR,
     DEFAULT_MAX_NAR_BYTES)`, upload the nar bytes via `add_bytes`,
     and UPDATE the row in place: new `ipfs_cid`, rewritten
     `narinfo_json` (a real `StoredNarinfo`), and the three integrity
     columns. Outcome: `updated`. Note the legacy CID pointed at raw
     file bytes, not a nar, so the CID must change.
   - If serialization exceeds the ceiling: outcome `too_large`, row
     untouched (it stays an honest 404).
   - If the path is absent on disk: outcome `missing`. With
     `prune_missing = false` the row is left untouched. With
     `prune_missing = true` the row is DELETEd and reported `pruned`.
     Eviction stays ceremony: it never happens without the explicit
     flag.
3. **Rows that already carry integrity are skipped** — outcome
   `already_indexed`, and nothing is uploaded to IPFS for them.
4. **Response** is a JSON report: per-path outcome plus totals, so a
   second run over the same DB reports zero `updated` (idempotence).
5. **New CLI subcommand `gips reindex`** (`gips/src/main.rs`) with
   `--prune-missing` and repeatable `--store-path` flags, sending the
   auth token via the existing `post_authorized` helper and printing
   the outcome report.
6. **Feeds are NOT rewritten.** Published feed history is append-only;
   reindex repairs local serving only. Document this in the endpoint's
   doc comment. Subscribers pick up entries through normal publishes.

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs` (endpoint, report types)
- `gips/src/main.rs` (subcommand)
- `components/gips-db/src/lib.rs` (only if a query helper is needed)
- member `Cargo.toml`/`Cargo.lock` for whitelisted deps and test
  dev-deps (per the stages 16–20 retro)
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. A legacy row (NULL integrity) whose store path exists on disk:
   `POST /reindex` marks it `updated`; the row then serves — the
   native narinfo route returns 200 with the real `NarHash`, and the
   recorded CID matches the uploaded nar bytes.
2. A legacy row whose store path does not exist: outcome `missing`,
   row still present, still 404 on the serving path. No DELETE without
   the flag.
3. Same row with `prune_missing: true`: outcome `pruned`, row gone.
4. `POST /reindex` without the token is 401; the CLI round-trips with
   the on-disk token (mirror the stage 18 CLI test pattern).
5. A row that already has integrity: outcome `already_indexed`, and
   the fake-IPFS request counter shows nothing was uploaded for it.
   A second full `POST /reindex` reports zero `updated` (idempotent).

**Definition of Done:** Legacy rows are recoverable without manual
re-publishing; nothing is evicted without the explicit flag; skipped
and failed paths are reported honestly; the serving-path integrity
predicate has exactly one definition. Gates pass: `cargo check`,
`just fmt-check`, `just test`; `just lint` error count unchanged vs
base (422 on this environment).

**Commit Message:**
`[stage-25] feat: gips reindex — backfill real integrity for legacy substitute rows`

**Report Requirements:** The outcome matrix (updated / missing /
pruned / too_large / invalid / already_indexed) with the exact JSON
shape, confirmation that a reindexed row's URL/CID now names nar
bytes, and any limits discovered (e.g. behavior under concurrent
publishes).

**Status:** Ready to be claimed.
