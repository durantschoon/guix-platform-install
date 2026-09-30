# Stage 21: G1.4 Benchmark Pilot Run

**Goal:** Execute the G1.4 Pilot run (2 blocks of the `small` workload) on the live Oracle instances to confirm the benchmark harness operates correctly end-to-end, and that `rx_bytes` are plausible for all arms.

## Requirements

1. **Hub Preparation**:
   - Run the `hub-prepare` step using the `oracle/benchmark/workload-small.scm` manifest, outputting to e.g., `/tmp/wl-small`.
   - Ensure the GNS name used is `bench.gnu`.
   - Start the two control arms on the Hub: `sudo guix publish --port=8081 -C none` and `sudo guix publish --port=8082 -C zstd --cache=/var/cache/guix/publish` (ensure the cache directory exists).

2. **Consumer Execution**:
   - Ensure the Consumer is subscribed to `bench.gnu`.
   - Copy or transfer the `workload.paths` and `workload.closure` files from the Hub to the Consumer (or run them via SSH streams). Note that `hub-prepare` generates these files on the Hub, but `preflight` and `run` must be run on the Consumer.
   - Run `preflight` on the Consumer.
   - Run `run` on the Consumer with `--workload small`, `--blocks 2`, and `--seed 20260920`. Provide the Hub's private IP (`10.0.0.71`) for the `--publish-none-url` and `--publish-zstd-url`.

3. **Validation**:
   - Confirm every row in the resulting TSV file has a status of `ok`.
   - Inspect the `rx_bytes` for the `central` and `gips` arms to ensure they are plausible.

## Context

- **Hub (`minius-02`)**: `157.151.255.3` (private `10.0.0.71`)
- **Consumer (`z5-02`)**: `129.213.123.216` (private `10.0.0.225`)
- Both guests are accessible via `ssh -i ~/.ssh/id_ed25519_guix_oracle guix@<ip>`.

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Be mindful of the 1 GiB memory limits on these instances.
- Include the resulting TSV rows in your report.
- Write your findings, the exact commands run, and the completion status in `docs/stages/stage-21-REPORT.md`.
- **STOP and ask** if any rows fail or if `rx_bytes` are implausible.

## Allow-list

- Live OCI instances (`157.151.255.3` and `129.213.123.216`)
- `docs/ORACLE_VALIDATION_CHECKPOINT.md` (to update the checkpoint with the result)
- `docs/stages/stage-21-REPORT.md` (to write your report)

