# Stage 22 (SKETCH — executed as stages 29 + 30) — Guix-native signature compatibility

> **How to read this file.** Stage 22 was never run as a stage of its own: it
> was authored as a deferred sketch, then expanded on 2026-08-18 into stage 29
> (Rust-side Guix-native signing) and stage 30 (Scheme parity + trust workflow
> docs), both merged. It is archived under this name — rather than the usual
> `stage-NN-PROMPT.md` — because it was a design document, not an executed
> prompt. The sketch below is preserved as written (line-item corrections in
> italics); the coordinator notes at the bottom record what shipped and what
> remains future work (GNS key distribution, revocation/rotation, `guix.scm`
> `#:select?` containment).

**Motivation:** The phased decision: only after the above is GIPS *safe*, but it is still **not** interoperable with a stock `guix-daemon` (dalek/PKCS#8/raw-sig vs. libgcrypt canonical-sexp keys, and Guix recomputes `NarHash` client-side). Making `just install` work against an unmodified Guix without disabling verification is a separate, larger effort.

**The Change (sketch — to be expanded into its own stage set when scheduled):**

1. Replace/augment the signing stack with guile-gcrypt s-expression keys and a Guix-parseable `Signature: <version>;<host>;<base64-sexp>` payload over the canonical `StorePath/NarHash/NarSize/References` body. *(Corrected 2026-08-18 by the stage-29 blocked run: the signature is libgcrypt **ECDSA with RFC 6979 nonces over the Ed25519 curve** — not RFC 8032 EdDSA, so dalek cannot produce it — and the base64 payload is the **advanced** sexp rendering, not canonical encoding. The signed text is everything before the `Signature:` token, and must include StorePath/NarHash/References.)*
2. Provide a `guix archive --authorize`-compatible key-advertisement/authorization workflow, and key distribution over GNS.
3. Fix `test_sign.scm` (correct guile-gcrypt API) or replace it with a real cross-validation test between the Rust and Guile signature formats; add `guile-gcrypt` to `guix.scm`. *(Done 2026-08-18 by stage 30: `test_sign.scm` is now a real sign→verify→tamper suite driving the committed signing helpers, `just scheme-test` is expected green, and `guile-gcrypt` is a `guix.scm` input.)* Note the then-current `test_sign.scm` was doubly broken — it passes a raw `(string->utf8 …)` bytevector to `signature-sexp` (which expects a canonical hash-data s-exp via `bytevector->hash-data`) and uses `key-type-private` (a key-*type* accessor, not a private-key extractor), **and it never verifies the signature it produces**. It is the pattern anyone here will copy, so the replacement MUST round-trip sign→verify.
4. Address `guix.scm` reproducibility (`#:cargo-inputs ()`) so GIPS can be built the offline way it asks users to trust, **and add a `#:select?` predicate** to `(local-file "." …)` so the packaged store item excludes `.git`, `.tools/`, `*.pem`/`*.key`, and stray `gipsd.toml`/`manifest.json` (Stage 20 adds the `.gitignore` guard; the `#:select?` fix is the real containment and belongs here).

**Status:** *(As archived 2026-08-18:)* Executed via stages 29 + 30 for the personal-sync scope (items 1 and 3, plus the authorize-ceremony docs). Items 2 (GNS key distribution) and 4 (`guix.scm` reproducibility / `#:select?`) remain future stages. The limitation in `SECURITY.md` still points here for the remaining design.

## Coordinator notes (2026-08-18)

- **UNPAUSED later on 2026-08-18** by the maintainer; expanded into
  stage 29 (Rust-side Guix-native signing + serve-time signature + key
  export, with a guile-gcrypt oracle test) and stage 30 (Scheme parity
  suite replacing `test_sign.scm`, `guix.scm` guile-gcrypt input, authorize
  workflow docs — authored after 29 merges). Item 2 (key distribution over
  GNS) and item 4's packaging work remain future stages. guile-gcrypt is
  now installed and working on the dev machine.
- **Framing.** Describe this work as *native interoperability with the stock
  Guix substitute-verification model*, not "backward compatibility". GIPS
  already speaks the substitute protocol (narinfo/nar, NarHash/NarSize);
  what is missing is Guix's **trust layer**: libgcrypt canonical
  s-expression Ed25519 signatures over the canonical
  `StorePath/NarHash/NarSize/References` body, and a publisher key a user
  can authorize with `guix archive --authorize`. A hard constraint on any
  interim state: **signature verification stays on** — no step of the plan
  may ask users to pass `--no-check-signature` or otherwise weaken
  client-side checking.
- **Scoping for personal multi-machine sync**
  (`docs/personal-sync-quickstart.md`): items 1 and 3 are the critical path
  (~2 stages — signing-stack swap, then a Rust↔Guile round-trip
  cross-validation test). Item 2 (key advertisement/distribution over GNS)
  is deferrable for personal use, where copying one's own pubkey and
  running `guix archive --authorize` by hand is acceptable ceremony. Item 4
  (`guix.scm` reproducibility / `#:select?`) is packaging hygiene unrelated
  to substitute interop and can be split into its own stage.
- **Environment prerequisite.** The cross-validation tests need
  `guile-gcrypt`, which is not installed on the dev machine
  (`just scheme-test` fails today). The notabug upstream repository is
  gone; build from `https://codeberg.org/guile-gcrypt/guile-gcrypt.git`
  (`autoreconf -vif && ./configure --prefix=/opt/homebrew && make install`;
  `automake` is already installed via Homebrew).
- **Numbering.** The pipeline moved past 22 before this sketch was scheduled;
  it was expanded into stages 29 and 30 rather than run under its own number.
  Archived 2026-08-18 as `completed/stage-22-SKETCH-expanded-into-29-30.md`
  so the non-standard history is legible from the filename; it remains the
  design document the remaining future work (items 2 and 4) cites.

---
