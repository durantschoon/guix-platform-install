# Stage 22: Deploy Updated GIPS Binaries to Live Nodes

**Goal:** Redeploy the latest compiled `gips` and `gipsd` binaries to the live Hub (`minius-02`) and Consumer (`z5-02`) nodes, so they have the GNS discovery fixes and manifest changes from Stages 16-19.

## Context

- The live nodes are currently running old `gips` binaries from 2026-09-21, which still attempt to use the broken `gnunet-gns` with record type 65536.
- The local codebase has fixes for GNS discovery (`gnunet-namestore`, record type 16, etc.) which need to be deployed.
- **Hub (`minius-02`)**: `157.151.255.3` (private `10.0.0.71`)
- **Consumer (`z5-02`)**: `129.213.123.216` (private `10.0.0.225`)

## Requirements

1. **Transfer Code**:
   - `rsync` the local `gips/` directory to `guix@157.151.255.3:~/gips-src`. (Exclude `target/` to save bandwidth).

2. **Rebuild on Hub**:
   - SSH into the Hub (`157.151.255.3`) and run `~/build-gips.sh`. This script was set up previously to build the GIPS binaries using Guix and Cargo.
   - Wait for the build to complete. Ensure it completes successfully.

3. **Install on Hub**:
   - The newly built binaries will be in `~/gips-src/target/release/gips` and `gipsd`.
   - Update `~/.local/gips/bin/gips` and `~/.local/gips/bin/gipsd` with the new binaries on the Hub. (You may need to `patchelf --set-rpath` them as was done previously, check `docs/ORACLE_VALIDATION_CHECKPOINT.md` line 16).

4. **Install on Consumer**:
   - Transfer the newly built binaries from the Hub to the Consumer (`129.213.123.216`). (You can download them locally and then upload them to the Consumer, or use `guix archive`).
   - Update `~/.local/gips/bin/gips` and `~/.local/gips/bin/gipsd` on the Consumer. (Ensure they are also patchelf'd if necessary, or transfer the GC-rooted dependencies).

5. **Restart Daemons**:
   - Restart the `gipsd` daemon on both nodes so they pick up the new binary.

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Be mindful of the 1 GiB memory limits on these instances (compiling might take time, use `CARGO_BUILD_JOBS=1`).
- Write your findings, the exact commands run, and the completion status in `docs/stages/stage-22-REPORT.md`.
- **STOP and ask** if the build fails.

## Allow-list

- Live OCI instances (`157.151.255.3` and `129.213.123.216`)
- `docs/ORACLE_VALIDATION_CHECKPOINT.md`
- `docs/stages/stage-22-REPORT.md`

