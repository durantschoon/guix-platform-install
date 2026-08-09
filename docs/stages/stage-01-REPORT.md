# Stage 01 REPORT — Handle OCI "Out of host capacity" on launch

- **Branch:** `stage-01-oci-capacity`
- **Base commit:** `cdd3683` (`docs(stages): scaffold the stage pipeline and author stages 01-02`)
- **Commit message:** `feat(oracle): handle "Out of host capacity" with AD fallback and advice`

## Checklist echo

| Prompt requirement | Status |
|---|---|
| Detect capacity failure specifically, distinct from quota/other | done — `launch-error-kind` returns `capacity` / `limit` / `other` / `none` |
| Enumerate all ADs instead of `data[0]`, walk on capacity failure | done — `availability-domains`, bounded loop in `ensure-instance` |
| Say which AD is being tried, and why | done — `Trying availability domain <ad> ...` / `[WARN] <ad>: no free ... -- trying the next` |
| Advise and exit cleanly when all ADs exhausted | done — `capacity-advice` printed, exit 1 |
| Advice names A1.Flex, different region, retry later | done (tests 6 group) |
| Advice warns image is x86_64 / will not boot on ARM | done (tests 7 group) |
| Idempotency preserved | done — `existing-instance` short-circuit untouched; nothing new is created before the launch |
| Guile only | done |
| ASCII only | done, asserted by test |
| Use `oci-common.scm` helpers, no JSON parser | done — `oci`, `oci/status`, `sh-quote`, `say`, `die`, `ocid-or-false`; every query is `--query`/`--raw-output` |
| `"\x1b["` never `"\033["` | done, asserted by test on both files |
| No aarch64 image support built | done — advice text only |
| Purpose file gains a section + statements of omission | done — 4 statements of omission |
| New offline test suite, style of `test-oracle-image.scm` | done — 24 checks, exit 0 |
| Registered in `run-tests.sh` under `command -v guile` | done |

## What changed, file by file

### `oracle/scripts/04-deploy.scm`

1. Header comment gains a paragraph on why the launch walks ADs, and states
   explicitly that the existing idempotency is what makes "rerun later" a real
   answer to a capacity failure.
2. New `%max-availability-domains` (10). A guard against an unexpected CLI
   response, not a policy — real tenancies have 1–3.
3. New **pure** section, before the storage helpers:
   - `launch-error-kind` — takes the combined stdout+stderr of a launch, returns
     a symbol. Case-insensitive text matching, because `OutOfCapacity` arrives
     with HTTP 500 and cannot be told from a transient server fault by status
     code. Order: capacity (`out of host capacity` / `outofcapacity`) → limit
     (`limitexceeded` / `quotaexceeded` / `service limit`) → other (contains
     `error` or `usage:`) → none.
   - `capacity-advice` — returns the advice string rather than printing it, so
     the offline test can assert its content.
   Both depend on core Guile only (`string-downcase`, `string-contains`,
   `string-join`), which is a load-bearing constraint: the test evaluates these
   two forms in isolation from the rest of the script.
4. New `availability-domains` — enumerates by index (`data[N].name`) rather than
   asking for the array, because `--raw-output` does not flatten a JSON list and
   there is no JSON parser by design. Reuses `ocid-or-false` as the empty/`None`
   guard (it is not OCID-specific, and an out-of-range index yields exactly that).
5. New `first-ocid-line` — the launch now merges stderr into stdout so failures
   can be classified, so the OCID must be picked out of possibly-noisy output
   rather than assumed to be the whole string.
6. New `attempt-launch` — one launch, `2>&1`, returns `(values ocid-or-#f output)`.
   The pre-existing "No `--metadata ssh_authorized_keys`" comment moved here
   verbatim; nothing was deleted.
7. `ensure-instance` rewritten as a bounded walk. `capacity` → next AD;
   `limit` → `die` with quota-specific advice (every AD draws on the same
   tenancy limit); anything else → `die` with the CLI's own words. When the list
   is exhausted: `[ERROR]` line naming the ADs tried, then `capacity-advice`,
   then `exit 1`.

