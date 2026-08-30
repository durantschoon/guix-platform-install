# Stage 13 — Test harness, dependency audit, and a security review gate

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
