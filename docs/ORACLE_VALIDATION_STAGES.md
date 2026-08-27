# Oracle validation staged work plan

These `OV-*` stages are the canonical execution order for the disposable OCI
validator.  They are distinct from the repository-wide delegated stages under
`docs/stages/` and from the validator's user-facing `Stage 0` probe and
`Stage 1` one-shot command names.

Only one `OV-*` stage is active at a time.  Every live action updates
`ORACLE_VALIDATION_CHECKPOINT.md`.  Live artifacts follow
`ORACLE_TEST_ARTIFACT_LIFECYCLE.md`.

## Status

| Stage | Outcome | Status |
|---|---|---|
| OV-0 | Controller foundation and measured failure | complete |
| OV-1 | Reliable guest metadata-key installation | complete |
| OV-2 | Live metadata-only SSH acceptance | complete |
| OV-3 | Executable `IN_TEST` ownership gate | complete |
| OV-4 | Live one-shot validation acceptance | complete |
| OV-5 | Resilient telemetry and recovery | complete |
| OV-6 | One-shot release and forward-compatible hardening | complete |

## OV-0 — Controller foundation and measured failure

Delivered:

- Stage 0 metadata-only probe and Stage 1 one-shot controller.
- Offline validation suite, local state, evidence capture, and cleanup policy.
- macOS OCI CLI discovery, Make targets, ignored `.env` defaults, and restart
  checkpoint.
- `IN_TEST` / `HANDED_OFF` lifecycle design.
- Two live failures with evidence.  The latest proved OCI held the exact
  intended public key and IMDSv2 was enforced, but SSH returned `Permission
  denied (publickey)`.
- Latest diagnostic instance and boot volume terminated successfully.

Exit gate: measured failure is locally preserved and no diagnostic instance is
left running.  **Passed 2026-08-25.**

## OV-1 — Reliable guest metadata-key installation

Objective: make the image install OCI metadata keys after networking is truly
usable and leave enough serial evidence to diagnose every outcome.

Work:

1. Replace the single metadata fetch attempt with bounded retry/backoff.
2. Log attempt count and the final outcome without logging key material.
3. Make service completion mean either a key was installed or the bounded
   policy was exhausted; do not silently turn a failed OCI fetch into success.
4. Verify ownership and modes for `/home/guix`, `.ssh`, and
   `.ssh/authorized_keys`.
5. Add offline tests for retry policy, JSON/raw leaf normalization, key
   filtering, destination, permissions, and secret-free logging.
6. Add an explicit timeout to reusable OCI status operations observed to hang.

Constraints:

- No live instance is launched in this stage.
- No private key or OCI credential enters the image, repository, logs, or
  guest.
- Preserve the baked-key path for personal images.

Exit gates:

```sh
make oracle-test
./run-tests.sh
git diff --check
```

The image configuration must evaluate both with and without
`oracle/image/authorized-key.pub`.  Runtime success remains labelled unverified
until OV-2.

**Passed 2026-08-25.** Host pre-deploy validation reported 6 passed, 15
warnings, 0 failures with a sandbox-safe Go cache. Go suites passed locally.
Because macOS bare Guile lacks Guix modules and the local Guix container lacks
Go, the full gate was executed as an equivalent split: every Guile/Guix suite
passed in the existing local Guix container. The literal host
`./run-tests.sh` remains environment-blocked at `(guix read-print)`; this is not
an OV-1 regression.

## OV-2 — Live metadata-only SSH acceptance

Entry gate: OV-1 is complete and a generic keyless image has been built and
imported.  Update `ORACLE_IMAGE_ID` in `.env` before launch.

Work:

1. Run `make oracle-stage0` with a fresh ephemeral SSH key.
2. Capture instance, VNIC, serial-console, SSH, result, and termination
   evidence locally.
3. Prove `guix` login and passwordless sudo with the supplied key.
4. Confirm password authentication is disabled and IMDSv1 remains disabled.
5. Terminate the exact test OCID and its boot volume after evidence collection.

Exit gate: a live run returns status 0, the evidence identifies the image and
source state, and OCI confirms `TERMINATED`.  Otherwise return to OV-1 with the
new measured failure; do not advance.

**Passed 2026-08-26.** Run `20260826T040146Z-b39-9e2ba` accepted the key
supplied only through instance metadata and the disposable instance terminated.

## OV-3 — Executable `IN_TEST` ownership gate

**Passed 2026-08-26.** Run `20260826T103552Z-f33-2b88d` passed through the
fresh ownership gate and its exact instance reached `TERMINATED`. Run
`20260826T104020Z-34fa-6776a` was retained after a declared `exit 7`, handed
off local-first, confirmed `HANDED_OFF` by fresh OCI read, and then rejected by
guarded cleanup. The unrelated Oracle Linux instance was read only.

Entry gate: OV-2 passes, so lifecycle automation can be tested on a working
disposable path.

Work:

1. Extend local state with `managed-by`, `artifact-state`, `run-id`, resource
   type, exact OCID, and declared operation scope.