Removed lines are exactly the old `data[0]` lookup and the single-shot launch
call that the stage asked to replace. Nothing else was deleted.

### `oracle/tests/test-oracle-capacity.scm` (new, 24 checks)

Runs offline: no OCI account, no `oci` CLI, no network, no `guix`. It reads
`04-deploy.scm`'s top-level forms and evaluates **only** `launch-error-kind` and
`capacity-advice`, because the script loads `oci-common.scm` and calls `(main)`
at the bottom — a plain `load` would try to talk to Oracle. That keeps the test
hook out of the production script entirely; there is no "if running under test"
branch in `04-deploy.scm`.

Covers the nine enumerated tests plus: `limit`/`other` positively (not just
"not capacity"), whitespace-only input, a bare success OCID, case-insensitivity,
`--shape-config` present in the advice, ASCII on both files, and two source-text
assertions that the walk stays bounded and that only `capacity` continues it.

### `run-tests.sh`

New block after the Oracle image block, inside the `command -v guile` guard but
deliberately **outside** the nested `command -v guix` guard — these tests need
neither guix nor network, so they should run everywhere. `[OK]`/`[FAIL]`, ASCII.
Uses `exit 1` on failure, matching the adjacent Oracle image block (a `return 1`
there would be a no-op outside a function).

### `oracle/scripts/oracle-scripts_purpose.txt`

New subsection under `04-deploy.scm`, placed before "SSH BANNER check":
the AD walk and the failure it fixes; the four kinds and why only one walks;
why ADs are enumerated by index; **four statements of omission** — no retry loop
anywhere, A1.Flex is advice not a fallback, no automatic region change, and why
the exit code is 1 rather than 0.

## Gate output

### Baseline (unmodified base `cdd3683`)

```
$ lib/validate-before-deploy.sh --verbose        # EXIT=0
=== Validation Summary ===
Passed:   6
Warnings: 15
Failed:   0

[WARN] VALIDATION PASSED WITH WARNINGS
Review warnings before deploying
```

```
$ ./run-tests.sh                                  # EXIT=0
⚠ Converted script tests: 14/14 failed
  These are auto-generated tests that need manual fixes.
  ...
=== All Tests Completed Successfully! ===
```

`guile --no-auto-compile -s oracle/tests/test-oracle-capacity.scm` — file did
not exist at baseline.

### Final

```
$ lib/validate-before-deploy.sh --verbose        # EXIT=0
Checking for common anti-patterns...
[WARN] Found direct os.Stdin usage (should use /dev/tty for user input)
[WARN] Found 'done < file' pattern (may consume stdin, use process substitution)

=== Validation Summary ===
Passed:   6
Warnings: 15
Failed:   0

[WARN] VALIDATION PASSED WITH WARNINGS
Review warnings before deploying
```

```
$ ./run-tests.sh                                  # EXIT=0
...
All 7 oracle image checks passed!
✓ Oracle image config tests passed

Testing Oracle Capacity Handling...
----------------------------------------
Testing OCI capacity handling
  Script: .../oracle/scripts/04-deploy.scm

  [OK]   launch-error-kind and capacity-advice are defined in 04-deploy.scm
  ... (24 checks) ...
All 24 oracle capacity checks passed!
[OK] Oracle capacity handling tests passed
...
⚠ Converted script tests: 14/14 failed
...
=== All Tests Completed Successfully! ===
```

