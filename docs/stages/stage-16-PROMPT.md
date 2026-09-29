# Stage 16: GIPS GNS Discovery Fix

**Goal:** Implement real GNUnet Name System (GNS) discovery for GIPS. Replace the invalid `gnunet-gns record ...` command with the correct `gnunet-namestore -a` invocation. 

## Requirements

1. **GIPS Source Update**: 
   - Modify the Rust source code in `../GIPS` to use `gnunet-namestore -a -n LABEL -t TXT -V VALUE -e 1h -p` for publishing records, replacing the invalid `gnunet-gns record` command.
   - The resolution side (`gnunet-gns -u`) is already correct, but verify it.
   - Run the Rust tests in `../GIPS` to ensure they pass.
2. **Reconcile Copies**: 
   - Copy the updated Rust source files from `../GIPS` to the `gips/` directory in this repository.
   - Update `gips/README.md` if necessary to reflect the correct GNS commands.
3. **Helper Scripts**:
   - Create or update helper scripts (e.g., `make gips-hub-setup`, `make gips-spoke-setup` in `gips/justfile` or `Makefile`) to document and automate the creation of the GNUnet ego on the hub, and the configuration on the spoke so the two peers connect.

## Allow-list

- `../GIPS/` (all files)
- `gips/` (all files)
- `docs/stages/stage-16-REPORT.md` (to write your report)

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Ensure `make gips-test` passes.
- Ensure `lib/validate-before-deploy.sh --verbose` exits 0.
- Ensure `./run-tests.sh` exits 0.
- Write your findings, the tests run, and the completion status in `docs/stages/stage-16-REPORT.md`.
- **STOP and ask** if you encounter issues building or running GNUnet locally.

