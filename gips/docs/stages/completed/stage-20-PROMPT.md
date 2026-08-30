# Stage 20 — Config, key, and filesystem integrity

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