```
$ guile --no-auto-compile -s oracle/tests/test-oracle-capacity.scm   # EXIT=0
Testing OCI capacity handling
  Script: /home/durant/Repos/ds/guix-platform-install/.claude/worktrees/agent-af430be32de076ff6/oracle/scripts/04-deploy.scm

  [OK]   launch-error-kind and capacity-advice are defined in 04-deploy.scm
  [OK]   "Out of host capacity" classifies as capacity
  [OK]   the service code "OutOfCapacity" classifies as capacity
  [OK]   a LimitExceeded quota error does NOT classify as capacity
  [OK]   a LimitExceeded quota error classifies as limit
  [OK]   an InvalidParameter/bad-subnet error does NOT classify as capacity
  [OK]   an InvalidParameter/bad-subnet error classifies as other
  [OK]   empty output does NOT classify as capacity
  [OK]   empty output classifies as none
  [OK]   whitespace-only output classifies as none
  [OK]   a successful launch's OCID classifies as none
  [OK]   capacity matching is case-insensitive
  [OK]   advice names the alternative Always Free shape VM.Standard.A1.Flex
  [OK]   advice mentions trying a different region
  [OK]   advice says retrying later is legitimate
  [OK]   advice warns the repo's image is x86_64
  [OK]   advice warns the x86_64 image will not boot on the ARM shape
  [OK]   advice notes A1.Flex needs --shape-config
  [OK]   04-deploy.scm is ASCII only
  [OK]   this test file is ASCII only
  [OK]   04-deploy.scm contains no \033[ escape
  [OK]   this test file contains no \033[ escape
  [OK]   the availability-domain walk is bounded by %max-availability-domains
  [OK]   only the capacity kind continues the walk

All 24 oracle capacity checks passed!
```

Baseline and final are identical on both inherited gates: validation 6/15/0, and
14/14 converted-script tests still failing. Neither was touched.

### `git diff cdd3683 --stat`

```
 oracle/scripts/04-deploy.scm              | 241 ++++++++++++++++++++++++++++--
 oracle/scripts/oracle-scripts_purpose.txt |  76 ++++++++++
 run-tests.sh                              |  13 ++
 3 files changed, 314 insertions(+), 16 deletions(-)
```

Plus the new untracked `oracle/tests/test-oracle-capacity.scm` and this report.
All four source files are on the prompt's whitelist. `SOURCE_MANIFEST.txt`,
`CHECKLIST.md` and `lib/validate-before-deploy.sh` were not touched.

## Deviations

1. **The worktree branched from `64b35fd`, three commits behind `main`.** The
   prompt file did not exist on that base. I fast-forwarded the worktree to
   `main` (`cdd3683`) — a clean fast-forward, `HEAD` was an ancestor — and
   measured the baseline there. All numbers in this report are against
   `cdd3683`.
2. **Branch name was not specified** by the prompt or `docs/stages/README.md`.
   I renamed the worktree branch to `stage-01-oci-capacity`.
3. **`launch-error-kind` returns four symbols, not two.** The prompt asked only
   that quota and unrelated failures not classify as capacity. Collapsing them
   into one "not capacity" bucket would have meant one error message for both,
   and a quota error genuinely needs different advice from a bad subnet OCID, so
   `limit` is handled separately in `ensure-instance`.
4. **`attempt-launch` merges stderr into stdout (`2>&1`).** Required — the CLI
   writes `ServiceError` to stderr, so without it the capacity message never
   reaches the classifier. The cost is that a success must be recognised by
   finding an `ocid1.`-prefixed line rather than by taking the whole output,
   which is what `first-ocid-line` is for.
5. **ADs are enumerated one index at a time** (N+1 API calls) rather than in one
   call. `--query 'data[*].name' --raw-output` returns a JSON array that
   `--raw-output` does not flatten, and parsing it would need `guile-json` —
   the dependency these scripts exist without.
6. **The test reads definitions out of the script instead of loading it.**
   `04-deploy.scm` calls `(main)` at the bottom, so loading it would call
   Oracle. The alternative — an env-var guard around `(main)` — would put a test
   hook in production code. The cost of the chosen approach: `launch-error-kind`
   and `capacity-advice` must keep depending on core Guile only. This is stated
   in both the script and the purpose file.
7. **The new `run-tests.sh` block sits outside the `command -v guix` guard**
   (but inside `command -v guile`, as instructed). The suite needs no guix.
