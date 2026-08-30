# Stage 45 — Guix ACL Management Tooling (`/etc/guix/acl`) & Security Threat Model Alignment

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In `SECURITY.md` lines 27–38, the lack of ACL tooling was recorded as a known gap: nothing in GIPS inspected, checked, authorized, revoked, or diffed `/etc/guix/acl`, requiring operators to manually pipe keys into `guix archive --authorize` or manually edit the system ACL file. Additionally, `SECURITY.md` lagged behind Stages 39–44, retaining outdated notes regarding revocation and Sybil resistance.

This stage introduces native Guix ACL management in `components/gips-trust/src/acl.rs`, implements the `gips key acl` CLI subcommand family (`list`, `check`, `authorize`, `revoke`, `diff`), establishes full Guile Scheme REPL parity (`gips-key-acl-*`), and updates `SECURITY.md` to align with the decentralized web-of-trust and objective fraud proof architecture.

## The Change

1. **`components/gips-trust/src/acl.rs` (New Module)**:
   - Implement robust S-expression AST (`Sexp`), tokenizer, and formatter preserving comments and indentation.
   - Implement `GuixAcl` and `AclEntry` data structures representing `/etc/guix/acl` entries (`(entry (public-key ...) (tag (guix import)))`).
   - Implement `parse_acl`, `read_acl`, `write_acl`, `normalize_key_string`, `contains_key`, `authorize`, `revoke`, and `diff_acl`.
   - Re-export ACL types and functions from `components/gips-trust/src/lib.rs`.
   - Comprehensive unit tests covering parsing (ECC Ed25519 and RSA), key extraction, authorization idempotency, revocation, and diffing.

2. **`gips/src/main.rs` (CLI Subcommands)**:
   - Add `Acl` subcommand family under `KeyCommands`:
     - `gips key acl list [--acl-file <path>] [--json]`
     - `gips key acl check [--acl-file <path>] [--key-file <path>] [--name <gns-name>] [--key <raw>]`
     - `gips key acl authorize [--acl-file <path>] [--key-file <path>] [--name <gns-name>] [--key <raw>] [--dry-run]`
     - `gips key acl revoke [--acl-file <path>] [--key-file <path>] [--name <gns-name>] [--key <raw>] [--dry-run]`
     - `gips key acl diff [--acl-file <path>] [--key-file <path> ...] [--json]`

3. **`scheme/gips/api.scm` & `test_api.scm` (Scheme REPL Parity)**:
   - Export and implement `(gips-key-acl-list)`, `(gips-key-acl-check)`, `(gips-key-acl-authorize)`, `(gips-key-acl-revoke)`, and `(gips-key-acl-diff)`.
   - Add Verdict 10 in `test_api.scm` exercising all ACL procedures, dry-run safety, and diffing.

4. **Docs Alignment**:
   - Update `SECURITY.md` aligning protections with Stages 39–44 and adding Guix ACL tooling.
   - Update `docs/personal-sync-quickstart.md`, `README.md`, `docs/TODO.md`, `docs/stages/README.md`, and `docs/user_guide.md`.

## Allowed Files Whitelist

- `components/gips-trust/src/acl.rs` (new)
- `components/gips-trust/src/lib.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `SECURITY.md`
- `README.md`
- `docs/TODO.md`
- `docs/personal-sync-quickstart.md`
- `docs/stages/README.md`
- `docs/user_guide.md`
- `docs/stages/stage-45-PROMPT.md` (or completed)

## Enumerated Tests

1. `components/gips-trust/src/acl.rs` unit tests (parsing, authorization, revocation, diffing, idempotency).
2. `test_api.scm` Verdict 10 (`gips-key-acl-list`, `gips-key-acl-check`, `gips-key-acl-authorize`, `gips-key-acl-revoke`, `gips-key-acl-diff`).
3. `cargo test --all` and `just scheme-test`.

## Definition of Done

- `cargo test --all` passes 100% green.
- `just scheme-test` passes 10/10 verdicts.
- `cargo fmt --check` passes.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-45] feat: Guix ACL management tooling (/etc/guix/acl) and security doc alignment`
