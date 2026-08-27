# Stage 09 — Typed MCP facade over the OV-backed controller

## Motivation (measured)

OV-6 established a stable one-shot interface and evidence contract. A future
MCP facade should expose that controller to tools without becoming a new cloud
authority, credential broker, or source of truth. The facade is deferred until
Stage 08 proves retained executions, but its contract can be fixed now.

## The change

1. Define typed create/run/status/logs/collect/handoff/terminate operations that
   delegate to the existing OV controller and return its versioned schemas.
2. Preserve exact run, execution, source, and instance identities in every
   response; never infer identity from display names or mutable task labels.
3. Return evidence paths and failure classes without copying OCI credentials or
   private keys into tool arguments, logs, or results.
4. Make destructive operations explicit, ownership-gated, and confirmation
   aware. The facade may request an existing guarded operation but may not
   bypass it.
5. Document client compatibility, refusal/error behavior, and the boundary
   between local controller authority and disposable guest execution.

## Ground rules

- Reuse OV-6 request/result/checkpoint schemas and Stage 08 execution identity;
  do not invent a parallel JSON contract.
- No service accepts third-party OCI credentials or SSH private keys.
- No implicit launch, termination, adoption, retention, or background worker.
- Tool tests are offline contract tests; live MCP acceptance is a separate
  human-authorized gate.

## Allowed files (whitelist)

```
oracle/scripts/validation-common.scm
oracle/scripts/validation-lifecycle.scm
oracle/scripts/validate.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-validation.scm
docs/ORACLE_VALIDATION_RUNNER.md
docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md
docs/stages/stage-09-REPORT.md
```

Do not edit `Makefile`, `run-tests.sh`, `CHECKLIST.md`, or
`SOURCE_MANIFEST.txt`; the coordinator owns shared registration files.

## Tests and gate

Offline tests must cover typed argument parsing, schema-preserving delegation,
identity round-trips, secret exclusion, ownership-gated mutation, and refusal
of unsupported or ambiguous operations. Use the established gates verbatim:

```sh
lib/validate-before-deploy.sh --verbose
./run-tests.sh
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm
git diff --check
```

No live MCP or OCI acceptance claim is permitted by this stage.

## Commit message

```
feat(oracle): add typed MCP facade over controller
```

## Blocked protocol

If the facade needs credentials, a new cloud authority, or a schema fork from
the OV controller, write a `Blocked:` report and stop for an architecture
decision.