8. **The self-check for `\033[` builds its needle from two pieces**
   (`(string-append "\\" "033[")`). Written literally, the test file failed its
   own check on itself. Noted in a comment there.
9. **Exit code on exhausted capacity is 1.** "Exit cleanly" was read as "no
   traceback, no raw CLI JSON as the last thing on screen" — not as exit 0,
   since nothing was deployed and a caller must not read that as success.

## Unverified claims

Nothing below has been exercised against a real capacity failure; one cannot be
provoked on demand. Each is reasoned, not observed.

1. **The exact wording Oracle emits.** The test fixtures are the *documented*
   forms (`"message": "Out of host capacity."` and `"code": "OutOfCapacity"`),
   hand-written, not captured transcripts. If Oracle words it a third way, the
   classifier returns `other` and the script stops with the CLI's own text —
   the safe direction, but the AD walk would not happen.
2. **That the capacity message reaches stdout via `2>&1`.** Reasoned from the
   OCI CLI writing `ServiceError` to stderr. Not observed on a live failure.
3. **That a second AD succeeds when the first is full.** ADs are separate
   physical pools, so this is plausible and is the standard community
   workaround — but the walk has never been observed to convert a failure into a
   launch.
4. **That `--query 'data[N].name'` on an out-of-range index yields empty or
   `None`** rather than a non-zero exit or a traceback. Inferred from the
   pre-existing `ocid-or-false` helper, which the original author wrote to guard
   both cases. If the CLI instead errors, `availability-domains` returns the ADs
   found so far, which still walks correctly — but if it errors on index 0 the
   script would `die` with "no availability domains returned", which is a
   misleading message for a CLI fault.
5. **That `first-ocid-line` finds the OCID on success.** Reasoned from
   `--query data.id --raw-output` printing the bare OCID and
   `SUPPRESS_LABEL_WARNING=True` silencing the known stderr noise. If some other
   stderr line were emitted *and* the OCID were absent, the script would treat a
   successful launch as a failure and — since the output would not classify as
   capacity — `die` rather than walk. It would not launch twice.
6. **That the advice is actionable for a Guix novice.** No user has read it.
7. **The whole path has never run end to end**, because the last successful run
   (2026-08-08) got capacity on the first AD.

## Open questions for the next stage

1. **`(zero? status)` will throw if the CLI is killed by a signal.**
   `run-command/status` in `oci-common.scm` returns `(status:exit-val status)`,
   which is `#f` for a signal death, and `(zero? #f)` raises. `attempt-launch`
   inherits this from `upload-image`, which has the same shape. The fix belongs
   in `oci-common.scm`, which is not on this stage's whitelist. Not touched.
2. **`run-tests.sh` line 50 has a `return 1` outside a function** (the Guile
   config helper block). Under `set -e` it is a no-op at best. Pre-existing;
   my block uses `exit 1` like the adjacent Oracle block. Not fixed — outside
   the stage's intent, and the file is a shared registration file.
3. **`run-tests.sh` still contains Unicode** (`✓ ✗ ⊘ ⚠`) in pre-existing lines.
   It is developer tooling rather than an ISO script, so it may be intentional,
   but it is inconsistent with the Oracle image block right above, which
   hex-escapes them. My additions are plain ASCII. Flagged, not changed.
4. **A capacity failure now consumes an image import first.** The walk happens
   at the very end. A cheap pre-flight — attempt a launch (or query capacity)
   before the 5–20 minute import — would surface the wait before the user spends
   the time. Out of scope here; it changes the pipeline's shape.
5. **aarch64 image support.** The advice points at `VM.Standard.A1.Flex` and
   then tells the user they cannot use it. Building an aarch64 Guix image is the
   thing that would make option 3 real.
6. **`docs/ORACLE_ONE_CLICK_ROADMAP.md` step 5 and `CHECKLIST.md`** presumably
   want status updates for this work. Both are coordinator-owned / off-whitelist,
   so neither was touched.
