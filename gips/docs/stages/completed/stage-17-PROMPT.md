# Stage 17 — Fix the publish/snapshot workflow (`create_snapshot.scm` + snapshot verification)

**Motivation:** The headline `just snapshot` workflow is broken and dangerous: it embeds a hardcoded fake signature (`scripts/create_snapshot.scm:33`, which — being `"Signature: 1;example.gnu;base64..."` — actually *parses*, while the "real" signing branch at `:32` emits bare `1;name;b64` with no `Signature:` prefix and is therefore **rejected** by the verifier: real signing is strictly worse than the placeholder), it **crashes** on unbound `string-replace-substring` (`:62`) *after* pinning content, writes a predictable world-readable `manifest.json` with a TOCTOU window before publish (`:50,69`), and bypasses the daemon's validated path entirely (the `snapshot` recipe is `justfile:53-54`). Separately, snapshot mode is served with **zero** signature checking (`gipsd/src/main.rs:23-37`, consulted before trust logic in `get_narinfo` ≈`gips-http:430`, `get_native_narinfo` ≈`:477`, and `get_nar` ≈`:554`).

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. Remove the hardcoded fake-signature fallback (`:33`); require real signing (align output with the canonical `Signature:` format from Stages 15–16 — note the *genuine* signing branch is `:32`, and it currently omits the prefix). Fix the `string-replace-substring` import (`(ice-9 string-fun)`), the unescaped JSON keys (`:63`), and stop invoking signing via `cargo run` (use a stable `gips sign-*` invocation or a library boundary). **Security aspect of dropping `cargo run` (not just stability):** `cargo run` on the signing path compiles and executes whatever `build.rs`, `[patch]` directives, and `.cargo/config.toml` (`target.<triple>.runner` can substitute an entirely different binary) exist in the publisher's CWD — and the private-key path is then handed to whatever that resolves to. A stable, absolute `gips` invocation closes that.
2. Fix the temp-file TOCTOU and DoS risks: write the manifest to a size-bounded temporary directory using Rust's `tempfile` crate, ensuring the file is safely unlinked upon handle closure even during a crash. Pin *that* file.
3. **Stop discarding subprocess exit status throughout the script.** The root cause is `run-cmd-get-output` (≈`create_snapshot.scm:18-21`), which `close-pipe`s without checking status and returns trimmed stdout regardless. This corrupts more than the "Published…" message: a failed signer (`:32`) appends empty stdout as the signature line (`:34`) → a structurally valid but **unsigned** manifest; a failed `ipfs add` (`:24`) writes the error text into the manifest as `artifact_cid`. Check exit status on **every** invocation and propagate failure — do not print "Published…" when `gnunet-gns` failed (`:71-72`).
4. **Route snapshot publishing through the daemon** (or make the script reuse the exact validated code path) so `is_valid_store_path`, DB recording, real NarHash, and feed signing all apply — closing the "documented flow ≠ real flow" gap. Note this depends on Stage 16 having removed the `create_snapshot` mock-entry branch.
5. **Verify snapshots on load AND at serve time.** In `gipsd/src/main.rs`, require the snapshot manifest itself to be signed by an authorized publisher (respecting Stage 14's fail-closed default and `allow_unsigned`), and apply the same NarHash/CID verification when serving snapshot entries in **all three** snapshot branches — `get_narinfo` (≈`:430`), `get_native_narinfo` (≈`:477`, which the roadmap originally omitted), and `get_nar` (≈`:554`) — instead of trusting them blindly.
6. **Fix the `gips` CLI snapshot commands, which are pure mocks.** `gips/src/main.rs` `SnapshotCommands::Create` (≈`:190-201`) *ignores its `manifest` argument* and posts a hardcoded `vec!["/gnu/store/mock-path-1.0"]`; `List`/`Import` (≈`:202-207`) print "Not implemented yet". Yet `justfile:60-62` and `docs/offline-snapshots.md` present these as working ("the daemon will return the `snapshot_cid`"; recipients "point Guix at `http://127.0.0.1:8080`"). Either implement the real closure/CID computation or make the commands **fail loudly as unimplemented** — they must not silently publish or claim to import a fabricated snapshot. Restore invariant #1 (CLI↔REPL parity) for the security-relevant commands touched here where feasible, or document the divergence explicitly.

**Allowed Files Whitelist:**

- `scripts/create_snapshot.scm`
- `justfile`
- `gipsd/src/main.rs`
- `components/gips-http/src/lib.rs` (snapshot-serving branches — all three)
- `gips/src/main.rs` (stable sign invocation; snapshot command honesty — item 6)
- `scheme/gips/api.scm` (parity, if in scope)
- `docs/offline-snapshots.md` (align claims with the real command behavior)
- `#[cfg(test)]` / scheme test as feasible

**Enumerated Tests:**

1. `just snapshot <name> <path>` completes without the `string-replace-substring` crash and never emits the literal `1;example.gnu;base64...`.
2. A snapshot manifest with a store path containing `"`/`\` produces valid JSON.
3. `gipsd` started with an **unsigned** snapshot CID and fail-closed defaults refuses to serve its entries **from all three snapshot branches** (`get_narinfo`, `get_native_narinfo`, `get_nar`), or refuses to start — rather than serving them as trusted.
4. `gnunet-gns` failure during snapshot publish yields a non-success exit and no false "Published" message; a signer failure yields an error, not an unsigned manifest.
5. `gips snapshot create <manifest>` either uses the real `<manifest>` argument or exits non-zero as unimplemented — it does **not** post the hardcoded mock path.

**Definition of Done:** The documented publish workflow runs, produces real signatures, and is verified on load *and* on every serve branch; no fake-signature, fabricated-hash, or mock-path artifacts are produced by either the script or the CLI; snapshot mode honors the fail-closed trust default. Gates pass.

**Commit Message:** `[stage-17] fix: real signed snapshot workflow + verify snapshots on load/serve; de-mock CLI`

**Report Requirements:** Describe the final snapshot manifest schema and how snapshot signatures are verified at load and at serve time (all three branches).

---
