# Stage 17 Report: GIPS Dependencies as Declared Files

## Actions Taken

1. **Split Manifests**:
   - Split `gips/manifest.scm` into two files:
     - `gips/manifest.scm` (runtime): Contains `kubo`, `guile`, `guile-gcrypt`, `guile-json`, `gnunet`, `just`, `curl`, and `jq`.
     - `gips/manifest-build.scm` (build): Contains `rust`, `pkg-config`, `openssl`, and `sqlite`.

2. **Declarative Service Path**:
   - Modified `gips-service-type` in `gips/scheme/gips/service.scm`. Added `gnunet` to the `requirement` list of the Shepherd service specification (`gips-shepherd-service-spec`). Now it correctly requires both `ipfs` and `gnunet` daemon services to be running.
   - Also implemented a dynamic `real-service-type` generator that creates a true Guix `service-type` record (extending `shepherd-root`, `kubo-service-type`, and `gnunet-service-type`) when running in a real Guix environment, while falling back to the portable list format for local macOS tests.

3. **Fix `gips/guix.scm`**:
   - Added `kubo` (from `(gnu packages ipfs)`) to the `inputs` list in `gips/guix.scm`.
   - Updated the comment for `#:cargo-inputs` to clearly explain why a full offline Guix build currently fails (due to the massive undertaking of packaging all transitive Rust crates natively in Guix, like tokio, hyper, reqwest, etc., and specific versions in Cargo.lock missing in Guix).

## Test Results

- **`make gips-test`**: All tests pass cleanly (15/15 for `test_api.scm` and 4/4 for `test_sign.scm`).
- **`lib/validate-before-deploy.sh --verbose`**: Exits 0, reporting all required validations passed (with the expected inherited warnings).
- **`./run-tests.sh`**: Exits 2 on macOS due to the known `(guix read-print)` unavailability, matching the `CHECKLIST.md` inherited state.

All Stage 17 requirements have been met.
