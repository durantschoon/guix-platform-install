# Stage 20: G1.3 Cross Benchmark Boundaries

**Goal:** Cross the boundaries identified in `docs/GIPS_BENCHMARK_PROTOCOL.md` Section 8 on the live `minius-02` (Hub) and `z5-02` (Consumer) nodes to ensure the benchmark harness can run safely and correctly.

## Findings

All 6 boundaries were successfully crossed and verified on the live Oracle micro instances:

1. **Log format (`guix build` logging)**
   - **Check**: Ran `guix gc -D` on `hello`, then `guix build hello --substitute-urls="https://bordeaux.guix.gnu.org"`.
   - **Result**: The output explicitly contained lines like `downloading from https://bordeaux.guix.gnu.org/nar/zstd/...`.
   - **Conclusion**: The benchmark script can reliably parse `downloading from <url>` to attribute downloads.

2. **`guix gc` coldness**
   - **Check**: Ran `guix gc -D /gnu/store/...-hello-2.12.3` on the Consumer.
   - **Result**: The garbage collector successfully deleted the item, reporting `deleting '/gnu/store/...'`. Subsequent builds successfully triggered a cold re-download.
   - **Conclusion**: `guix gc -D` actually deletes the target item, guaranteeing a cold state for Guix.

3. **`ipfs repo gc` coldness**
   - **Check**: Added a test file to IPFS on the Consumer (`ipfs add test.txt`), checked `NumObjects` (11), unpinned the CID, ran `ipfs repo gc`, and checked `NumObjects` again.
   - **Result**: `NumObjects` dropped from 11 to 5, and the `RepoSize` decreased.
   - **Conclusion**: `ipfs repo gc` effectively drops unpinned blocks, satisfying the benchmark's IPFS reset step.

4. **`gipsd` caching**
   - **Check**: Found `hello` in the Consumer's `gipsd.sqlite` database and successfully fetched its `.narinfo` via `curl -s http://127.0.0.1:8080/`. Stopped `gipsd`, moved `gipsd.sqlite` to a backup, and restarted `gipsd`.
   - **Result**: Re-fetching the same `.narinfo` returned HTTP 404.
   - **Conclusion**: `gipsd` holds no secret cache outside of its SQLite database and IPFS. A database wipe reliably resets the daemon.

5. **`gips publish` -> fetchable**
   - **Check**: Built `hello` on the Hub and published it via `gips publish --gns-name gips /gnu/store/...-hello-2.12.3`. This returned an `ipfs_cid` (`QmPvNAB...`). Ran `ipfs cat QmPvNAB...` on the Consumer.
   - **Result**: The Consumer instantly resolved and downloaded the JSON artifact metadata over the libp2p swarm.
   - **Conclusion**: Items published on the Hub are discoverable and fetchable by the Consumer.

6. **`sudo -n`**
   - **Check**: Ran `sudo -n true` via SSH on both the Hub and Consumer.
   - **Result**: Both commands exited 0 with no password prompt.
   - **Conclusion**: The guest user has passwordless sudo access.

## Completion Status
**COMPLETED**. No boundary checks failed. The benchmark design remains valid and safe to execute.
