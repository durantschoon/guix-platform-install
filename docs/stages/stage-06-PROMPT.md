# Stage 06 — Review and reap expired `IN_TEST` resources safely

## Motivation (measured)

Stage 5 froze the versioned one-shot contract and preserved the OV-3 fresh
ownership gate.  The current lifecycle surface can clean up one exact run, but
an interrupted controller can leave an `IN_TEST` instance and local checkpoint
behind.  OV-6 requires a bounded, inspectable way to find stale candidates and
an explicit reaper that never treats expiry as deletion authority.

## The change

1. Add a read-only expired-run review that inventories local validation
   checkpoints and reports candidate facts: exact run directory, run and
   execution identities, recorded instance OCID, expiry, local artifact state,
   and whether the checkpoint is eligible for a fresh ownership read.
2. Add an explicit reaper operation.  It may consider only expired local
   records whose local state is `IN_TEST`, whose exact instance OCID is
   recorded, and whose fresh OCI ownership facts pass the existing OV-3 gate.
   Expiry selects candidates; it never grants deletion authority.
3. Make ambiguity fail closed: missing/malformed records, absent OCIDs,
   `HANDED_OFF`, unknown artifact state, ownership mismatch, and OCI read
   errors are reported as protected/skipped, never mutated.
4. Keep review non-destructive and make reaping attributable with a durable
   per-candidate outcome and machine-readable summary.  Confirmation must be
   explicit (`--yes` only for an already-reviewed invocation), and cleanup
   must target each exact OCID through the existing guarded termination path.
5. Document the command surface, expiry semantics, evidence, and the
   compatibility boundary.  Do not add retention, synchronization, a daemon,
   task joining, or MCP tools.

## Ground rules

- Guile for controller code and tests; ASCII-only console-visible output.
- Parse review/reaper policy once at the boundary; downstream code consumes
  parsed values.
- Expiry is a review datum, not authorization.  Every destructive action must
  pass the existing fresh OV-3 ownership check immediately before termination.
- No OCI credential or private-key path/content enters reports or summaries.
- No new lifecycle state, automatic background process, or cloud mutation
  other than exact-instance termination through the existing gate.  Such an
  expansion is **STOP and ask**.
- Preserve OV-3 ownership, handoff refusal, and OV-5 journal/replay behavior.
- Do not silently adopt resources lacking a matching local record and required
  `managed-by`, `artifact-state`, `run-id`, and exact OCID facts.
- Do not remove existing code; flag unrelated cleanup in the report.

## Allowed files (whitelist)

```
oracle/scripts/validation-common.scm
oracle/scripts/validation-lifecycle.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-validation.scm
docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md
docs/ORACLE_VALIDATION_RUNNER.md
docs/stages/stage-06-REPORT.md
```

Do not edit `Makefile`, `run-tests.sh`, `CHECKLIST.md`,
`SOURCE_MANIFEST.txt`, or any OCI credential/default file.

## Tests (enumerated — all required)

1. Review is read-only and inventories expired, unexpired, malformed, missing,
   and handed-off records with explicit protected/eligible reasons.
2. Reaping requires an exact local OCID and a fresh matching `IN_TEST` ownership
   read; expiry alone never authorizes termination.
3. Handoff markers, unknown/malformed state, missing OCID, mismatched run ID,
   mismatched manager/state, and OCI read failures all fail closed without an
   OCI termination call.
4. A successful reaper fixture terminates exactly the authorized OCID and
   records a durable outcome; a termination failure is distinguishable and
   does not claim success.
5. `--yes` is required only for the mutating reaper path; review remains
   non-destructive and does not require confirmation.
6. Review/reaper summaries carry explicit schema versions, run/execution/
   instance identities, expiry, decision, and evidence paths without secrets.
7. Existing overlap replay, forced-reconnect, ownership, handoff-refusal,
   permanent-loss, schema, policy, and output-bound tests remain green.
8. Source inspection proves this stage added no daemon, MCP server, retained
   instance default, implicit adoption rule, or unrelated cloud mutation.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm   # exit 0
git diff --check                         # exit 0
```

Inherited baseline after Stage 5: validation has 15 warnings and zero
failures; the focused Oracle suite has 94 checks; on macOS `./run-tests.sh`
reaches the documented `(guix read-print)` unavailable boundary and exits 2.
Use the repository's established writable-`GOCACHE` host split and report the
literal commands.  No live acceptance claim is permitted by this stage; its
highest evidence phase is offline controller execution.

## Commit message (exact, single line)

```
feat(oracle): add safe expired-run review and reaper
```

## Report requirements

Write `docs/stages/stage-06-REPORT.md` with: changes per file; review and reaper
schemas with examples; candidate eligibility and fail-closed invariants;
pasted gate output; whitelist audit; deviations; open questions; and an
Unverified claims section naming the highest evidence phase reached.

## Blocked protocol

If safe enumeration requires guessing an instance from OCI inventory, or if
reaping cannot prove the complete local-plus-fresh-remote OV-3 ownership facts
for each exact OCID immediately before termination, stop and write a `Blocked:`
report with the conflicting records and transitions.  Do not widen this stage
into automatic adoption, retained-instance management, or a daemon.
