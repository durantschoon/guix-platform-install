# Stage 18: GIPS Config Flag Fix

**Goal:** Address the flagged issue where `gipsd` ignores the `--config PATH` flag.

## Requirements

1. **Fix `gipsd` config flag**:
   - Update `../GIPS` (likely in `src/bin/gipsd.rs` or similar) so that `gipsd` actually parses and honours the `--config PATH` flag, rather than just logging a warning and falling back to the default location.
2. **Reconcile Copies**:
   - Copy the updated Rust source files from `../GIPS` to `gips/`.
3. **Verify Callers**:
   - Verify that `make gips-start` and the benchmark's default `--gipsd-start` correctly pass the flag and that `gipsd` now respects it.

## Allow-list

- `../GIPS/` (all files)
- `gips/` (all files)
- `oracle/scripts/` (if updating benchmark defaults)
- `docs/stages/stage-18-REPORT.md` (to write your report)

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Ensure `make gips-test` passes.
- Ensure `lib/validate-before-deploy.sh --verbose` exits 0.
- Ensure `./run-tests.sh` exits 0.
- Write your findings, the tests run, and the completion status in `docs/stages/stage-18-REPORT.md`.

