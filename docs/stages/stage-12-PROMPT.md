# Stage 12 — Multi-Node Disposable Cloud Validation for GIPS

## Motivation (measured)

Stage 10 integrated the GIPS subsystem and Stage 11 provided declarative system service integration. The next critical milestone is validating GIPS in live and disposable cloud execution environments (Oracle Cloud Always Free and Cloudzy VPS) using the proven OV validation machinery.

Without disposable cloud validation, assumptions regarding network firewalling, IPFS NAT traversal across cloud tenancies, and substitute download verification across distinct machines remain unmeasured.

## The change

1. Define a disposable validation workload that:
   - Launches a disposable Guix guest instance using the OV-6 validation controller (`oracle/scripts/validate.scm`).
   - Provisions `ipfs` and `gipsd` on the disposable instance.
   - Publishes a deterministic Guix store path to the IPFS swarm.
   - Retrieves the substitute `.narinfo` and `.nar` archive over wire on a separate node.
   - Validates cryptographic signature verification, bit-for-bit NAR integrity, and hash matching.
2. Build offline test harnesses covering the validation workload command runner, request/result schemas, and evidence collection.
3. Record evidence boundaries separating offline simulation from human-authorized live cloud acceptance runs.

## Ground rules

- No live cloud instances are launched without explicit human authorization.
- Disposable instances must carry exact `IN_TEST` ownership tags and terminate cleanly upon test completion.
- Fail-closed error handling and evidence capture: all telemetry and journals must be archived under `.oracle-validation/runs/<run-id>/`.
- No third-party credentials or private keys may be leaked into logs, arguments, or result files.
- Guile for all controller and workload scripts; ASCII-only console output.

## Allowed files (whitelist)

```
oracle/scripts/gips-validation-workload.scm
oracle/tests/test-gips-cloud-validation.scm
oracle/scripts/oracle-scripts_purpose.txt
docs/ORACLE_VALIDATION_RUNNER.md
docs/stages/stage-12-REPORT.md
```

## Tests (enumerated — all required)

1. Workload generator constructs deterministic store path publishing and retrieval commands without hardcoded secrets.
2. Result parser verifies that successful runs validate `.narinfo` signature status, NarHash match, and byte size.
3. Network error simulation validates that unreachable peers or hash mismatches produce classified failure results rather than unhandled crashes.
4. Telemetry events from the GIPS validation workload conform to the OV-5 sequenced JSONL schema.
5. All 24 Oracle capacity tests, 105 Oracle validation tests, and 19 GIPS Scheme verdicts remain green.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0
make oracle-test                          # exit 0
guile --no-auto-compile -s oracle/tests/test-gips-cloud-validation.scm  # exit 0
git diff --check                         # exit 0
```

## Commit message (exact, single line)

```
feat(oracle): add disposable cloud validation harness for GIPS substitutes
```

## Report requirements

Write `docs/stages/stage-12-REPORT.md` with:
- Summary of changes per file.
- Workload schema and verification commands.
- Offline simulation evidence.
- Live release checklist (gated on human authorization).
- Pasted gate output.
- Whitelist audit.
- Unverified claims section.

## Blocked protocol

If disposable execution requires exposing unverified IPFS ports or modifying tenancy firewall rules without explicit user confirmation, stop and report `Blocked:`. Do not bypass the OV-3 fresh ownership gate.
