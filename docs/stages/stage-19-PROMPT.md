# Stage 19: G1.2 Live End-to-End Substitute Verification

**Goal:** Execute G1.2 on the live Oracle instances. Demonstrate that the Hub and Consumer nodes can use GIPS to serve and fetch one substitute end-to-end.

## Context

- **Hub (`minius-02`)**: `157.151.255.3` (private `10.0.0.71`)
- **Consumer (`z5-02`)**: `129.213.123.216` (private `10.0.0.225`)
- Both guests are accessible via `ssh -i ~/.ssh/id_ed25519_guix_oracle guix@<ip>`.

## Requirements

1. **Daemon Setup**:
   - Ensure `ipfs` (Kubo), `gnunet`, and `gipsd` are running on both nodes. You may need to use `guix shell` or the updated `gips/manifest.scm` to install them if they aren't fully set up yet.
   - Start the daemons (e.g., using the `just start` or `make gips-start` commands in the `gips` directory on the instances).

2. **GNS Peer Discovery**:
   - On the Hub, run `just hub-setup` to create the ego and get the HELLO URI.
   - On the Consumer, run `just spoke-setup "<hello-uri>"` to connect to the Hub.
   - Verify that the consumer can resolve the hub's GNS record.

3. **End-to-End Substitute Transfer**:
   - On the Hub, pick a small package (e.g., `hello` or a simple text file added to the store) and publish it to IPFS and GNS using GIPS (`gips publish` or the `create_snapshot.scm` helper).
   - On the Consumer, ensure the local cache/store does *not* already have this item.
   - On the Consumer, fetch it using Guix pointing *only* at the local GIPS daemon: `guix build /gnu/store/...-item --substitute-urls=http://127.0.0.1:8080`.
   - Capture the output demonstrating that the substitute was successfully fetched over IPFS/GIPS.

## Allow-list

- Live OCI instances (`157.151.255.3` and `129.213.123.216`)
- `docs/ORACLE_VALIDATION_CHECKPOINT.md` (to update the checkpoint with the result)
- `docs/stages/stage-19-REPORT.md` (to write your report)

## Instructions for Executor

- Do NOT touch `CHECKLIST.md` or `docs/stages/README.md`.
- Be mindful of the 1 GiB memory limits on these instances.
- Write your findings, the exact commands run, and the completion status in `docs/stages/stage-19-REPORT.md`.
- **STOP and ask** if you encounter persistent connection issues or daemon crashes.

