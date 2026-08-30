# Stage 15 — Bind the signature to the content it delivers

**Motivation:** Even with fail-closed trust, the signature binds a narinfo body while the download uses an unsigned sibling `artifact_cid` (verified in `resolve_manifest_entry` ≈`gips-http:358-408`: the signature covers `entry.narinfo` only; `entry.artifact_cid` is returned at ≈`:408` and consumed by `get_nar` at ≈`:580`, never signed), and the two signing schemes are mutually incompatible (signer emits bare `1;name;b64` at `gips-trust:45` while the verifier requires a `Signature:` prefix at ≈`gips-http:363` — the audit's "real signing never validates" finding). This stage makes the signature actually cover the artifact and adds first-order content integrity (bytes match their CID) plus replay protection.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. **Unify the wire format, then put the artifact CID inside the signed body.** First resolve the two-parser split flagged in Stage 14: `resolve_manifest_entry` (fat `HashMap<String,ManifestEntry>`) and `process_feed` (flat `{store_path,ipfs_cid,timestamp,signature}`) must agree on **one** signed-body format and **one** `Signature:`/`Sig:` field name, used by `publish_substitute` (`/publish`, signing block ≈`gips-http:204-224`), the snapshot signer (Stage 17), and both verifiers. Reject any manifest/feed where the delivered `artifact_cid` is not the one covered by the signature. **State in the report which parser was made canonical and how the other was migrated.**
2. **Verify IPFS bytes against their CID before serving.** In `get_nar`/`get_native_nar`, after `ipfs.cat(cid)`, recompute the CID's multihash over the returned bytes and refuse to serve on mismatch (defends against a hostile `ipfs_api`/gateway). (Full Guix `NarHash` binding is Stage 16; this is the CID-level guarantee.)
3. **Replay/rollback protection & Causal Consistency (TLA+ Verified).** Introduce a Merkle DAG structure by including a `previous_cid` field in the feed. Mirrors **must not** update their tip until they have verified and successfully fetched all causal ancestors. Our TLA+ model mathematically proved that relying on monotonic timestamps fails eventual consistency due to out-of-order packet delivery, whereas the Merkle DAG approach safely enforces causal ordering. **Do not treat a missing/absent timestamp as "epoch, therefore oldest"** — both `/publish` (≈`:193-196`) and `process_feed` (≈`:793-796`) currently `unwrap_or_default()` a timestamp to `0`, so a feed that simply omits the field produces a well-formed signed body over `Timestamp: 0`. A missing or non-monotonic timestamp/`previous_cid` must be an explicit **reject**, not a silent zero.
4. Fix `/publish`'s fail-open signing side effects: if signing is *configured* but the key can't be read or signing fails (key-read failure is swallowed at ≈`:220-222`, sign failure at ≈`:218-219`, then it falls through and publishes unsigned), **return an error** instead of publishing unsigned; and never publish an empty feed on `to_vec` failure (`let feed_bytes = serde_json::to_vec(&feed_json).unwrap_or_default();` ≈`:226` publishes an empty `[]` body on serialization failure — make it a hard error).

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs`
- `components/gips-trust/src/lib.rs`
- `components/gips-ipfs/src/lib.rs` (add a CID-verify helper; optionally a streaming/size-capped `cat`)
- `components/gips-db/src/lib.rs` (add per-publisher last-timestamp / last-`previous_cid` storage)
- `#[cfg(test)]` modules in the above

**Enumerated Tests:**

1. A manifest whose signed body covers CID `X` but whose `artifact_cid` field is swapped to `Y` is rejected — in the unified parser.
2. Bytes returned by a stubbed IPFS client that don't hash to the requested CID cause `get_nar` to refuse (not 200).
3. A feed with a timestamp older than the last-seen for that publisher is rejected as a replay; **a feed that omits the timestamp entirely is also rejected** (not accepted as `Timestamp: 0`).
4. **TLA+ Causal Consistency Test:** A feed update arrives out-of-order (missing its `previous_cid` in local storage). The mirror correctly suspends tip advancement, fetches the missing ancestor, and only then applies both updates in causal order, preventing data loss.
5. `/publish` with signing configured but an unreadable key returns 5xx and does **not** publish an unsigned feed; a `to_vec` failure does **not** publish an empty `[]` feed.

**Definition of Done:** The signature demonstrably covers the delivered artifact through **one** unified wire format; content that doesn't match its CID is never served; stale/missing-timestamp feeds are rejected; signing is fail-closed on the publish path. Gates pass.

**Commit Message:** `[stage-15] fix: unify wire format, bind signature to artifact CID, verify bytes-vs-CID, replay protection`

**Report Requirements:** Document the final canonical signed-body schema (field order, delimiters), and state which of the two parsers was made canonical and how the other was migrated to it.

---
