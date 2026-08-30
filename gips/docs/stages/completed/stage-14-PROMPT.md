# Stage 14 — Fail-closed trust and correct publisher binding

**Motivation:** The single most dangerous defect. Empty `trusted_publishers` currently means *accept everything* (`fn resolve_manifest_entry` ≈`gips-http:356`, `fn process_feed` ≈`gips-http:802` — both `let mut is_trusted = state.config.trust.trusted_publishers.is_empty();`), inverting Guix's fail-closed ACL. Worse, when trust *is* configured, the publisher key is selected using the GNS name taken from **inside the untrusted signature line** (`let pub_name = parts[1]` ≈`gips-http:373-382`), and `resolve_manifest_entry` iterates *all* subscriptions without requiring the signer to match the name the manifest came from — so publisher A's key validates content served under publisher B's name.

> **Anchor by `fn` name + quoted code, not line number** — the file drifts every stage.

> **Two parsers, two wire formats — READ THIS.** `resolve_manifest_entry` parses a *fat* `HashMap<String, ManifestEntry>` manifest (the shape `scripts/create_snapshot.scm` produces). `process_feed` parses a *flat* feed object (`{store_path, ipfs_cid, timestamp, signature}` — the shape `/publish` produces). They are reached from the **same** GNS name, so a feed published by GIPS itself can never be read by `resolve_manifest_entry`, and vice-versa. **This stage must fix the fail-open default and binding in BOTH functions**, and every change below must state which parser it targets. `resolve_manifest_entry` is the fail-open one reachable from an unauthenticated `GET /narinfo`; treat it as the priority. (Unifying the two formats is Stage 15 item 1.)

**The Change:**

1. **Invert the default to fail-closed in BOTH parsers.** Replace `is_trusted = trusted_publishers.is_empty()` with `is_trusted = false` in `resolve_manifest_entry` (≈`:356`) **and** `process_feed` (≈`:802`). An empty trust list ⇒ *nothing* is accepted from the network.
2. Add an explicit, clearly-named escape hatch **off by default**: `trust.allow_unsigned: bool` (default `false`) in `TrustConfig`. When `true`, log a prominent startup warning and per-request warnings. This is the *only* way to restore old behavior, and it is loud.
3. **Bind the signer to the fetch source.** In `resolve_manifest_entry`, require that the publisher whose key verifies the signature is the *same* `gns_name` the manifest was resolved from — do not trust `parts[1]` from the signature to *select* the key; use it only as a consistency check that must equal the resolved name. (Mirror the stricter binding `process_feed` already does at ≈`:808-814`, `.find(|p| p.gns_name == gns_name)`.)
4. Make `verify_narinfo` distinguish "malformed" from "bad signature" for internal logging (return a typed error/enum) without leaking detail to clients; return a uniform `404 Not Found` for both genuine misses and untrusted signatures to prevent leaking storage state to HTTP requesters.
5. Harden canonicalization: define one canonical narinfo body form (sorted, `\n`-terminated, `Signature:`/`Sig:` line excluded) in `gips-trust` and use it on both sign and verify sides so restructuring can't preserve a signature. **Explicitly reject multiple `Signature:` lines** (today the verifier excludes *all* of them from the body but keeps only the last as the checked signature, so an attacker can append a second signature line for free), **require exactly one** signature line, and **normalize/forbid CRLF** so a CRLF-signed body cannot verify as LF (or vice-versa).
6. **Make security logs visible by default.** `gipsd/src/main.rs` initializes tracing with `EnvFilter::from_default_env()` and **no fallback** — with `RUST_LOG` unset this emits *nothing at any level*, so the fail-closed rejection logs and the `allow_unsigned` warning (and Stage 14 test #4) are invisible on a default install. Change to `EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))` (or equivalent).

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs`
- `components/gips-trust/src/lib.rs`
- `bases/gips-config/src/lib.rs` (only if `allow_unsigned` plumbing needs a field; trust lives in `gips-trust`)
- `gipsd/src/main.rs` (EnvFilter default only — item 6)
- `docs/architecture.md` (add the `http --> trust` edge + note fail-closed default)
- `#[cfg(test)]` modules in the above

**Enumerated Tests:**

1. With empty `trusted_publishers` and `allow_unsigned=false`, a `/narinfo` and `/nar` request that can only be satisfied via a subscription returns 404/untrusted — **not** the content. (Assert on the `resolve_manifest_entry` path.)
2. A manifest whose signature verifies under publisher A's key but is served under subscription B is **rejected**.
3. A correctly-signed manifest from an authorized publisher is accepted.
4. `allow_unsigned=true` restores acceptance and emits the warning (assert via a captured log/side channel — this requires item 6's EnvFilter default to be in place).
5. Canonicalization: reordering non-signature lines invalidates the signature; a body carrying **two** `Signature:` lines is rejected, not accepted-on-the-last.
6. The **flat-feed** path (`process_feed`) also rejects everything under an empty trust list (regression-guard the second parser explicitly).

**Definition of Done:** Default install accepts nothing from the network without an authorized, correctly-bound signature — in *both* the manifest and feed parsers; security logs are visible by default; `cargo test`/`fmt`/audit gates pass; architecture doc reflects the wired trust edge and the fail-closed default.

**Commit Message:** `[stage-14] fix: fail-closed trust default and correct publisher-key binding (both parsers)`

**Report Requirements:** State the exact new default trust decision truth-table (config × signature × binding → accept/reject), and confirm the truth-table holds for both `resolve_manifest_entry` and `process_feed`.

---