2. Add fresh OCI-tag reads and a pure comparison function.
3. Permit mutation/deletion only when local and OCI ownership facts all match.
4. Implement fail-safe `handoff`: local `HANDED_OFF` first, OCI tag second,
   confirmation third.
5. Add human-facing `make oracle-handoff` and narrowly scoped cleanup/status
   targets.  Do not add a generic name-based destroy target.
6. Test absent tags, mismatched run IDs, stale state, interrupted handoff,
   already-terminated resources, and protected resources.

Exit gate: offline tests prove every mismatch blocks mutation, followed by one
live `IN_TEST` cleanup and one live `HANDED_OFF` refusal.  The unrelated Oracle
Linux instance must never be used as a fixture.

## OV-4 — Live one-shot validation acceptance

Entry gates: OV-2 passes and OV-3 cleanup protection is executable.

Work:

1. Run `make oracle-stage1 COMMAND='./run-tests.sh'` and record a passing run.
2. Run a declared failing command and prove its nonzero status is preserved.
3. Verify both instances terminate by default and their boot volumes are not
   preserved.
4. Verify source manifest/run ID/command are written before remote execution.
5. Verify no OCI credential path or content reaches the guest.

Exit gate: passing and failing live evidence satisfies every Stage 1 criterion
in `ORACLE_VALIDATION_RUNNER.md`.

**Passed 2026-08-26 for the one-shot pass/fail contract.** Run
`20260826T040957Z-556e-be8fb` passed; run
`20260826T041155Z-5ed1-4bec7` preserved the declared `exit 7` failure. Both
instances terminated. This evidence does not complete OV-3's fresh-tag
ownership gate.

## OV-5 — Resilient telemetry and recovery

Status: complete. The JSONL event/replay layer rejects malformed records and
sequence gaps while allowing an overlapping prefix after reconnect. Live
forced-disconnect and permanent guest-loss acceptance both passed with fresh
OCI ownership-gated cleanup.

Work:

- Sequenced JSONL remote journal and local event stream.
- Heartbeats, bounded OCI lifecycle polling, and periodic console capture.
- SSH reconnect/replay without event gaps.
- `status`, `logs`, `collect`, and `stop` commands with Make entry points.
- Explicit timeouts for every network wait.

Exit gate passed 2026-08-27: forced SSH interruption run
`20260826T190730Z-171ae-ef956` replayed contiguous events 1..6; permanent
guest-loss run `20260826T235720Z-b317-de56f` retained events and console/lifecycle
evidence and classified the terminated guest before a result.

## OV-6 — One-shot release and forward-compatible hardening

Status: complete. The bounded one-shot release candidate passed its live
acceptance run on 2026-08-27. Run `20260827T201856Z-dd6f-661af` transferred the
hashed source snapshot, executed a hash of the transferred `SOURCE_MANIFEST.txt`
with result 0, preserved versioned evidence, and the exact instance was
confirmed `TERMINATED` by a fresh OCI read. Two earlier runs deliberately used
files outside the transferred working directory; both returned command-failure
and terminated cleanly, so they remain diagnostic evidence rather than release
evidence.

The release milestone is intentionally narrower than a Runpod-like compute
service: remotely run one declared computation that requires a live Guix
environment, return attributable evidence, and clean up the disposable
instance. Retaining an instance for later tasks and exposing MCP tools are
post-release work, but this release must not conflate instance, execution, and
source identities in a way that blocks them.

The repository-wide stage sequence in `docs/stages/` implements OV-6:

1. **Stage 05 — bounded one-shot contract.** Freeze versioned request, status,
   and result shapes; keep instance/execution/source identities distinct; add
   duration, output, shape, and command policy with fail-closed parsing.
2. **Stage 06 — expired-resource lifecycle.** Add read-only stale-run review,
   then an explicit reaper that can act only through the OV-3 fresh ownership
   gate. Expiry selects candidates; it never grants deletion authority.
3. **Stage 07 — release candidate (active).** Package the non-interactive entry point,
   document human and coding-agent use, complete restart-from-checkpoint
   rehearsal, and prepare the live acceptance checklist.

OV-6 exits only after a live release-acceptance run executes a declared
computation from a hashed snapshot, produces the versioned result/evidence,
and confirms the exact disposable instance `TERMINATED`. That live action is a
human/coordinator gate, not delegated implementation.

Deferred, explicitly not OV-6 release blockers:

- **Stage 08 — retained instance.** Multiple explicitly hashed executions may
  join one instance without result misattribution.
- **Stage 09 — MCP facade.** Typed create/run/status/logs/handoff/terminate
  tools wrap the proven controller. No third-party credential-accepting
  service is introduced.

## Stage transition rule

At each transition:

1. Preserve evidence and update the checkpoint.
2. Run the stage's local gates.
3. Regenerate `SOURCE_MANIFEST.txt` if covered files changed.
4. Mark exactly one next stage active here and in `CHECKLIST.md`.
5. Commit a coherent checkpoint before starting a costly live operation.
