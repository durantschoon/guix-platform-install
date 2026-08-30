# Stage 29 (take 2) — Guix-native narinfo signatures via libgcrypt subprocess

**History:** Take 1 of this prompt was executed on 2026-08-18 and correctly hit its Blocked protocol: its ground truth claimed Guix signatures were RFC 8032 EdDSA producible by `ed25519_dalek`. The blocked run proved otherwise against a live `ci.guix.gnu.org` narinfo, the installed guile-gcrypt, and upstream `guix/pki.scm`. This take's ground truth incorporates that evidence. The coordinator's architectural decision: **signing shells out to `guile` + `(gcrypt pk-crypto)`** — no new Rust crates, no FFI, no hand-rolled crypto — and GIPS grows a second, guix-format key pair alongside the dalek feed key (which is untouched).

**Ground truth (binding, verified 2026-08-18 against production + upstream source):**

- The `Signature:` payload decodes to an **advanced-rendered** (human-readable, UTF-8) s-expression — `guix/scripts/publish.scm` does `base64-encode(string->utf8(canonical-sexp->string ...))` and `guix/narinfo.scm` does `utf8->string(base64-decode ...)`. NOT the canonical `<len>:<bytes>` encoding.
- The structure is `(signature (data (flags rfc6979) (hash sha256 #HEX#)) (sig-val (ecdsa (r #32#) (s #32#))) (public-key (ecc (curve Ed25519) (q #32#))))` — **`ecdsa`**, libgcrypt's RFC 6979 deterministic ECDSA over the Ed25519 curve. `ed25519_dalek` cannot produce this and its keys derive different public points from the same seed; nothing dalek touches this stage.
- The signed text is everything the narinfo serves **before the `Signature:` token** (including the preceding newline), hashed sha256. Guix's `narinfo-sha256` additionally returns `#f` — narinfo counts as unsigned — unless the signed region contains all of `StorePath`, `NarHash`, `References`.
- Guix's `%signature-status` requires BOTH `hash-data->bytevector(data) == recomputed hash` AND libgcrypt `verify(sig-val, data, public-key)`, then ACL membership of the exact public key.
- Key generation: `(genkey (ecc (curve Ed25519) (flags rfc6979)))` via `(gcrypt pk-crypto)`; the public half renders as `(public-key (ecc (curve Ed25519) (q #HEX#)))` — the shape `guix archive --authorize` consumes. Advanced rendering comes from `canonical-sexp->string`; obtain all sexp bytes FROM libgcrypt (via the guile helper), never by hand-formatting in Rust.

**The Change:**

