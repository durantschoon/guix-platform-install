# Stage 21 Report

## Execution Summary
- Connected to Hub (`157.151.255.3`) and Consumer (`129.213.123.216`).
- Started the control arms on the Hub (`publish none` on 8081, `publish zstd` on 8082).
- Executed `hub-prepare` on the Hub using `oracle/benchmark/workload-small.scm`.
  - The script realized the manifest and successfully wrote `workload.paths` and `workload.closure` (22 items) to `/tmp/wl-small`.
  - It invoked `gips publish` which attempted to publish the 22 items to `bench.gnu`.
- Transferred `/tmp/wl-small/workload.closure` and `workload.paths` to the Consumer.
- Subscribed the Consumer to `bench.gnu` via `gips subscribe bench.gnu`.
- Ran `preflight` on the Consumer to check if both arms were available.

## Findings & Blockers
The `preflight` step failed on the Consumer for the `gips` arm:
```
[OK]   central: 22/22 narinfos available
[FAIL] gips: 0/22 narinfos available
...
[ERROR] preflight failed; do not start trials
```
**Root cause analysis:**
1. The GNS discovery mechanism (`gnunet-gns`) is not installed on the Consumer. The wrapper script `/home/guix/.local/gips/bin/gns_wrapper.sh` attempts to call `/home/guix/.guix-profile/bin/gnunet-gns`, which does not exist.
2. Even if it did exist, the Rust GNS client (`GnsClient::resolve`) expects the wrapper to output a single valid CID string (46-64 alphanumeric chars). However, `hub-prepare` publishes 22 separate narinfos to `bench.gnu`, which would result in multiple CIDs. 
3. Because `preflight` failed, the Consumer's local `gipsd` did not fetch the substitute narinfos, leaving `0/22` available.

Due to the explicit prompt instruction: **"STOP and ask if any rows fail or if rx_bytes are implausible"**, execution of the `run` command was halted. The issue perfectly matches the stated blocker **G1.1b** ("hub -> spoke sync has probably never worked live").

## Commands Run
**Hub:**
```sh
guile --no-auto-compile -s ~/oracle/scripts/gips-benchmark.scm hub-prepare --manifest ~/oracle/benchmark/workload-small.scm --out-dir /tmp/wl-small --publish --gns-name bench.gnu
sudo nohup guix publish --port=8081 -C none > /tmp/guix-publish-8081.log 2>&1 &
sudo nohup guix publish --port=8082 -C zstd --cache=/var/cache/guix/publish > /tmp/guix-publish-8082.log 2>&1 &
```

**Consumer:**
```sh
gips subscribe bench.gnu
guile --no-auto-compile -s ~/oracle/scripts/gips-benchmark.scm preflight --closure /tmp/wl-small/workload.closure
```

## Completion Status
**BLOCKED**. The pilot benchmark cannot proceed past `preflight` because cross-machine discovery (GNS) is broken (G1.1b), preventing the Consumer's GIPS daemon from retrieving narinfos from the Hub.
