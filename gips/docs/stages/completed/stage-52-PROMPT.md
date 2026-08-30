# Stage 52 — Guix Package Definition & Static Distribution Harness (`gips.scm`)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

For users deploying GIPS via GNU Guix or integrating GIPS into channels and operating system definitions, a top-level `gips.scm` package file and `(gips package)` module allows running `guix build -f gips.scm`, `guix shell -f gips.scm`, or referencing `(package (inherit gips) ...)` in custom channel manifests.

## The Change

1. **Guix Package Module (`scheme/gips/package.scm` & `gips.scm`)**:
   - Define `<gips-package-description>` / `gips` package record with:
     - `name`: `"gips"`
     - `version`: `"0.1.0"`
     - `build-system`: `cargo-build-system`
     - `synopsis`: `"Guix IPFS Substitute Daemon and Peer-to-Peer Mirror Fabric"`
     - `description`: Detailed description covering substitute serving, web-of-trust verification, and offline snapshotting.
     - `home-page`: `"https://github.com/ds/GIPS"`
     - `license`: `"GPL-3.0-or-later"`
   - Create root `gips.scm` entrypoint for direct `guix build -f gips.scm` invocation.

2. **Justfile Release Recipes (`Justfile`)**:
   - Add `package` and `dist` recipes.

3. **Scheme REPL Parity & Test Suite (`test_api.scm`)**:
   - Add Verdict 15 in `test_api.scm` validating package record properties, synopsis, version, and license attributes.

4. **Documentation**:
   - Update `README.md`, `docs/user_guide.md`, and `docs/TODO.md`.

## Allowed Files Whitelist

- `scheme/gips/package.scm`
- `gips.scm`
- `Justfile`
- `test_api.scm`
- `README.md`
- `docs/user_guide.md`
- `docs/TODO.md`
- `docs/stages/stage-52-PROMPT.md` (or completed)

## Enumerated Tests

1. `test_api.scm` Verdict 15 (`(gips package)` package definition validation)
2. `just scheme-test`
3. `cargo test --all`

## Definition of Done

- All 15 verdicts in `test_api.scm` hold.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.

## Commit Message

`[stage-52] feat: standalone Guix package definition (gips.scm) and packaging recipes`