1. **A guix-format key pair for gipsd** (`gips-trust`): secret and public keys stored as advanced sexp text files (like guix's `/etc/guix/signing-key.{sec,pub}`), 0600/0700 via the existing `fsintegrity` staking, in the config dir. Generation is explicit ceremony: `gips key generate-guix` (CLI) shells a committed guile helper that calls `genkey` and writes both files; refuses to overwrite an existing key. The dalek feed key and every existing `sign_narinfo`/`verify_narinfo` call stay untouched.
2. **A signing subprocess helper** (committed guile script, suggested `components/gips-trust/guile/guix-sign.scm`): reads the secret-key path and the sha256 hex (argv, `--`-separated), emits the full advanced signature sexp on stdout. The Rust wrapper (`gips-trust`) invokes it with the stage-19 subprocess pattern — absolute/configured guile path, argument separation, timeout, output size bound — and builds `Signature: 1;<host>;<base64(utf8 advanced sexp)>`. Host: a config override, defaulting to the machine hostname (what `guix publish` does).
3. **Serve-time signing with a cache** (`gips-http`): `get_native_narinfo` (both DB and snapshot branches) appends the Signature line when a guix key is configured. A subprocess per request is unacceptable on the narinfo-burst path, so cache the signature keyed by the sha256 of the signed text (moka, same pattern as the GNS cache; size-bounded). No key configured → byte-identical unsigned output plus a once-at-startup log line. Signing failure → 500, never silently unsigned. The served text must contain `StorePath`, `NarHash`, `References` before the Signature line (per ground truth); if today's text lacks any, fixing the text is in scope and must be disclosed.
4. **Config surface** (authorized by this prompt): an optional `guix_signing` config block (secret-key path, optional `host`) threaded to where items 2–3 need it. Follow the existing config conventions; absent block = feature off.
5. **Key export**: `gips key export-guix` prints the public advanced sexp exactly as stored — `guix archive --authorize`-ready.
6. **The oracle test** (`gips-trust` integration test + committed oracle script): generate a key (in a temp dir), sign a realistic narinfo text through the real pipeline, then verify with a guile oracle that mirrors `%signature-status` and `narinfo-sha256` semantics: recompute the hash from the text before `Signature:`, check it equals the sexp's embedded hash, libgcrypt-`verify` the sig-val, and compare the embedded public key against the exported `.pub` byte-for-byte. A flipped byte in the signed text must flip the verdict (non-vacuity). Skip loudly if `guile`/`(gcrypt pk-crypto)` are absent; they are present on this machine and the report must show the oracle ran for real.

**Ground rules:** No new Rust dependencies. No dalek involvement in any new code path. Feed/mirror trust path, `scheme/` top-level sources, `justfile`, `guix.scm` untouched (stage 30's territory). Subprocess hardening per stage 19 is mandatory, not optional polish.

**Allowed Files Whitelist:**

- `components/gips-trust/src/` (lib.rs or new modules)
- `components/gips-trust/guile/` (new: signing + keygen helper scripts)
- `components/gips-trust/tests/` (oracle test + oracle `.scm`)
- `components/gips-http/src/lib.rs`
- `gips/src/main.rs` (`key generate-guix`, `key export-guix`)
- `bases/gips-config/src/lib.rs` (the `guix_signing` block)
- `#[cfg(test)]` modules in the above
- member `Cargo.toml`/`Cargo.lock` for dev-deps of tests only (flag them)

**Enumerated Tests:**

1. `gips key generate-guix` creates `.sec`/`.pub` advanced sexp files, 0600 in a 0700 dir, whose `q` values match; a second invocation refuses to overwrite.
2. The oracle round-trip (item 6), including the flipped-byte non-vacuity check and the embedded-key == exported-`.pub` comparison.
3. `get_native_narinfo` with a configured key serves text whose pre-`Signature:` bytes are identical to the unsigned serving of the same row, whose last line parses as `Signature: 1;<host>;<base64>`, and whose payload decodes as UTF-8 to an advanced sexp with `(sig-val (ecdsa ...))`.
4. With no `guix_signing` config, served narinfos are byte-identical to pre-stage output.
5. The signature cache: two serves of the same row spawn one signing subprocess (observable via a test hook or a counting wrapper — executor's choice, disclosed); a different row signs separately.
6. The snapshot branch signs too (test 3's assertions against a snapshot-served narinfo).
7. Subprocess hardening: a helper stubbed to hang trips the timeout (bounded error, no indefinite hang), and a malformed/oversized helper stdout is rejected, both surfacing as 500-with-log not unsigned-200.

**Definition of Done:** All enumerated tests pass with the oracle genuinely executing here; `cargo check`, `just fmt-check`, `just test` green; `just lint` diffed against base, zero new error lines; `just audit` vacuous (note it); `just scheme-test` still fails on the pre-existing `test_sign.scm` breakage exactly as on base — stage 30's territory.

**Commit Message:** `[stage-29] feat: Guix-native narinfo signatures — libgcrypt subprocess signing, guix-format keys, serve-time cache`

**Report Requirements:** The exact advanced sexp bytes produced for the test key (redacting nothing — it is a test key); evidence the oracle ran; cache hit behavior observed; subprocess timeout/size-bound values chosen; the byte-compatibility evidence for tests 3–4; every deviation.

**Blocked protocol:** If the served narinfo text cannot satisfy the mandatory-fields rule without changes outside the whitelist, or the guile helper cannot express `genkey`/`sign` as specified with the installed guile-gcrypt, STOP and report. Do not fall back to dalek, do not hand-format sexps in Rust, do not ship a signature the oracle rejects.

---
