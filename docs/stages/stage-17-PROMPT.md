# Stage 17: GIPS Dependencies as Declared Files

**Goal:** Clean up the GIPS dependency declaration in manifests and the Guix service definition.

## Requirements

1. **Split Manifests**:
   - Split `gips/manifest.scm` into two manifests: a runtime manifest (for nodes running prebuilt binaries, containing only things like `kubo`, `gnunet`, `guile-gcrypt`, etc.) and a build manifest (adding Rust, Cargo, pkg-config, etc.).
2. **Declarative Service Path**:
   - Modify `gips-service-type` (in `lib/guile-config-helper.scm` or wherever `(gips service)` is defined) to either extend or require `kubo` (IPFS) and `gnunet` services, so that adding `(service gips-service-type)` configures a complete working node.
3. **Fix `gips/guix.scm`**:
   - Update `gips/guix.scm` so it includes `kubo`.
   - Leave `#:cargo-inputs` alone if we can't build it via Guix yet, but add a comment explaining why it fails and what inputs are needed.

## Allow-list

- `gips/manifest.scm` (and new manifest files in `gips/`)
- `gips/guix.scm`
- `lib/guile-config-helper.scm` (or wherever `gips-service-type` is)
- `gips/gips.scm` (if needed)
- `docs/stages/stage-17-REPORT.md` (to write your report)

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Ensure `make gips-test` passes.
- Ensure `lib/validate-before-deploy.sh --verbose` exits 0.
- Ensure `./run-tests.sh` exits 0.
- Write your findings, the tests run, and the completion status in `docs/stages/stage-17-REPORT.md`.

