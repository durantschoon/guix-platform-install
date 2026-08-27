# Stage 06 report: expired-run review and reaper

## Changes per file

- `oracle/scripts/validation-common.scm`: added strict UTC expiry parsing,
  local candidate decisions, and versioned review/reaper JSON encoders.
- `oracle/scripts/validation-lifecycle.scm`: added read-only `review` and
  explicit `reap --yes`, using only immediate local checkpoint directories,
  exact recorded OCIDs, fresh OV-3 ownership reads, and durable JSONL outcomes.
- `oracle/scripts/oracle-scripts_purpose.txt`: documented the safety boundary
  and deliberate omissions.
- `oracle/tests/test-oracle-validation.scm`: added six offline Stage 06 policy,
  schema, surface, and no-expansion checks; focused suite is now 100 checks.
- `docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md`: documented commands, semantics,
  schemas, and compatibility behavior.
- `docs/ORACLE_VALIDATION_RUNNER.md`: documented the runner integration.

## Schemas and invariants

Review records use `schema_version: 1` and include `run_id`, `execution_id`,
`instance_ocid`, `expires_at`, `decision`, `reason`, and `evidence_path`.
Reaper outcomes use `schema_version: 1` and include those identities plus
`decision`, `outcome`, and `evidence_path`. No credential material is emitted.

Only a local `IN_TEST` instance record with the required manager, resource,
safe run ID, exact OCID, valid expiry, and an expiry at or before the current
UTC time is eligible for a fresh ownership read. `HANDED_OFF`, malformed or
unknown state, missing identity/expiry, unexpired records, ownership mismatch,
handoff markers, and OCI read errors are protected/skipped. Expiry never
authorizes deletion. Termination is performed only through the existing exact
OCID guarded path; successful and failed requests are distinct outcomes.

Current pre-Stage-6 checkpoints do not contain `expires-at`; they are therefore
protected rather than assigned an expiry by inference.

## Gate output

Focused command:

```text
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm
All 100 Oracle validation checks passed!
```

Static validation with the writable host cache split:

```text
GOCACHE=/tmp/guix-stage06-gocache lib/validate-before-deploy.sh --verbose
Passed: 5; Warnings: 15; Failed: 1
```

The sole failure is the expected stale shared `SOURCE_MANIFEST.txt` for the
three changed covered files; the coordinator must regenerate it after merge.
The initial run without `GOCACHE` also hit the macOS cache permission boundary.

Full suite with the same cache split:

```text
GOCACHE=/tmp/guix-stage06-gocache ./run-tests.sh
exit 2
```

Go tests passed. The suite reaches the established macOS boundary when the
Guile config helper requires `(guix read-print)`, which is unavailable here.
`git diff --check` passed. Controller syntax was independently loaded with
`ORACLE_VALIDATION_TEST_MODE=1 guile --no-auto-compile -s
oracle/scripts/validation-lifecycle.scm` (exit 0).

## Whitelist audit

Changed files are exactly the six implementation/documentation/test files
listed above plus this report, all within the seven-file prompt whitelist.
No `Makefile`, `run-tests.sh`, `CHECKLIST.md`, `SOURCE_MANIFEST.txt`, or OCI
credential/default file was changed. No live OCI mutation or launch was run.

## Deviations and open questions

The existing producer (`validate.scm`) is outside this stage whitelist and does
not yet write `expires-at` into local state. The compatibility behavior is
fail-closed protection; a later release stage should add producer recording if
automatic expiry review is required.

## Unverified claims

Highest evidence phase reached: offline controller execution and source-level
syntax loading. No live OCI acceptance, boot, login, or termination claim is
made. Durable termination outcomes were exercised only by policy fixtures, not
against OCI.
