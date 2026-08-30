<!-- markdownlint-disable MD013 -->

# GIPS Security Hardening Roadmap — Staged Plan

> **Status: historical record — executed and closed.** Stages 13–21 all
> merged (2026-08-17); stage 23 remains design-only (`docs/trust-economics.md`);
> stage 22 was later expanded into stages 29–30 and merged (2026-08-18) — see
> `docs/stages/completed/stage-22-SKETCH-expanded-into-29-30.md`. Each
> `## Stage NN` block below is preserved as authored (the archived prompt
> files in `docs/stages/completed/` are the source of truth); line numbers
> and "current behavior" claims describe the pre-hardening tree, not today's.

## Context

**Why this work exists.** GIPS advertises itself (README, `docs/jargon.md`, `docs/user_guide.md`, `docs/federation.md`) as a *censorship-resistant, signature-anchored, trust-based* peer-to-peer substitute network. Two independent audits of the current tree found that essentially every path that would connect that promise to real user safety is fail-open, stubbed with placeholder values, or broken. A third final sweep (folded into the prompts below) found additional gaps the first two missed. The goal of this roadmap is to make GIPS genuinely trustworthy **within clearly stated limits** — and to state those limits — so a user can both trust it and *want* to.

**The load-bearing gap.** Guix's substitute model is fail-**closed**: an empty authorization list means *accept nothing*, and a signature transitively binds the actual bytes via `NarHash`. GIPS inverts this. Concretely, from the audits (line numbers drift every stage — anchor by `fn` name + quoted code):

