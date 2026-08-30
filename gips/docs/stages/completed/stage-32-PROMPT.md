# Stage 32 — `gips key generate-feed`/`export-feed`, example configs, and a true end-to-end personal-sync walkthrough

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

A docs audit (2026-08-18) walked `docs/personal-sync-quickstart.md` as a
new user would and found the GIPS-side half of setup undocumented and
partially untooled. Trust is fail-closed, so every gap below ends the same
way: the laptop silently builds from source and nothing explains why.

- **No way to generate the feed key.** `[trust].signing` wants a PKCS#8
  PEM Ed25519 private key (`gips-trust`: `SigningKey::from_pkcs8_pem` in
  `fn sign_narinfo`) and verifiers read an SPKI public PEM
  (`VerifyingKey::from_public_key_pem` in `fn verify_narinfo`), but
  `gips key` offers only `generate-guix`/`export-guix`
  (`gips/src/main.rs`, `enum KeyCommands`). A publisher must hand-roll a
  PEM with openssl, uninstructed.
- **The `[trust]` table is shown nowhere.** No doc demonstrates
  `[[trust.trusted_publishers]]` (`gns_name` + `public_key` path — see
  `TrustConfig`/`TrustedPublisher` in `components/gips-trust/src/lib.rs`),
  even though an empty list means "accept nothing from the network".
- **The two-key model is unexplained**: the Ed25519 *feed* key
  (GIPS-internal trust between gipsd nodes) vs. the Guix-format *narinfo*
  key (`gips key generate-guix`, authorized into `/etc/guix/acl`). The
  quickstart's "Trust the Builder" covers only the second.
- **The quickstart's consumer section never subscribes** — it jumps from
  "copy the manifest" to `just sync-pull`, but resolution runs over
  subscriptions (`just subscribe <gns-name>` → `POST /subscribe`).
- **No prerequisites, no example configs, no troubleshooting** anywhere
  in the repo (`ls examples/` — the directory does not exist; only
  `docs/user_guide.md` has a prerequisites list, and it omits
  guile-gcrypt, which serve-time signing needs at runtime).

Verified ground truth to build on: the workspace's `ed25519-dalek` already
carries `features = ["pkcs8", "pem"]` (root `Cargo.toml`), `gips-trust`
already depends on `rand 0.8`, and the Scheme config emitter already has
`<trusted-publisher>` records (`scheme/gips/config.scm`), so both config
syntaxes can be documented truthfully.

> **Anchor by `fn` name + quoted code, not line number.**

## The Change

1. **`generate_feed_key_pair` in `gips-trust`** (mirror the shape of
   `gips_trust::guix::generate_key_pair`): generate an Ed25519 keypair
   with the crate's existing `rand`; write the private half as PKCS#8 PEM
   and the public half as SPKI PEM — exactly the formats
   `sign_narinfo`/`verify_narinfo` and `KeyCache` already read. Files
   `0600`, parent dir created `0700`, refuse to overwrite if **either**
   half exists (same ceremony rules as the guix pair, same reason: the
   only thing that can verify an already-published signature is the key
   that made it). Choose default filenames beside the guix key that make
   the PEM format and the feed role obvious and cannot be confused with
   `signing-key.sec`; state the names in your report.
