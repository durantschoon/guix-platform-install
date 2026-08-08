# Stage 01 — Handle OCI "Out of host capacity" on launch

## Motivation (measured, not hypothetical)

`oracle/scripts/04-deploy.scm` launches into a single availability domain chosen
without inspection:

```scheme
(let ((availability-domain
       (oci "iam availability-domain list --query 'data[0].name' --raw-output")))
  (say "Launching " %shape " ...")
```

It takes `data[0]` — the first AD — and `%shape` is fixed at
`"VM.Standard.E2.1.Micro"` (line 34).

Oracle's Always Free `E2.1.Micro` capacity is exhausted in popular regions for
long stretches; the launch then fails with `Out of host capacity` (service code
`OutOfCapacity` / HTTP 500). Today that surfaces as a raw `oci` CLI error at the
last step of an otherwise successful pipeline — after the image has been built,
uploaded and imported.

[docs/ORACLE_ONE_CLICK_ROADMAP.md](../ORACLE_ONE_CLICK_ROADMAP.md) step 5 records
why this matters: the target user has never used Guix, and a novice who hits a
raw capacity error with no guidance simply stops.

**This cannot be fixed, only handled.** Do not add unbounded retry loops or
anything that hammers the API.

## The change

In `oracle/scripts/04-deploy.scm`:

1. **Detect** the capacity failure specifically — match on `Out of host
   capacity` / `OutOfCapacity` in the CLI's combined output. It must be
   distinguished from other launch failures (quota, bad subnet, bad image),
   which need different advice.
2. **Try the other availability domains.** Enumerate all ADs rather than
   `data[0]`, and on a capacity failure try the next one. This is a bounded
   walk over a list that is typically 1–3 entries — not a retry loop. Say
   which AD is being tried, and why, as it goes.
3. **When every AD is exhausted, advise and exit cleanly** with a message that
   tells a novice exactly what to do next:
   - the Always Free ARM shape `VM.Standard.A1.Flex` (different capacity pool;
     note it needs `--shape-config` with OCPUs/memory, and that the image in
     this repo is **x86_64 and will not boot on ARM** — so this is a "you will
     need an aarch64 image" pointer, not a drop-in flag)
   - trying a different region, since Always Free is per-tenancy-home-region
   - that capacity does free up, so retrying later is legitimate
4. Keep the existing idempotency property: a rerun after failure must still
   continue rather than duplicate resources.

## Ground rules

- **Guile only.** This file is Guile and stays Guile.
- **ASCII only** — read over the OCI serial console and plain terminals.
  `[OK]` / `[WARN]` / `[ERROR]`.
- Use the existing helpers in `oracle/scripts/oci-common.scm` (`oci`,
  `sh-quote`, `say`, `die`, prompts on `/dev/tty`). Do not introduce a JSON
  parser — every `oci` call uses `--query` / `--raw-output` by design.
- Guile has no octal escape: `"\x1b["`, never `"\033["`.
- Do not remove existing code you were not asked to remove; flag it instead.
- **Do not** invent an aarch64 image build. Pointing at A1.Flex is advice text
  only; actually supporting ARM is a separate, unstaged piece of work.

## Allowed files (whitelist)

```
oracle/scripts/04-deploy.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-capacity.scm     (new)
run-tests.sh                              (registration; this stage owns it)
```

Touching anything else — especially `SOURCE_MANIFEST.txt`, `CHECKLIST.md`, or
`lib/validate-before-deploy.sh` — is out of scope. The coordinator regenerates
the manifest after merge.

## Tests (enumerated — all required)

New file `oracle/tests/test-oracle-capacity.scm`, Guile, in the style of the
existing `oracle/tests/test-oracle-image.scm` (small harness, `[OK]`/`[FAIL]`
counters, exit 0/1). It must run **offline** — no OCI calls, no network.

Factor the classification logic into a pure, testable procedure (e.g.
`launch-error-kind` returning a symbol) so these can be asserted directly:

1. `Out of host capacity` in the message classifies as capacity.
2. The JSON-ish service form (`"code": "OutOfCapacity"`) classifies as capacity.
3. A quota/limit error (`LimitExceeded`) does **not** classify as capacity.
4. An unrelated failure (`InvalidParameter`, bad subnet OCID) does **not**
   classify as capacity.
5. Empty output / no error does **not** classify as capacity.
6. The advice text names all three of: `VM.Standard.A1.Flex`, a different
   region, and retrying later.
7. The advice text warns that the repo's image is x86_64 and will not boot on
   the ARM shape.
8. The file is ASCII only.
9. No `\033[` escapes anywhere in the changed Guile.

Register the new suite in `run-tests.sh` next to the existing Oracle block,
guarded by `command -v guile`.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s oracle/tests/test-oracle-capacity.scm   # exit 0
```

Baseline for comparison (do not "fix" these; they are inherited):

- validation: Passed 6, Failed 0, ~15 warnings
- `run-tests.sh`: exit 0, with 14/14 converted-script tests failing
  (auto-generated, never passed, deliberately non-gating)

Also required: `oracle/scripts/oracle-scripts_purpose.txt` gains a section
explaining the capacity handling and, per the repo convention, at least one
statement of omission (why no unbounded retry; why A1.Flex is advice rather
than a flag).

## Commit message (exact, single line)

```
feat(oracle): handle "Out of host capacity" with AD fallback and advice
```

## Report requirements

Write `docs/stages/stage-01-REPORT.md` containing:

- **What changed**, file by file.
- **Gate output**: the actual tail of each of the three commands above, pasted,
  not summarized.
- **Deviations**: anything you did differently from this prompt, and why.
- **Open questions**: what the next stage should pick up.
- **Unverified claims**: explicitly — nothing here can be tested against a real
  capacity failure without one occurring, so state plainly which behaviour is
  reasoned rather than observed.

## Blocked protocol

If you cannot proceed without violating a guardrail in
[README.md](README.md) — in particular if the change seems to require a new
`.sh` on a Guix target, removing existing code, or handling credentials — **stop
and write the REPORT with a `Blocked:` section** explaining the conflict.
Do not improvise around it.