- **Verification fails open by default.** `resolve_manifest_entry` (≈`components/gips-http/src/lib.rs:356`) and `process_feed` (≈`:802`): `let mut is_trusted = state.config.trust.trusted_publishers.is_empty();` — the default (empty) trust list ⇒ *everything* is accepted, no signature checked. These are **two separate parsers with two incompatible wire formats** (fat manifest vs. flat feed); both must be fixed.
- **The signature does not bind the downloaded content.** The verified body is derived from `entry.narinfo`, but the CID actually fetched is `entry.artifact_cid`, a sibling field that is never signed (verify block ≈`:358-408`, artifact returned ≈`:408`, consumed by `get_nar` ≈`:580`) → complete signature bypass even when trust is configured.
- **Fabricated integrity metadata.** Served narinfo carries `NarHash: sha256:000…0`, `NarSize: 0`, empty `References:`, empty `Sig:` (`get_native_narinfo` ≈`:520-531`). No content integrity check exists anywhere in GIPS.
- **Real signing never validates.** The signer emits `1;name;b64` (`gips-trust/src/lib.rs:45`) while the verifier requires a `Signature:` prefix (≈`gips-http:363`); and the documented `just snapshot` embeds a hardcoded fake signature (`scripts/create_snapshot.scm:33`) and crashes on an unbound `string-replace-substring` (`:62`).
- **No authentication** on `/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, **or `/snapshot/create`** (the last was missing from the original endpoint list, and its handler *fabricates* trusted-looking entries for arbitrary store paths); `scheme/README.md:74` demonstrates binding `0.0.0.0`. `/nar/:cid` is an open IPFS proxy.
- **DoS/robustness holes:** unbounded in-memory reads of store files and arbitrary IPFS objects, unbounded remote-triggered pinning, no HTTP timeouts, no subprocess timeouts, silent cwd fallback for **both** the DB *and* the config file (attacker-plantable → RCE), argument-injection into `gnunet-gns`/`guile` via unvalidated names (on multiple call sites and on subprocess *output*), `sqlx 0.7.4` (RUSTSEC-2024-0363), and **zero tests**. (`ed25519-dalek` is already 2.2.0 — RUSTSEC-2022-0093 does **not** apply; sqlx is the only real advisory.)
- **The pipeline is itself a trust boundary:** stage prompts, `.agents/rules/*`, and `justfile` arrive over the unauthenticated `rad` remote and are executed by tool-enabled agents, and the verification gates run unreviewed branch code before the diff is audited.

**Chosen direction:**

1. **Phased crypto** — harden the existing `ed25519-dalek`/PKCS#8 scheme now and *document plainly that GIPS is not yet a drop-in Guix keyring*; defer true Guix-compatible (guile-gcrypt canonical-sexp) signatures to a later stage.
2. **Fail-closed, breaking changes acceptable** — empty trust list ⇒ deny (both parsers); refuse non-loopback bind unless explicitly opted in; remove the silent cwd DB *and* config fallbacks; require a local auth token for all mutating endpoints.
3. **Real content integrity** — compute a real `NarHash`, put it in the signed body, and verify fetched bytes before serving.
4. **Comprehensive roadmap** — sequenced stages covering crypto/trust, auth, validation, DoS, config/fs integrity, docs/threat-model, and a security test suite.

**Intended outcome.** A daemon that, by default, accepts only signed substitutes from explicitly authorized publishers; binds signatures to verifiable content; refuses to expose itself unauthenticated; and ships with an honest `SECURITY.md` + threat model that states exactly what it does and does not protect against.

---

## How this plan is organized

The repo already uses a numbered **stage pipeline** (`docs/stages/`, format: *Motivation / The Change / Allowed Files Whitelist / Enumerated Tests / Definition of Done / Commit Message / Report Requirements*), executed one stage at a time by a `stage-executor` subagent in an isolated worktree, with the coordinator running verification gates before merge (`docs/stages/README.md`).

- Last completed stage: **12**. Stage **11** (offline snapshots) is an unrelated *pending* feature; these security stages are numbered **13–23** to avoid collision. Stages 22–23 are explicitly **deferred** (the Guix-compat crypto rewrite, and the federated-membership design).
- Each stage below is mirrored verbatim in `docs/stages/stage-NN-PROMPT.md`. **Anchor every code change by `fn` name + quoted snippet, not by line number** — `components/gips-http/src/lib.rs` is ~862 lines and drifts ~15–90 lines per stage.
- **Ordering is dependency-driven.** Stage 13 (test harness + gates) comes first so every later stage lands with regression tests and a security review gate. Crypto/trust core (14→15→16) progresses fail-closed → bind-CID → bind-real-hash. Then auth/DoS/config surface (17→20), then docs/threat-model (21), then the deferred work (22–23).

---

## Stage 13 — Test harness, dependency audit, and a security review gate

**Motivation:** Invariant #4 ("reasonable tests should exist for any code we claim works") is violated — there are **zero** Rust tests, and the pipeline's own gate defers `cargo test` "once tests are implemented" (`docs/stages/README.md:10`). Every later security stage needs a place to land regression tests, and the toolchain has a known-vulnerable dependency. This stage builds the foundation and *arms* the gates.

> **Anchor convention (read first).** `components/gips-http/src/lib.rs` is ~862 lines and drifts every stage. **Do not trust historical line numbers.** Anchor every change to a `fn` name + a quoted snippet and re-grep for it. Line numbers in these prompts are hints written `(≈:NNN)`, not addresses.

**The Change:**

1. Introduce `[workspace.dependencies]` in the root `Cargo.toml` and switch the 9 member manifests to `workspace = true` for shared crates (tokio, serde, anyhow, reqwest, sqlx, axum, tracing…), removing the current version drift (`tokio` is `1.37` in five crates and bare `1` in `gips-http`).
2. **Bump `sqlx` to ≥ 0.8.1** (fixes RUSTSEC-2024-0363; transitively updates `libsqlite3-sys`). Adjust any 0.7→0.8 API changes. **sqlx is the ONLY real advisory in this tree** — `ed25519-dalek` is already **2.2.0** (RUSTSEC-2022-0093 applies only to 1.x; do not "bump" it), `libsqlite3-sys 0.27.0` and `tokio 1.50.0` are clean. Do not spend budget chasing a phantom dalek CVE.
3. Add a `deny.toml` (cargo-deny) with advisory + license + bans checks, and a local `just audit` recipe wrapping `cargo audit`/`cargo deny check` (no CI system is assumed present).
4. Add unit tests for the two pure security-relevant functions that exist today: `is_valid_store_path` (`fn is_valid_store_path`, ≈`gips-http:721`) and `verify_narinfo` (`gips-trust:50`) — including negative/tampered/wrong-key/malformed vectors and the version-field check.
5. Add a `just test`, `just fmt-check`, and `just lint` (markdownlint) recipe so the documented merge gates are actually runnable (they are not today).
6. Update `docs/stages/README.md` to **arm** the gates: `cargo test` is now required (not deferred), add `just audit` as a gate, and add an explicit **security-review gate** step to the pipeline description. **Also fix the gate ORDERING**: the current README runs `cargo check`/`cargo test`/`just audit`/`just lint` on the executor branch *before* the diff is audited — that compiles and runs the branch's `build.rs`, proc-macros, `#[test]` bodies, and its own `justfile`/`deny.toml` recipes on the coordinator's non-sandboxed host before anyone has read the diff. Reorder so the **human/adversarial diff audit of `justfile`, `build.rs`, `deny.toml`, and any new `scheme/` or `.tla` files happens FIRST**, and require gate execution to run in a disposable/sandboxed environment (or at minimum document that running an unreviewed branch's gates is arbitrary code execution as the coordinator).
7. **Supply-chain: pin the one unverified binary dependency.** `justfile` (≈`:101-105`) and `scripts/tla2pdf.sh` (≈`:17-19`) `wget` `tla2tools.jar` over the network with **no checksum, no signature, `-q` hiding errors**, into gitignored `.tools/`, then `java -cp` it. Add a SHA-256 checksum verification step (fail hard on mismatch, re-fetch on partial download — the current `[ ! -f ]` guard never repairs a truncated jar), and pass `--https-only` to `wget`. cargo-deny does not cover this.
8. **Fix `just setup-hooks` (≈`justfile:8-29`).** It `>`-clobbers any existing `.git/hooks/pre-commit` with no backup, and the installed hook auto-runs the unverified `wget`+`java`+`pdflatex` chain (item 7) and `git add`s generated PDFs the author never staged — so merging a branch that adds a `.tla` file turns the coordinator's next commit into fetch-and-execute and smuggles unreviewed binaries past the `git show --stat` audit. Make hook install non-destructive (refuse/prompt if a hook exists) and remove the auto-`git add`.

**Allowed Files Whitelist:**

- `Cargo.toml` (root — add `[workspace.dependencies]`)
- All member `Cargo.toml` files (bases/*, components/*, gips/*, gipsd/*)
- `Cargo.lock`
- `components/gips-http/src/lib.rs` (add `#[cfg(test)]` module only — no logic changes)
- `components/gips-trust/src/lib.rs` (add `#[cfg(test)]` module only)
- `deny.toml` (new)
- `justfile`
- `scripts/tla2pdf.sh` (checksum + `--https-only`)
- `docs/stages/README.md`
- `docs/TODO.md` (add a "Security hardening" milestone section; do **not** re-tick anything)

**Enumerated Tests:**

1. `cargo test` runs and the new `is_valid_store_path` / `verify_narinfo` tests pass, including negative cases (wrong key rejected, tampered body rejected, `version != "1"` rejected, non-64-byte sig rejected).
2. `just audit` reports no `sqlx < 0.8.1` advisory (and confirm no new advisory appears for the workspace pins).
3. `cargo check` and `cargo fmt --check` pass across the workspace.
4. `just tla-check`/`tla-pdf` fail hard (non-zero) if the downloaded `tla2tools.jar` does not match the pinned checksum.
5. `just setup-hooks` refuses to overwrite an existing `pre-commit` hook rather than clobbering it.

**Definition of Done:** Workspace builds green; tests + audit are runnable via `just`; the pipeline README lists a security-review gate *and* orders the diff audit before gate execution; the one binary dependency is checksum-pinned; the git hook no longer auto-fetches/auto-stages. No behavioral change to the daemon yet.

**Commit Message:** `[stage-13] chore: workspace deps, sqlx>=0.8.1, cargo-deny, test harness, armed+ordered gates, pin tla2tools`

**Report Requirements:** List the sqlx API changes required by the 0.8 bump, the tla2tools checksum pinned, and any advisories cargo-deny still reports. Confirm the ed25519-dalek version and that no dalek work was needed.

---

## Stage 14 — Fail-closed trust and correct publisher binding

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

## Stage 15 — Bind the signature to the content it delivers

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

## Stage 16 — Real NarHash: content integrity end to end

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

## Stage 17 — Fix the publish/snapshot workflow (`create_snapshot.scm` + snapshot verification)

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

## Stage 18 — Authentication and network-exposure hardening

**Motivation:** There is no authentication on any endpoint; mutating endpoints (`/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, **and `/snapshot/create`**) are fully open, `/nar/:cid` is an open unauthenticated IPFS proxy, and `scheme/README.md:74` demonstrates binding `0.0.0.0`. Anyone who can reach the socket can publish, pin arbitrary CIDs (disk-fill / host arbitrary content), evict everything, or forge a signed-looking snapshot manifest.

> **Anchor by `fn` name + quoted code, not line number.** The mutating routes are wired in `build_router` (≈`gips-http:134-148`).

> **CRITICAL — the route list.** The actual router registers `/snapshot/create` (≈`:145`, `post(create_snapshot)`) — it was missing from the original endpoint list and MUST be authenticated. Also note the native-narinfo route is `.route("/:file", get(get_native_narinfo))` (≈`:140`), a **bare single-segment catch-all**, not the `/:hash.narinfo` some prompts assume: `file` is a fully attacker-controlled string, so any auth/validation reasoning that assumes a constrained `:hash` parameter is on a false premise.

**The Change:**

1. **Loopback by default, refuse public bind unless opted in.** At startup, if `listen` is non-loopback and `insecure_bind` (new, default `false`) is not set, **refuse to start** with a clear error. When opted in, log a prominent warning.
2. **Local auth token for mutating endpoints.** Generate a token via a CSPRNG (e.g., 32 bytes from `/dev/urandom`), store it with mode `0600`, and require it on **all** mutating endpoints: `/publish`, `/pin`, `/unpin`, `/subscribe`, `/link-channel`, **and `/snapshot/create`**. The token verification in `gips-http` must use constant-time string comparison (`subtle::ConstantTimeEq`) to prevent timing attacks. The `gips` CLI reads and sends it automatically. Read-only endpoints Guix needs (`/narinfo`, `/nar`, the `/:file` native-narinfo route) stay unauthenticated but are governed by Stages 14–16 verification.
3. Scope `/nar/:cid` so it only serves CIDs the node actually tracks/pins (no arbitrary-CID proxying), or require the token for the raw-CID form.
4. **Harden `/link-channel` semantics.** It uses `ON CONFLICT(channel_name) DO UPDATE SET gns_name = excluded.gns_name` (an unconditional repoint of an existing channel to a different publisher), unlike `/subscribe`'s `INSERT OR IGNORE`. Even behind the token, make repointing explicit/rejected-by-default rather than a silent overwrite, or document why overwrite is intended. (The `channels` table is currently never read anywhere — confirm it is actually needed before adding auth around dead write-only state.)
5. **Fix the REPL/CLI client's own exposure bugs** (`scheme/gips/api.scm`): `GIPS_DAEMON` is consulted **before** the fluid set by `(gips-base-url ...)` (≈`:29-35`), so a stale/hostile env var silently redirects every request — including the store paths published and the new auth token — while the REPL reports the URL the user asked for. Make the explicit setter authoritative over the env fallback. Also add `--` before the URL in the `curl` invocation (≈`:59-63`) so a base URL beginning with `-` cannot inject curl options (`-K`, `-o`, `--upload-file`); this is the same flag-injection class Stage 19 fixes for `gnunet-gns`.
6. Update `scheme/README.md` to stop demonstrating `0.0.0.0` without the explicit opt-in + warning context, and correct the `(gips-base-url ...)` documentation to match the fixed precedence.

**Allowed Files Whitelist:**

- `components/gips-http/src/lib.rs` (auth extractor/middleware, `/nar/:cid` scoping, `/snapshot/create` auth, `/link-channel` semantics)
- `bases/gips-config/src/lib.rs` (`insecure_bind`, token path)
- `gipsd/src/main.rs` (bind refusal, token load)
- `gips/src/main.rs` (send token)
- `scheme/gips/api.scm` (GIPS_DAEMON precedence, curl `--`)
- `scheme/README.md`
- `components/gips-http/Cargo.toml` (add `tower-http` if used)
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. `POST /publish` without the token ⇒ 401; with the correct token ⇒ proceeds. Same for **`POST /snapshot/create`** (explicitly test it — it was the missing endpoint).
2. Starting `gipsd` with `listen = "0.0.0.0:9090"` and no `insecure_bind` **fails to start**.
3. `/nar/:cid` for an untracked CID is refused (or requires the token).
4. The `gips` CLI round-trips a mutating command using the on-disk token.
5. With `GIPS_DAEMON` set in the environment, `(gips-base-url "http://explicit")` still directs requests to `http://explicit` (explicit setter wins over env).

**Definition of Done:** No unauthenticated mutation is possible on **any** mutating route (including `/snapshot/create`); the daemon cannot silently expose itself publicly; the open IPFS proxy is closed; the REPL client cannot be silently redirected or curl-flag-injected. Gates pass.

**Commit Message:** `[stage-18] feat: local auth token for ALL mutating endpoints + refuse public bind + fix REPL client redirect/injection`

**Report Requirements:** Document the token format, storage location/permissions, and the exact endpoint auth matrix — the matrix MUST list `/snapshot/create`.

---

## Stage 19 — Input validation, resource limits, and subprocess hardening

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

## Stage 20 — Config, key, and filesystem integrity

**Motivation:** The daemon executes a `guile` script and an arbitrary `gns_command` sourced from config it does not integrity-check; a failing config script silently reverts to fail-open defaults (`gips-scheme-config:27-29`, `if !output.status.success() { return Ok(base); }`); the DB is created world-readable with a **silent cwd fallback** that can open an attacker-planted database (`gips-db:52-62`); **the config-file loader has the same cwd-fallback flaw** (`bases/gips-config/src/lib.rs`); and signing keys are re-read with blocking IO on every request and never zeroized.

> **Anchor by `fn` name + quoted code, not line number.**

**The Change:**

1. **Remove ALL silent cwd fallbacks — there are two, not one.**
   - The DB fallback (`gips-db:52-62`): on DB-open failure, fail loudly and exit; never open a DB relative to CWD.
   - **The config-file fallback** (`bases/gips-config::load_default`, `let mut path = config_dir().unwrap_or_else(|| PathBuf::from("."))`, ≈`:74`, and the `Default` `db_path` which falls back to `current_dir()` ≈`:56-57`): when `config_dir()` returns `None` (systemd/cron/containers/`su` with no `HOME`/`XDG_CONFIG_HOME`), the daemon loads `./gips/gipsd.toml` from its CWD — and that file sets `gns_command`/`guile_config`, both executed as subprocesses, i.e. **attacker-writable CWD ⇒ code execution as the daemon user**. This is strictly worse than the DB fallback. Fail loudly if no explicit/known-safe config dir can be resolved; never resolve config or DB paths relative to CWD.
2. Create the DB (and token/key files) with `0600`, the config dir with `0700`; warn if existing files are group/world-readable or not owned by the daemon user.
3. **Fail-closed on guile config failure:** if `guile_config` is set but the script fails, **refuse to start** rather than silently using defaults (silent revert can drop security-relevant config). Add a subprocess timeout (covered structurally in Stage 19; enforce here for config).
4. **Plumb `trust` through the guile config path — currently impossible.** `gipsd-configuration->toml` (`scheme/gips/config.scm`) emits only `listen`/`db_path`/`ipfs_api`/`gns_command`/`snapshot_cid`, and `merge_guile_config` (`gips-scheme-config`) merges the same five and **never touches `trust`**. Since `GipsdConfig.trust` is `#[serde(default)]`, a Scheme-configured daemon silently gets an **empty trust list** — after Stage 14 that means "accept nothing", and after this stage's item 3 fail-closed guile config could brick every Scheme-configured install with no Scheme-side way to authorize publishers. Add `trust` (trusted_publishers, `allow_unsigned`) to both the Scheme emitter and the Rust merge.
5. Cache the signing key **and the publisher public keys** in memory. Item 4-of-original scoped only the private key, but `resolve_manifest_entry` (≈`gips-http:384`) and `process_feed` (≈`:815`) both do blocking `std::fs::read_to_string(&publisher.public_key)` inside `async fn` on **every** `/narinfo` fan-out — an unauthenticated request stalls a tokio worker per subscription. Cache public keys too (invalidate on config reload); wrap secret material in `zeroize`, and validate key-file permissions on load.
6. Warn when `gns_command`/`guile_config` point at world-writable or non-owned paths (executable-from-config is arbitrary code execution as the daemon user — make that boundary explicit and checked).
7. **Keep signing keys out of the packaged store item.** `guix.scm` copies the entire working tree (`(local-file "." … #:recursive? #t)`) into a world-readable `/gnu/store` item, and `.gitignore` has no `*.pem`/`*.key`/`gipsd.toml` entry — so a publisher's Ed25519 key placed in the repo for `--private-key` lands in the store readable by all. Add `*.pem`, `*.key`, `*.sqlite`, and `gipsd.toml` to `.gitignore`, and document that key material must live outside the checkout. (The `#:select?` fix to `guix.scm` itself is Stage 22; this stage just stops the footgun.)

**Allowed Files Whitelist:**

- `components/gips-db/src/lib.rs`
- `bases/gips-config/src/lib.rs`
- `components/gips-scheme-config/src/lib.rs`
- `scheme/gips/config.scm` (emit `trust`)
- `components/gips-trust/src/lib.rs` (key caching + zeroize)
- `components/gips-http/src/lib.rs` (use cached keys — private and public)
- `gipsd/src/main.rs` (fail-closed startup wiring)
- `.gitignore` (secret-file exclusions — item 7)
- relevant `Cargo.toml` (add `zeroize`)
- `#[cfg(test)]` modules

**Enumerated Tests:**

1. A DB-open failure with no writable configured path causes a clean non-zero exit — **not** a CWD-relative DB. **Same for config load**: with `config_dir()` unresolvable, the daemon exits cleanly rather than loading `./gips/gipsd.toml`.
2. A newly created DB/token file has mode `0600`.
3. `gipsd` with a `guile_config` that exits non-zero refuses to start (does not silently use defaults).
4. A Scheme-emitted config carrying `trust.trusted_publishers` round-trips into `GipsdConfig.trust` (not silently dropped to empty).
5. The signing key **and** a given publisher public key are each read at most once across N `/publish` / `/narinfo` calls (assert via an injected reader/counter).

**Definition of Done:** No attacker-plantable DB **or config** path; secrets and config files have safe permissions and are integrity-gated; config-script failure is fail-closed; trust is expressible via the Scheme path; private and public keys are cached and zeroized; key material is excluded from the packaged store. Gates pass.

**Commit Message:** `[stage-20] fix: remove cwd DB+config fallbacks, 0600 perms, fail-closed+trust-aware guile config, key caching+zeroize`

**Report Requirements:** Document the new startup failure modes and the file-permission matrix, and confirm `trust` now survives the Scheme config round-trip.

---

## Stage 21 — SECURITY.md, threat model, honest docs, and safety invariants

**Motivation:** The explicit ask — trust *within stated limits, which we must state*. Today there is no `SECURITY.md`, no threat model, `docs/invariant.md` has zero safety invariants, `docs/TODO.md:38-41` falsely marks "Trust & signing" complete, `docs/architecture.md` predates stages 03–12, `docs/RISK_ASSESSMENT.md` cites Stage 14/19 mitigations as if already shipped, and the concurrency/permissions policy in `.agents/rules/git-permissions.md` classifies `git push` to a p2p remote as "reversible".

> **Two roadmap claims here are already stale — do NOT act on them blindly:** `.agents/` is **already git-tracked** (`.agents/rules/git-permissions.md` and `.agents/skills/stage-pipeline/SKILL.md` are committed), and `docs/trust-economics.md` **already exists**. Item 5 below is therefore *correct-and-reword*, not *track-from-scratch*.

**The Change:**

1. Add **`SECURITY.md`**: the threat model (adversaries: malicious publisher, hostile IPFS node/gateway, GNS zone compromise, local unprivileged process, network attacker), what GIPS *does* protect against after Stages 14–20, and — plainly — what it does **not** yet:
   - not a drop-in Guix keyring (phased crypto → Stage 22);
   - privacy leakage (publish/search/nar disclose your package set);
   - no revocation;
   - **no Sybil resistance** (integrity ≠ identity-cost → Stage 23);
   - security-through-unguessable-GNS-name is not a capability model;
   - IPFS pubsub is unauthenticated;
   - **store-path ownership is first-writer-wins** — `substitutes` has no `UNIQUE(store_path)` and `process_feed`'s dedupe (`SELECT 1 FROM substitutes WHERE store_path = ?`) is **not publisher-scoped**, so the first subscription to advertise a path owns it with no update path. State this limitation (and file a follow-up to add publisher-scoped rows/uniqueness);
   - **the pipeline itself is a trust boundary** — stage prompts, `.agents/rules/*`, and `justfile` arrive over the unauthenticated `rad` remote and are executed by tool-enabled agents; there is no commit-signature verification. Document the expected repo DID and the "audit-diff-before-running-gates" rule (Stage 13).
   Include how to report a vulnerability.
2. Add **safety invariants** to `docs/invariant.md`: e.g. "never serve a substitute whose NarHash is unverified", "empty trust list ⇒ accept nothing (both parsers)", "no unauthenticated mutation (including `/snapshot/create`)", "no fabricated integrity fields", "config and DB paths are never resolved relative to CWD", and "mirror updates must be strictly causally ordered via Merkle DAGs (TLA+ proven)".
3. **Correct `docs/TODO.md`:** un-tick the false "Trust & signing" completions (≈`:38-41`); reflect the real state and the new hardening milestone.
4. Update `docs/architecture.md` (routes — including `/snapshot/create` and the `/:file` catch-all, `AppState`, the `http→trust` edge, fail-closed default) and `docs/federation.md`/`docs/offline-snapshots.md` to remove overpromises ("signed narinfos", "capability", "censorship-resistant") or qualify them accurately. **Fix `docs/RISK_ASSESSMENT.md`** so it no longer presents Stage 14/19 mitigations as shipped when they are the very work being staged.
5. **Correct (not create) the `.agents/` policy files:** `.agents/rules/git-permissions.md` is already tracked — **reclassify** `git push`/`rebase`/`checkout` as non-trivial (publication/history-rewrite) in the p2p context; ensure the odd/even sharding rule lives in tracked docs so a fresh clone retains it. **Also address claim-protocol integrity:** `claimed_at` is self-attested/unsigned with no owner check on stale-claim removal (any node can backdate to park a stage, or declare another node's active claim stale and take it over). Document the weakness and the mitigation (signed claims / owner-only removal / authority clock) or explicitly record it as an accepted limitation.
6. **Align the consumer-facing docs and recipes with reality.** `just install <package>` (`justfile:72-74`) and `docs/user_guide.md:36-41` add GIPS as a Guix substitute source with **no mention** of `guix archive --authorize`, the ACL, or that narinfo signature verification is what stands between the user and arbitrary substituted binaries. Add the authorization step and an honest note that following the guide against an unmodified Guix will fail verification until Stage 22 (do not imply the workaround is disabling verification).

**Allowed Files Whitelist:**

- `SECURITY.md` (new)
- `docs/invariant.md`, `docs/TODO.md`, `docs/architecture.md`, `docs/federation.md`, `docs/offline-snapshots.md`, `docs/user_guide.md`, `docs/jargon.md`, `docs/RISK_ASSESSMENT.md`
- `README.md` (align claims with reality)
- `justfile` (add the `guix archive --authorize` step / honest comment on `just install`)
- `.agents/rules/git-permissions.md` (reword + claim-protocol note)
- `docs/stages/README.md` (reference SECURITY.md from the security gate)

**Enumerated Tests:**

1. `just lint` (markdownlint) passes on all changed docs.
2. A reviewer checklist: every "censorship-resistant"/"signed"/"capability"/"trusted" claim in the docs is either backed by shipped behavior or explicitly marked as a stated limitation.
3. No `docs/TODO.md` box is ticked for behavior that isn't implemented and tested; `docs/RISK_ASSESSMENT.md` cites no mitigation as shipped that is not.

**Definition of Done:** GIPS ships an accurate `SECURITY.md` + threat model, safety invariants are recorded, the pipeline's own trust boundary and store-path/claim limitations are stated, and no doc overpromises relative to the code. This is the "state the limits" deliverable.

**Commit Message:** `[stage-21] docs: SECURITY.md, threat model, safety invariants, honest claims`

**Report Requirements:** Provide the final list of "protects against" vs "does not yet protect against" bullets from SECURITY.md.

---

## Stage 22 (DEFERRED / FUTURE) — Guix-native signature compatibility

> **Resolution (2026-08-18):** expanded into stages 29 (Rust-side Guix-native
> signing — which corrected item 1: the real format is libgcrypt ECDSA with
> RFC 6979 nonces over the Ed25519 curve, advanced-sexp rendering, not
> canonical-sexp EdDSA) and 30 (Scheme test parity, `guix.scm` guile-gcrypt
> input, authorize-workflow docs), both merged. Item 3's `test_sign.scm`
> critique below is therefore resolved. Items 2 and 4 remain future work.
> See `docs/stages/completed/stage-22-SKETCH-expanded-into-29-30.md`.

**Motivation:** The phased decision: only after the above is GIPS *safe*, but it is still **not** interoperable with a stock `guix-daemon` (dalek/PKCS#8/raw-sig vs. libgcrypt canonical-sexp keys, and Guix recomputes `NarHash` client-side). Making `just install` work against an unmodified Guix without disabling verification is a separate, larger effort.

**The Change (sketch — to be expanded into its own stage set when scheduled):**

1. Replace/augment the signing stack with guile-gcrypt canonical s-expression Ed25519 keys and a Guix-parseable `Signature: <version>;<host>;<base64-sexp>` payload over the canonical `StorePath/NarHash/NarSize/References` body.
2. Provide a `guix archive --authorize`-compatible key-advertisement/authorization workflow, and key distribution over GNS.
3. Fix `test_sign.scm` (correct guile-gcrypt API) or replace it with a real cross-validation test between the Rust and Guile signature formats; add `guile-gcrypt` to `guix.scm`. Note the current `test_sign.scm` is doubly broken — it passes a raw `(string->utf8 …)` bytevector to `signature-sexp` (which expects a canonical hash-data s-exp via `bytevector->hash-data`) and uses `key-type-private` (a key-*type* accessor, not a private-key extractor), **and it never verifies the signature it produces**. It is the pattern anyone here will copy, so the replacement MUST round-trip sign→verify.
4. Address `guix.scm` reproducibility (`#:cargo-inputs ()`) so GIPS can be built the offline way it asks users to trust, **and add a `#:select?` predicate** to `(local-file "." …)` so the packaged store item excludes `.git`, `.tools/`, `*.pem`/`*.key`, and stray `gipsd.toml`/`manifest.json` (Stage 20 adds the `.gitignore` guard; the `#:select?` fix is the real containment and belongs here).

**Status:** Not scheduled in this roadmap; listed so the phased boundary is explicit and the limitation in `SECURITY.md` (Stage 21) points here.

---

## Stage 23 (DEFERRED / DESIGN-ONLY) — Sybil resistance via federated, accountable membership

**Motivation:** Signatures and NarHash (Stages 14–16) stop *forged/tampered content*, but they do nothing about *cheap identity* — an adversary can mint many valid publishers to flood, spam, or grief the network. This stage designs an **optional** identity-cost + accountability layer without reintroducing a central chokepoint (which would negate GIPS's censorship-resistance premise). It is design-only: the output is a written spec + a decision on whether/how to implement, not code.

**Design principle — separate the two questions:**

- *Cost of identity* (Sybil resistance) ← membership fee / slashable bond / invitation delegation.
- *Grounds for removal* (integrity) ← **objective, cryptographically-provable fraud proofs**, gossiped and independently verifiable (a signed narinfo whose delivered bytes don't match its signed `NarHash`; equivocation = two conflicting signed feeds at one version). Enforcement must ride on evidence, never on subjective accusation, or the mechanism becomes a censorship weapon.

**The model to specify (federated):**

1. **Local accountability, global amplification.** Small groups vouch for their own members (who they actually know); larger groups vouch for groups. A member's acceptance by a distant peer is transitive through this graph — a web-of-trust / attenuable-capability (macaroon/UCAN/GNUnet-style) delegation chain rooted in signed GNS identities, extending `docs/federation.md`.
2. **The larger group is a shared-defense service, not a gatekeeper.** For a small fee, a sub-group gains: faster revocation/fraud-proof propagation, access to a shared slashable-bond / insurance pool, and a broader trust anchor so its members are accepted by more peers. The fee funds *infrastructure*, not a ban lever.
3. **Bounded, decaying vouching stake.** Inviting/vouching risks a small, decaying amount of the voucher's reputation or a refundable bond — slashed only on a *proven* fraud proof against the vouchee, and never the voucher's whole standing. Repeated bad vouches compound. ("If you vouch for a bad actor your account freezes too," made survivable and non-chilling.)
4. **Optional economic Sybil-cost as a slashable bond, not a pure subscription.** A refundable deposit that is slashed on proven misbehavior gives identity-cost without funding a central banning operator. If a paid-membership operator is desired, it runs as *one group among many*, never the single root.

**Non-negotiable properties (what keeps it censorship-resistant):**

- **No single root.** Multiple overlapping federations must coexist; a node may belong to several larger groups.
- **Cheap exit, no orphaning.** Leaving a group is low-cost and does not make your already-published, still-verifiable content unreachable.
- **No collective capital punishment.** One bad member cannot destroy an honest group; penalties are bounded and evidence-gated.
- **Evidence over fiat.** Every revocation should carry a portable, independently-verifiable fraud proof. Fraud proofs must be completely self-contained and objective, explicitly stripping any client-identifying metadata (IPs, headers) to protect requester privacy.

**Open questions to resolve in the spec:** payment rail vs. bond escrow (and the legal/custody/KYC/AML surface either introduces); how membership tokens are represented and rotated over GNS; how fraud proofs are gossiped and how nodes weight group-level vs. direct trust; adjudication for misbehavior that is *not* cryptographically provable (if any is admitted at all); anti-collusion for a corrupt larger group falsely accusing a sub-group.

**Allowed Files Whitelist (design-only):**

- `docs/federation.md` (extend with the federated-membership model)
- `docs/trust-economics.md` (**already exists** — extend it, do not create anew)
- `SECURITY.md` (link Sybil-resistance limitation → this design)
- `docs/TODO.md` (add as a future milestone)

**Definition of Done:** A written design (`docs/trust-economics.md`) that specifies the model above, satisfies the non-negotiable properties, and either proposes a concrete implementable subset or explicitly records why it stays deferred. No production code in this stage.

**Commit Message:** `[stage-23] docs: design federated accountable-membership / Sybil-resistance layer`

**Report Requirements:** Summarize the recommended concrete subset (if any) to implement first and its dependencies on Stages 14–16.

**Status:** Deferred, design-only. Depends conceptually on Stage 16 (fraud proofs require real NarHash) and Stage 18 (identity/token plumbing).

---

## Verification (per stage and end-to-end)

**Per-stage gates (run by the coordinator before merge, per `docs/stages/README.md`, now armed AND reordered in Stage 13):**

- **Diff audit FIRST** — adversarial read of the diff (especially `justfile`, `build.rs`, `deny.toml`, new `scheme/`/`.tla` files) *before* any gate executes branch code, and gate execution in a disposable/sandboxed environment.
- `cargo check` and `cargo fmt --check` across the workspace.
- `cargo test` (each stage adds its enumerated tests as `#[cfg(test)]` / integration tests).
- `just audit` (cargo-audit + cargo-deny) — no known advisories.
- `just lint` (markdownlint) for any docs touched (invariant #3).
- The new **security-review gate**: adversarial read of the diff against the threat model.

**End-to-end acceptance (after Stage 21):**

1. Fresh install, default config, empty trust list, `allow_unsigned=false`: subscribe to a publisher and confirm `/narinfo` + `/nar` return **nothing** unless a correctly-signed, correctly-bound, NarHash-verified substitute is present — via **both** the manifest and feed parsers. (Stages 14–16.)
2. Tamper test: with an authorized publisher, swap the artifact CID / flip a content byte / replay a stale (or missing-timestamp) feed — each is rejected. (Stages 15–16.)
3. Exposure test: `listen=0.0.0.0` without `insecure_bind` refuses to start; a mutating request without the token is 401 — including `POST /snapshot/create`. (Stage 18.)
4. Robustness test: a hung/oversized IPFS response, or an unbounded remote pin flood, yields a bounded error, not an OOM/hang. (Stage 19.)
5. Integrity test: a DB-open **or config-load** failure exits cleanly (no CWD DB/config); DB/token files are `0600`; trust survives the Scheme config round-trip. (Stage 20.)
6. Docs test: `SECURITY.md` "does not protect against" list matches reality; no false TODO ticks; `RISK_ASSESSMENT.md` cites no unshipped mitigation as shipped; markdownlint clean. (Stage 21.)

---

## Notes on execution (do not run yet)

- This file mirrors the `docs/stages/stage-NN-PROMPT.md` files, which are the source of truth. When approved, the pipeline runs them **in order** (13→21; 22–23 deferred). Dependencies: 14 depends on 13's tests/gates; 15 unifies the two wire formats and 15–16 build on that canonical body; 17 depends on 15–16's signature schema and 16's mock-branch removal; 18–20 are independent of the crypto chain but should land after 14 so the fail-closed default is the baseline; 21 documents the finished behavior.
- Breaking changes are expected (fail-closed default in both parsers, required token on all mutating endpoints, refused public bind, removed cwd DB *and* config fallbacks, trust required via Scheme config). Stage 21's `SECURITY.md` + `README`/`user_guide` updates must land so users understand the new configuration requirements.
