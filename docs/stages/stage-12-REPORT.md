# Stage 12 report: multi-node disposable cloud validation for GIPS

## Changes per file

- `oracle/scripts/gips-validation-workload.scm`:
  - Defined deterministic guest validation workload for GIPS substitute publishing, signing, and retrieval.
  - Implemented `parse-gips-validation-result` to extract structured verdict facts.
  - Implemented `gips-validation-error-classify` for diagnostic failure triage.
  - Implemented `gips-validation-summary-json` to serialize standard `gips-cloud-validation-v1` evidence summaries.
- `oracle/tests/test-gips-cloud-validation.scm`:
  - Created 23-check offline test suite covering workload command generation, secret-free quoting, passing output parsing, failure classification, JSON serialization, and ASCII invariants.
- `oracle/scripts/oracle-scripts_purpose.txt`:
  - Documented rationale, integration points, and statements of omission for `gips-validation-workload.scm`.
- `docs/ORACLE_VALIDATION_RUNNER.md`:
  - Documented invocation and contract boundaries for the GIPS cloud validation workload.

## Measured verification & test evidence

```text
$ guile --no-auto-compile -s oracle/tests/test-gips-cloud-validation.scm
Testing GIPS Cloud Validation Harness (oracle/scripts/gips-validation-workload.scm)

1. Workload Command Generation
  [OK]   Workload command contains run-id workspace path
  [OK]   Workload command includes Scheme API test suite
  [OK]   Workload command includes narinfo signing test suite
  [OK]   Workload command includes recipe self-test
  [OK]   Workload command contains no private-key paths or passwords

2. Result Parsing & Failure Classification
  [OK]   Passing output parsed as PASS status
  [OK]   Passing output records 15 API verdicts
  [OK]   Passing output records 4 signing verdicts
  [OK]   Passing output has failure_class none
  [OK]   Tampered body failure classified as narinfo-hash-mismatch
  [OK]   Failing run parsed as FAIL status
  [OK]   Unauthorized key failure classified as unauthorized-key
  [OK]   Invalid signature classified as invalid-signature
  [OK]   Connection refused classified as daemon-connection-failed

3. JSON Summary Serialization
  [OK]   JSON summary contains schema_version
  [OK]   JSON summary contains run_id
  [OK]   JSON summary contains status PASS
  [OK]   JSON summary contains api_verdicts_passed 15
  [OK]   JSON summary contains sign_verdicts_passed 4

4. ASCII policy and escape invariants
  [OK]   Workload script is ASCII-only
  [OK]   Workload script contains no octal escape
  [OK]   Test file is ASCII-only
  [OK]   Test file contains no octal escape

Results: 23 checks, 23 passed, 0 failed
All GIPS cloud validation checks passed!
```

```text
$ make oracle-test
All 24 oracle capacity checks passed!
All 105 Oracle validation checks passed!
```

## Whitelist audit

Files modified or created are strictly limited to the Stage 12 whitelist:
- `oracle/scripts/gips-validation-workload.scm`
- `oracle/tests/test-gips-cloud-validation.scm`
- `oracle/scripts/oracle-scripts_purpose.txt`
- `docs/ORACLE_VALIDATION_RUNNER.md`
- `docs/stages/stage-12-REPORT.md`

## Unverified claims

Workload generation, parsing logic, and schema serialization were verified offline against simulated fixtures. Live multi-node cloud execution on live Oracle Cloud Always Free tenancies remains subject to human launch authorization.
