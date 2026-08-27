# Stage 07 report: one-shot release candidate

## Changes per file

- `Makefile`: added `oracle-run`/`oracle-one-shot` as the documented explicit
  one-shot entry point and `oracle-resume-check` as read-only checkpoint status.
- `oracle/scripts/validation-common.scm`: added an exact-identity resumable
  checkpoint predicate. It requires a non-terminal `IN_TEST` state and matching
  run, execution, and instance identities.
- `oracle/tests/test-oracle-validation.scm`: covered forwarding, restart
  round-trip/refusal cases, identity preservation, and expansion exclusions.
- `oracle/README.md`, `docs/ORACLE_VALIDATION_RUNNER.md`: documented human and
  coding-agent invocation, evidence paths, restart rehearsal, and live gate.
- `oracle/scripts/oracle-scripts_purpose.txt`: recorded the rationale and
  deliberate omissions.

## Packaged command examples

```sh
make oracle-run IMAGE_ID=ocid1.image... SUBNET_ID=ocid1.subnet... \
  SOURCE="$PWD" COMMAND='sha256sum known-good/provenance' YES=--yes
make oracle-resume-check RUN_DIR=.oracle-validation/runs/<run-id>
```

The first command remains a disposable OCI mutation and writes all evidence
under the exact run directory. The second is read-only.

## Restart rehearsal evidence

The offline suite round-trips a `running` checkpoint and accepts it only with
matching run ID, execution ID, and instance OCID. It refuses complete,
`HANDED_OFF`, malformed, mismatched, and identity-ambiguous records. No live
restart or OCI mutation was performed by this stage.

## Release checklist

- [ ] Run a declared computation from the uploaded snapshot whose source hash
      is recorded in `request.json` and `result.json`.
- [ ] Confirm result, run, execution, source, and exact instance identities.
- [ ] Confirm the exact recorded instance reaches `TERMINATED`.
- [ ] Preserve the complete run directory and live OCI evidence.

## Gate output

```text
$ GOCACHE=/tmp/guix-stage07-gocache lib/validate-before-deploy.sh --verbose
exit 1; Passed: 5, Warnings: 15, Failed: 1
Failure: SOURCE_MANIFEST.txt is stale for validation-common.scm and
test-oracle-validation.scm (coordinator owns manifest regeneration).

$ GOCACHE=/tmp/guix-stage07-gocache ./run-tests.sh
exit 2; framework-dual Go tests passed; macOS boundary reports missing
(guix read-print), then the known return-outside-function error.

$ guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm
exit 0; All 105 Oracle validation checks passed!

$ git diff --check
exit 0
```

## Whitelist audit

Changed files are limited to the nine files in the Stage 07 whitelist. No
`CHECKLIST.md` or `SOURCE_MANIFEST.txt` change is included; the coordinator
owns those shared files.

## Deviations and open questions

No deviations. The existing controller's durable checkpoints are retained;
this stage adds the packaged entry point and a pure exact-identity rehearsal,
not a second cloud controller or automatic restart loop.

## Unverified claims

The highest evidence phase reached by Stage 07 is offline source inspection
and local Guile rehearsal. No claim is made here about building, booting,
logging into, computing on, or terminating a live OCI instance. OV-6 remains
open until the human live release gate passes.
