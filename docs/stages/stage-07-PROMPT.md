# Stage 07 — Package and rehearse the one-shot release candidate

## Motivation (measured)

OV-4 and OV-5 passed live acceptance, and Stage 05 froze the versioned bounded
one-shot contract. Stage 06 added read-only expired-run review and a guarded
reaper. The pieces are usable from source, but the OV-6 release boundary still
needs one discoverable non-interactive entry point, a restart rehearsal, and a
single checklist that states exactly what remains live-only. Without that
packaging, a caller must reconstruct the controller invocation and can confuse
offline evidence with release evidence.

## The change

1. Package the existing bounded one-shot controller behind one documented,
   non-interactive entry point. Preserve explicit source, image, subnet, and
   command inputs; do not hide cloud mutation or confirmation policy.
2. Add focused offline coverage for the entry point's argument forwarding,
   restart-from-checkpoint rehearsal, output/result evidence paths, and refusal
   of ambiguous or terminal checkpoints.
3. Document human and coding-agent invocation, required local inputs, expected
   result/evidence files, restart semantics, and the exact live release gate.
4. Make the release checklist explicit: a live run must execute a declared
   computation from a hashed snapshot, return the versioned result, and confirm
   the exact disposable instance `TERMINATED`.
5. Keep this stage offline. Do not launch, terminate, or otherwise mutate OCI
   resources, and do not claim OV-6 complete.

## Ground rules

- Guile for controller code and tests; ASCII-only console-visible output.
- Preserve Stage 05 identity, policy, truncation, and result schemas.
- Preserve Stage 06 fail-closed review/reaper and OV-3 fresh ownership gates.
- Restart may resume only a non-terminal checkpoint with an exact recorded
  identity; it must never guess an instance or silently adopt a resource.
- No retained-instance default, synchronization, daemon, task joining, MCP
  facade, or new cloud mutation. Any such expansion is **STOP and ask**.
- No credentials or private-key paths/content in examples, reports, or tests.
- Do not edit `CHECKLIST.md` or `SOURCE_MANIFEST.txt`; the coordinator owns
  those shared files.

## Allowed files (whitelist)

```
Makefile
oracle/scripts/validation-common.scm
oracle/scripts/validation-lifecycle.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-validation.scm
oracle/README.md
docs/ORACLE_VALIDATION_RUNNER.md
docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md
docs/stages/stage-07-REPORT.md
```

## Tests (enumerated — all required)

1. The packaged entry point forwards explicit source/image/subnet/command
   inputs without credentials or hidden defaults.
2. Restart-from-checkpoint rehearsal round-trips a resumable checkpoint and
   refuses terminal, handed-off, malformed, or identity-ambiguous records.
3. Result and evidence paths retain run, execution, instance, and source
   identities without substitution or secret material.
4. Existing Stage 05 policy, output-bound, schema, and Stage 06 review/reaper
   checks remain green.
5. Source inspection proves no retained-instance default, daemon, MCP facade,
   implicit adoption, or unrelated cloud mutation was added.
6. Documentation names the highest verified phase and separates offline
   rehearsal from the still-human live release gate.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm   # exit 0
git diff --check                         # exit 0
```

Inherited baseline after Stage 06: validation has 15 warnings and zero
failures with the refreshed manifest; the focused Oracle suite has 100 checks.
On macOS `./run-tests.sh` reaches the documented `(guix read-print)` boundary
and exits 2. Use the established writable-`GOCACHE` split and report literal
commands. No live acceptance claim is permitted by this stage.

## Commit message (exact, single line)

```
feat(oracle): package one-shot release candidate
```

## Report requirements

Write `docs/stages/stage-07-REPORT.md` with: changes per file; packaged command
examples; restart rehearsal evidence; release checklist; pasted gate output;
whitelist audit; deviations; open questions; and an Unverified claims section
naming the highest evidence phase reached.

## Blocked protocol

If packaging requires guessing missing resource identifiers, changing the
ownership model, or performing live OCI mutation, stop and write a `Blocked:`
report with the exact missing boundary. Do not widen this stage into retained
instances, MCP tooling, or live acceptance.
