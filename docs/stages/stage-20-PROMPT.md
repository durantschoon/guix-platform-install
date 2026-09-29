# Stage 20: G1.3 Cross Benchmark Boundaries

**Goal:** Cross the boundaries identified in `docs/GIPS_BENCHMARK_PROTOCOL.md` Section 8 on the live `minius-02` (Hub) and `z5-02` (Consumer) nodes to ensure the benchmark harness can run safely and correctly.

## Boundaries to Cross

1. **Log format (`guix build` logging)**: Verify that `guix build --substitute-urls=...` actually logs `downloading from <url>` for each item, so the benchmark script can attribute the download correctly.
2. **`guix gc` coldness**: Fetch a test item on the Consumer, then run `guix gc`. Verify that the item (and its closure) is actually deleted from the store, ensuring subsequent fetches are truly cold.
3. **`ipfs repo gc` coldness**: (Note: The protocol says the mirror worker pins everything, so we now unpin and gc in the reset step. Verify that the reset command `ipfs pin ls --type recursive | ... unpin` followed by `ipfs repo gc` actually drops the fetched blocks).
4. **`gipsd` caching**: Ensure that fetching the same item twice after a reset (including restarting `gipsd`) doesn't magically use zero `rx_bytes`, proving no hidden consumer-side cache exists outside of IPFS.
5. **`gips publish` -> fetchable**: Verify that publishing an item on the Hub makes it discoverable and fetchable via the Consumer (which we largely proved in G1.2, but confirm for a multi-file package like `hello`).
6. **`sudo -n`**: Verify the guest user (`guix`) on both nodes can run `sudo -n true` without a password prompt.

## Context

- **Hub (`minius-02`)**: `157.151.255.3` (private `10.0.0.71`)
- **Consumer (`z5-02`)**: `129.213.123.216` (private `10.0.0.225`)
- Both guests are accessible via `ssh -i ~/.ssh/id_ed25519_guix_oracle guix@<ip>`.

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Be mindful of the 1 GiB memory limits on these instances.
- Write your findings, the exact commands run, and the completion status in `docs/stages/stage-20-REPORT.md`.
- **STOP and ask** if any of these boundary checks fail, as they invalidate the benchmark design.

## Allow-list

- Live OCI instances (`157.151.255.3` and `129.213.123.216`)
- `docs/ORACLE_VALIDATION_CHECKPOINT.md` (to update the checkpoint with the result)
- `docs/stages/stage-20-REPORT.md` (to write your report)

