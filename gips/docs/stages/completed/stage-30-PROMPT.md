# Stage 30 — Scheme parity for Guix signing: real test_sign, config emitter, workflow docs (stage-22 expansion, part 2 of 2)

**Motivation (measured):** Stage 29 shipped Guix-native narinfo signing, leaving three loose ends its report enumerated. (1) Root `test_sign.scm` — the entire `just scheme-test` gate — still fails on every run (`gcrypt/pk-crypto.scm:307:28 struct-vtable: Wrong type argument … ed25519`): it passes a raw bytevector where a hash-data sexp is required, misuses `key-type-private`, never verifies what it signs, and assumes the EdDSA format stage 29 disproved. It is the pattern anyone here would copy. (2) A Scheme-configured node cannot turn signing on: `gips_scheme_config::merge_toml` and `scheme/gips/config.scm` know nothing of `[guix_signing]`, so the documented Guile-config path silently cannot configure the feature. (3) `guix.scm` does not declare `guile-gcrypt`, so a Guix-deployed gipsd lacks the signing subprocess's one dependency; and no user-facing doc explains the generate → authorize → verify workflow. The working `genkey`/`sign` incantations are committed in `components/gips-trust/guile/` — this stage builds on them, it does not re-derive them.

> **Anchor by `fn`/file + quoted code, not line number.**

**The Change:**

1. **Replace `test_sign.scm` (repo root) with a real suite.** Keep the filename and the `just scheme-test` recipe (`guile test_sign.scm`) unchanged so the gate definition doesn't move. The new suite, using `(gcrypt pk-crypto)` with the stage-29 shapes (`(genkey (ecc (curve Ed25519) (flags rfc6979)))`, `bytevector->hash-data … #:key-type 'ecc`, `(sig-val (ecdsa …))`):
   - generates a throwaway key pair in a temp dir,
   - signs a realistic narinfo body **by invoking the committed helper** `components/gips-trust/guile/guix-sign.scm` as a subprocess (the thing production runs is the thing tested),
   - verifies the result the way Guix does — recompute sha256 of the pre-`Signature:` text, compare to the embedded hash, libgcrypt-`verify`, compare embedded key to the `.pub` —
   - and proves non-vacuity: a tampered body and a mismatched key must both fail loudly.
   Exit 0 only if every check passes. **After this stage, `just scheme-test` green is the new gate baseline on this machine** — the "known-broken" note in the stages README stops being true.
2. **Scheme config parity.** Teach `scheme/gips/config.scm` to emit a `[guix_signing]` TOML block (secret-key path, optional host, optional guile path) and verify `gips_scheme_config`'s merge delivers it into `GipsdConfig.guix_signing` — a Rust test in `components/gips-scheme-config` driving a real `guile` subprocess with a config script, mirroring however that crate's existing tests work. If `merge_toml` passes unknown tables through untouched, prove it with the test rather than adding dead plumbing; if it drops them, fix it.
3. **`guix.scm`: add `guile-gcrypt` as an input** (item 3 of the stage-22 sketch says exactly this). Guix is not installed on this machine, so the gate is a syntax/read check (`guile -c` reading all sexps from the file) plus review — say so in the report, don't pretend it was built.
4. **Docs, truthfully:**
   - `SECURITY.md`: rewrite the "Not a Drop-In Guix Keyring" limitation — serving-side signing now ships; still open: key distribution over GNS, revocation, rotation, and ACL tooling. Point remaining work at the stage-22 sketch.
   - `docs/personal-sync-quickstart.md`: a "Trust the builder" section with the exact ceremony: `gips key generate-guix` on the desktop, copy the printed `.pub`, `sudo guix archive --authorize < gips-signing.pub` on the laptop, and the `[guix_signing]` block gipsd needs. Note that verification stays on end to end.
   - `docs/stages/README.md`: update the environment note — `just scheme-test` is expected green now; `guile-gcrypt` is installed via the codeberg build (keep the brew-upgrade caveat).

**Ground rules:** No changes to `components/gips-trust/` or `components/gips-http/` (stage 29's code is frozen for this stage; its helpers are consumed, not edited). No new Rust dependencies. `justfile` only if the `scheme-test` recipe genuinely cannot stay `guile test_sign.scm` — that would be a disclosed deviation with the reason.

**Allowed Files Whitelist:**

- `test_sign.scm` (repo root — full replacement)
- `scheme/gips/config.scm`
- `components/gips-scheme-config/src/lib.rs`
- `guix.scm`
- `SECURITY.md`, `docs/personal-sync-quickstart.md`, `docs/stages/README.md`
- `#[cfg(test)]` modules in `components/gips-scheme-config`
- member `Cargo.toml`/`Cargo.lock` for dev-deps of tests only (flag them)

**Enumerated Tests:**

1. `just scheme-test` exits 0, and its output shows the four verdicts (valid, tampered-body rejected, wrong-key rejected, helper self-check exercised).
2. Deliberately breaking the body (a test-internal tamper case, not a repo change) flips the suite to non-zero — demonstrated in the suite itself, per item 1.
3. The Scheme-config round trip: a `.scm` config emitting `guix_signing` produces a `GipsdConfig` whose `guix_signing.secret_key` matches — Rust test in `gips-scheme-config`.
4. A `.scm` config *without* the block leaves `guix_signing = None` (absence still means off through the Scheme path).
5. `guix.scm` read-check passes and its diff shows `guile-gcrypt` among the inputs.
6. Docs: `just lint` diff against base shows only the intended new/changed lines (docs edits must not add markdown errors; fixing adjacent pre-existing ones is out of scope).

**Definition of Done:** All enumerated tests pass; `cargo check`, `just fmt-check`, `just test` green; **`just scheme-test` green** (the point of the stage); `just lint` diffed against base with zero new error lines; `just audit` vacuous (note it — its fate is a recorded retro item, not yours).

**Commit Message:** `[stage-30] feat: real scheme-test suite, guix_signing Scheme config parity, guile-gcrypt in guix.scm, trust workflow docs`

**Report Requirements:** The scheme-test output (all verdicts); how the config round-trip test drives guile; the `guix.scm` input diff; the exact docs wording for the authorize ceremony; every deviation.

**Blocked protocol:** If the committed `guix-sign.scm` helper cannot be reused from the suite without editing it (its file is outside your whitelist), or `merge_toml` parity requires touching files beyond the whitelist, STOP and report — do not fork a divergent copy of the helper into `test_sign.scm`.

---
