# Stage 16 — Real NarHash: content integrity end to end

**Motivation:** The served narinfo lies about integrity (`get_native_narinfo` emits `NarHash: sha256:000…0`, `NarSize: 0`, empty `References:` at ≈`gips-http:520-531`; `create_snapshot.scm:29` emits the same fake `NarHash` — note it pairs it with `NarSize: 1234`, not `0`). A CID guarantees bytes match the CID, not that the bytes are the store object Guix expects. Real safety requires a Guix-format `NarHash` in the signed body, verified against the downloaded bytes before serving.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. Implement nar serialization + `sha256` hashing of the store object at publish time (a new `gips-nar` component, or a module in `gips-ipfs`), producing the Guix `NarHash: sha256:<nix-base32>` and accurate `NarSize`. Populate `References:` from the store object's closure (at minimum, stop emitting a false empty value; compute references where the store layout allows, else record honestly as "unknown" and document the limit).
2. Include `NarHash`/`NarSize` in the **signed** body (extending Stage 15's unified schema).
3. On fetch, recompute `NarHash` over the delivered bytes and **reject on mismatch** before serving — the real content-integrity gate.
4. Replace the fabricated placeholders in `get_native_narinfo` (≈`gips-http:520-531`) with the real values; if unknown (e.g. legacy DB rows without a hash), return 404/`unknown` rather than serving zeros.
5. **Delete the `create_snapshot` fabrication branch.** `fn create_snapshot` (≈`gips-http:664-677`) has a "mock behavior: if DB is empty, use a dummy entry" branch that inserts `artifact_cid: "QmDummyArtifactCidForMocking"` and a synthetic narinfo for **any store path the caller names**, then signs/pins the resulting manifest. Combined with the unauthenticated route (Stage 18) and unsigned snapshot loading (Stage 17), this is a live substitute-forgery primitive. Remove the mock branch entirely: a store path with no real DB-backed artifact must yield an error, never a fabricated entry.

**Allowed Files Whitelist:**

- `components/gips-nar/` (new component: nar serialize + hash) **or** `components/gips-ipfs/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `components/gips-trust/src/lib.rs`
- `components/gips-db/src/lib.rs` (store `narhash`/`narsize` columns; migration)
- root/member `Cargo.toml` if a new crate is added
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. Round-trip: serialize a known small store fixture, hash it, and assert the `NarHash` matches the value Guix would compute (golden vector).
2. Delivered bytes tampered by one byte ⇒ `get_nar` rejects on NarHash mismatch.
3. Served narinfo no longer contains `sha256:000…0`, and no `NarSize: 0` **or** `NarSize: 1234` placeholder, for a freshly published object.
4. A legacy row lacking a hash yields 404/unknown, never fabricated zeros.
5. `POST /snapshot/create` for a store path with no real artifact returns an error and does **not** produce a `QmDummy...` manifest entry.

**Definition of Done:** Every served substitute carries a real, signed `NarHash`, verified against bytes before serving; no fabricated integrity fields remain on the live path; the snapshot-mock forgery branch is gone. Gates pass.

**Commit Message:** `[stage-16] feat: real NarHash serialization + content verification on fetch; remove snapshot mock branch`

**Report Requirements:** State the nar-serialization approach used, the golden test vector source, and any closure/`References` limitation being documented.

---
