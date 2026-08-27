# Stage 08 — Retained-instance executions on the OV-backed controller

## Motivation (measured)

OV-6 now provides a live-accepted one-shot controller with versioned request,
result, checkpoint, source-hash, evidence, and exact-instance ownership facts.
The deferred retained-instance feature must build on those measured boundaries;
otherwise a second execution loop could silently misattribute a result to a
later source snapshot or bypass the cleanup gate.

## The change

1. Add an explicitly opt-in retained-instance mode while preserving one-shot as
   the default and keeping instance, execution, and source identities distinct.
2. Give every execution its own source hash, execution ID, command, policy,
   journal/result, and evidence directory using the OV-6 schemas.
3. Reuse OV-3 ownership and OV-5 replay/lifecycle evidence for handoff, stop,
   reconnect, guest loss, and final cleanup. No display-name discovery or
   implicit adoption is permitted.
4. Add bounded synchronization and task-join semantics with explicit refusal
   on stale, ambiguous, terminal, or handed-off checkpoints.
5. Document the compatibility boundary and prove one-shot behavior is unchanged.

## Ground rules

- No change to the proven one-shot default or its live acceptance contract.
- No new credential path, daemon, MCP server, or unbounded background process.
- Every execution consumes one immutable source snapshot and emits one
  attributable versioned result.
- Retained resources remain behind explicit ownership, TTL, handoff, and
  termination controls. Any weakened gate is **STOP and ask**.

## Allowed files (whitelist)

```
oracle/scripts/validation-common.scm
oracle/scripts/validation-lifecycle.scm
oracle/scripts/validate.scm
oracle/scripts/validation-guest-runner.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-validation.scm
docs/ORACLE_VALIDATION_RUNNER.md
docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md
docs/stages/stage-08-REPORT.md
```

Do not edit `Makefile`, `run-tests.sh`, `CHECKLIST.md`, or
`SOURCE_MANIFEST.txt`; the coordinator owns shared registration files.

## Tests and gate

Offline tests must cover distinct execution/source identities, immutable
snapshot attribution, join/reconnect overlap, stale and handed-off refusal,
bounded retention, and one-shot regression. Use the established gates verbatim:

```sh
lib/validate-before-deploy.sh --verbose
./run-tests.sh
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm
git diff --check
```

No live acceptance claim is permitted until a separately authorized retained
instance run is designed and recorded.

## Commit message

```
feat(oracle): add OV-backed retained-instance executions
```

## Blocked protocol

If synchronization cannot preserve immutable source/result attribution or the
existing ownership gate, write a `Blocked:` report and do not add a daemon or
implicit retention policy.