2. **CLI**: `gips key generate-feed [--path <secret>]` calls it and
   prints both paths (match `generate-guix`'s output shape);
   `gips key export-feed [--path <secret>]` prints the sibling public
   PEM to stdout for copying to consumer machines (match
   `export-guix`'s behavior, including the error when the file is
   missing — it must name the path it looked at).
3. **Example configs — new `examples/` directory**, two richly commented
   files:
   - `examples/gipsd-builder.toml`: `[trust]` with `[trust.signing]`
     (`narinfo_private_key`, `narinfo_public_key`,
     `publisher_gns_name`), a `[guix_signing]` block, and a comment on
     each field saying which ceremony produces it.
   - `examples/gipsd-consumer.toml`: `[[trust.trusted_publishers]]`
     (`gns_name`, `public_key`) plus `allow_unsigned = false` spelled
     out with a comment on why it must stay false.
   These files are contract, not prose: add a Rust test that parses BOTH
   files into `GipsdConfig` (via `include_str!` +
   `env!("CARGO_MANIFEST_DIR")`) so the examples can never drift from the
   serde shapes. Put the test wherever `GipsdConfig` parsing is already
   tested (`bases/gips-config`) unless you find a better home; say where
   in the report.
4. **Rewrite `docs/personal-sync-quickstart.md` into a true end-to-end
   walkthrough**, in this order:
   - **Prerequisites** (builder: Guix, IPFS, guile + guile-gcrypt for
     `[guix_signing]`, optionally GNUnet; consumer: Guix, IPFS, GIPS).
   - **The two keys, in one short paragraph**: feed key = gipsd-to-gipsd
     trust (`[trust]`), Guix key = guix-daemon acceptance (`/etc/guix/acl`).
     Every later step names which key it is touching.
   - **Builder setup**: `gips key generate-feed`, `gips key
     generate-guix`, the builder TOML (point at
     `examples/gipsd-builder.toml`), restart.
   - **Consumer setup**: copy BOTH public keys over an eyeball-able
     channel; `[[trust.trusted_publishers]]` (point at
     `examples/gipsd-consumer.toml`); `just subscribe <gns-name>` —
     the step the current doc omits; `sudo guix archive --authorize`
     (keep the existing section's content).
   - **The workflow** (sync-export / sync-push / sync-pull — keep, now
     that stage 31 made it real).
   - **Troubleshooting**: at minimum — laptop builds from source
     (missing ACL entry, missing `[[trust.trusted_publishers]]`, or no
     subscription — and how to tell which, including that fail-closed
     rejections are deliberately indistinguishable from misses on the
     wire, so the place to look is the consumer gipsd's logs); 401s
     (token file); `guix build -m` refusing the run (stage 31's strict
     stdout parsing).
   - Keep the existing "Why GIPS instead of standard Guix tools?"
     framing; keep every existing claim that is still true.
5. **`docs/user_guide.md`**: in "Subscribe to a Publisher", add the
   missing other half — the `[[trust.trusted_publishers]]` snippet (or a
   pointer to the consumer example) — and a sentence distinguishing the
   two keys, linking to the quickstart walkthrough.
6. **`docs/TODO.md`**: in the "Still open" Scheme-parity line, add the
   new `key generate-feed`/`export-feed` commands to the list of
   commands with no Scheme binding (the debt grows; record it).
7. **`README.md`**: extend the one CLI sentence to mention the feed-key
   commands.

## Non-goals (do not touch)

- No key rotation, revocation, or GNS key distribution.
- No changes to `sign_narinfo`/`verify_narinfo`, `KeyCache`, or any
  serving/verification logic — this stage only *produces* keys in the
  formats they already consume.
- No Scheme REPL bindings for `key` commands (recorded debt, item 6).
- No changes to `scheme/gips/config.scm` — it already carries trust
  parity; the docs just have to show it.

## Allowed Files Whitelist

- `components/gips-trust/src/lib.rs` (new generate function + its tests;
  a small new module file under `components/gips-trust/src/` is fine)
- `components/gips-trust/Cargo.toml` (only if a missing crate feature
  blocks PEM encoding)
- `gips/src/main.rs`
- `examples/gipsd-builder.toml`, `examples/gipsd-consumer.toml` (new)
- `bases/gips-config/src/lib.rs` (`#[cfg(test)]` example-parsing test
  only — or the alternate test home you justify in the report)
- `docs/personal-sync-quickstart.md`, `docs/user_guide.md`,
  `docs/TODO.md`, `README.md`
- Member `Cargo.toml`/`Cargo.lock` for whitelisted dependencies and
  dev-deps of tests (standing retro allowance)

## Enumerated Tests

1. **Ceremony rules**: `generate_feed_key_pair` writes both halves with
   mode `0600` inside a `0700` directory; a second call with either half
   already present refuses and changes nothing (assert both file
   contents unchanged).
2. **Round-trip is the guarantee**: a freshly generated pair
   signs a narinfo body via `sign_narinfo` and verifies via
   `verify_narinfo`; a tampered body then fails verification. (This is
   the test that proves the emitted PEM formats are the ones the
   verifier actually reads — do not test format by string-matching
   headers alone.)
3. **Config round-trip**: a `TrustConfig` whose
   `signing.narinfo_private_key` points at the generated secret half
   signs successfully through the existing `KeyCache::private_key` path
   (i.e. the cache loads what the generator wrote).
4. **`export-feed`**: prints the exact bytes of the public PEM; with the
   file absent, exits non-zero naming the path.
5. **Examples are contract**: both `examples/*.toml` parse into
   `GipsdConfig`; the parsed builder config has `trust.signing` and
   `guix_signing` present; the parsed consumer config has exactly one
   trusted publisher and `allow_unsigned == false`.
6. **CLI surface**: `gips key generate-feed --path <tmp>` followed by
   `gips key export-feed --path <tmp>` round-trips through the binary's
   own argument handling (a unit test of the handler functions is
   acceptable if the existing key-command tests are structured that way
   — match the house pattern already in `gips/src/main.rs`'s test
   module).

## Definition of Done

- All enumerated tests implemented and green.
- Gates in the stages-README order: adversarial diff audit first, then
  `cargo check`, `just fmt-check`, `just test`, `just audit` (known
  vacuous — note it), `just lint` (diff the full sorted ` error ` list
  against the base commit; zero new lines beyond this prompt file's own
  pre-existing ones), `just scheme-test` green (stage-30 baseline).
- Every config snippet shown in the rewritten docs is either quoted from
  (or pointed at) the tested `examples/` files — no untested TOML in
  prose.
- A reader following the quickstart top to bottom encounters every step
  the audit found missing: prerequisites, both keys, `[trust]` on both
  machines, subscribe, authorize, workflow, troubleshooting.

## Commit Message

`[stage-32] feat: gips key generate-feed/export-feed, tested example configs, end-to-end personal-sync walkthrough`

## Report Requirements

- The default feed-key filenames chosen and why they cannot be confused
  with the guix pair.
- Where the example-parsing test lives.
- A section-by-section summary of the quickstart rewrite (old → new).
- Confirmation that no signing/verification logic changed (diff scope).
- Deviations, per house rules.

## Blocked Protocol

If ground truth contradicts this prompt — `ed25519-dalek` cannot emit
PKCS#8/SPKI PEM even with its standard feature flags, the example configs
cannot be made to parse without changing `GipsdConfig` itself, or the
existing key-command tests follow a pattern that makes enumerated test 6
impossible as stated — STOP. Commit nothing beyond your branch, report
the evidence (command output, file+line), and end BLOCKED. Do not
improvise around the prompt.
