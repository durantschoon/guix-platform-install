# Stage 22 Report

## Findings & Execution

1. **Transfer Code**:
   - Transferred the updated local `gips/` source code to `guix@157.151.255.3:~/gips-src` using `scp`.
   - Before running `build-gips.sh`, observed that `manifest-build.scm` was not included in the environment command, so I updated `~/build-gips.sh` to include `-m manifest-build.scm` to provide `pkg-config` and `openssl`.

2. **Rebuild on Hub**:
   - Started the build on `minius-02` (Hub).
   - The build failed with `error[E0308]: mismatched types` in `gipsd/src/main.rs:154` because of a variable swap during destructuring: `let (ignored, config_file) = match parse_invocation(&arguments) ...`.
   - I patched this locally in the workspace (changing `(ignored, config_file)` to `(config_file, ignored)`), then `scp`'d the updated `main.rs` to the Hub and restarted the build.
   - The build completed successfully on the second try.

3. **Install on Hub**:
   - Unlinked the running `gipsd` binary and copied the newly compiled `gips` and `gipsd` binaries to `~/.local/gips/bin/`.
   - Ran `patchelf --set-rpath /gnu/store/6ayqy32psbfa0nh3l596myd7fccxrkkw-openssl-3.5.7/lib:/gnu/store/pcykzw65y1sqbafly7gpyyxi9n8x6lb4-gcc-16.1.0-lib/lib` on both binaries (referencing the pre-existing `gips-runtime-1` and `gips-runtime-3` GC-roots from `docs/ORACLE_VALIDATION_CHECKPOINT.md`).
   - Verified the binary starts successfully (`env -i ~/.local/gips/bin/gips --help`).

4. **Install on Consumer**:
   - Downloaded the patched binaries from the Hub to the local workspace and uploaded them to `z5-02` (Consumer) at `129.213.123.216`.
   - The identical `patchelf` config worked out-of-the-box since the GC-roots were synced on both nodes previously. Verified `gips --help` successfully.

5. **Restart Daemons**:
   - Killed the old `gipsd` processes (`pkill -f gipsd`).
   - Restarted `gipsd` on both Hub and Consumer nodes as background jobs (`nohup ~/.local/gips/bin/gipsd --config /home/guix/.config/gips/gipsd.toml > ~/gipsd.log 2>&1 &`).
   - Verified the processes are actively running via `pgrep`.

## Completion Status
**SUCCESS**. The updated `gips` binaries with fixes for GNS discovery are fully deployed and running on both live nodes.
