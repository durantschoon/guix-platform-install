# Stage 05 Report - Bounded one-shot compute contract

## Changes per file

- `oracle/scripts/validation-common.scm`: added schema constants, fail-closed
  policy parsing, request/status/result encoders, and complete result fields.
- `oracle/scripts/validate.scm`: records explicit execution identity and
  `request.json`, passes parsed bounds to the guest, and writes classified
  terminal results for launch, command, guest-loss, and cleanup outcomes.
- `oracle/scripts/validation-guest-runner.scm`: bounds retained output and emits
  one durable `output-truncated` event with its byte limit and explicit absence
  of a full-output location.
- `oracle/scripts/oracle-scripts_purpose.txt`: records identity, policy,
  truncation, and architectural omissions.
- `oracle/tests/test-oracle-validation.scm`: adds schema/identity/policy/result/
  truncation/secret/source-scope checks while retaining OV-3 and OV-5 checks.
- `docs/ORACLE_VALIDATION_RUNNER.md`: documents schemas, policy bounds, examples,
  and the compatibility boundary.
- `docs/stages/stage-05-REPORT.md`: this execution report.

## Schemas and examples

Request:

```json
{"schema_version":1,"run_id":"run-1","execution_id":"exec-1","source_sha256":"abc123","command":"./run-tests.sh","policy":{"timeout_seconds":3600,"max_output_bytes":1048576,"shape":"VM.Standard.E2.1.Micro"}}
```

Status:

```json
{"schema_version":1,"run_id":"run-1","execution_id":"exec-1","source_sha256":"abc123","instance_ocid":"ocid1.instance.fixture","local_phase":"running","artifact_state":"IN_TEST","remote_lifecycle":"RUNNING","remote_artifact_state":"IN_TEST","ownership_match":true}
```

Result:

```json
{"schema_version":1,"run_id":"run-1","execution_id":"exec-1","instance_ocid":"ocid1.instance.fixture","source_sha256":"abc123","command":"./run-tests.sh","exit_status":0,"failure_class":null,"started_at":"2026-08-27T12:00:00Z","ended_at":"2026-08-27T12:00:42Z","duration_seconds":42,"cleanup_disposition":"terminated","output_truncated":false,"output_byte_limit":1048576,"full_output_path":null,"evidence_paths":["events.jsonl"]}
```

## Invariants

- `run_id`, `execution_id`, `instance_ocid`, and `source_sha256` are explicit
  facts. The one-shot implementation currently chooses execution ID equal to
  run ID; no consumer derives either from the instance OCID.
- Output at the byte limit is complete. Output beyond it emits exactly one
  `output-truncated` event containing `byte_limit=N;full_output_path=none`.
- Policy is parsed before authentication, SSH key generation, or launch.
- Results and guest inputs contain no OCI credential/private-key path or data.

## Gate output

Literal host command: `lib/validate-before-deploy.sh --verbose`

```text
exit 1
Passed: 3
Warnings: 15
Failed: 3
Compilation and unit tests could not write the sandboxed macOS Go cache;
manifest reported 4 changed covered files.
```

Diagnostic rerun with writable cache:
`GOCACHE=/private/tmp/guix-platform-stage-05-go-cache lib/validate-before-deploy.sh --verbose`

```text
exit 1
Passed: 5
Warnings: 15
Failed: 1
Code compiles successfully
Unit tests pass
Source manifest is STALE: 4 of 78 files differ
```

`SOURCE_MANIFEST.txt` is coordinator-owned and forbidden by the stage
whitelist, so the executor did not update it.

Literal host command: `./run-tests.sh`

```text
exit 1
Go cache writes were denied by the workspace sandbox.
```

Diagnostic rerun with writable cache:
`GOCACHE=/private/tmp/guix-platform-stage-05-go-cache ./run-tests.sh`

```text
exit 2
Common Library Functions tests passed
Framework Dual-Boot Install Functions tests passed
Guile Config Helper: (guix read-print) is unavailable
./run-tests.sh: line 49: return: can only return from a function or sourced script
```

This is the prompt's documented macOS host boundary; no host pass is claimed.

Literal command: `guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm`

```text
exit 0
All 94 Oracle validation checks passed!
```

Literal command: `git diff --check`

```text
exit 0
(no output)
```

## Whitelist audit

`git diff --name-only` contains only:

```text
docs/ORACLE_VALIDATION_RUNNER.md
docs/stages/stage-05-REPORT.md
oracle/scripts/oracle-scripts_purpose.txt
oracle/scripts/validate.scm
oracle/scripts/validation-common.scm
oracle/scripts/validation-guest-runner.scm
oracle/tests/test-oracle-validation.scm
```

All are allowed. The test runner's untracked `postinstall/tests/test-work.scm`
fixture was removed after the host run and is not part of the stage.

## Deviations

- The static gate cannot reach exit 0 until the coordinator regenerates the
  forbidden shared manifest after merge. No code/test failure remains in its
  writable-cache rerun.
- The host full-suite command has the inherited `(guix read-print)`/top-level
  `return` failure documented in the prompt. It was not changed.
- No live launch was performed, as required.

## Open questions

- The coordinator must regenerate `SOURCE_MANIFEST.txt` and rerun validation on
  the merged union.
- A Guix-capable environment must run `./run-tests.sh` for the release gate.
- Multi-byte Unicode output is outside this controller's ASCII-visible output
  contract; the retained limit is exercised with byte-for-byte ASCII fixtures.

## Unverified claims

Highest evidence phase: **offline controller execution**. Parsing, schema
encoding, guest-runner output bounding, journal replay, mocked lifecycle loss,
ownership, and source-scope checks executed locally. Nothing in this stage was
built into an image, booted, logged into, or exercised against OCI. Existing
OV-3/OV-5 live evidence was preserved but not repeated or upgraded.
