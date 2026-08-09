# Stage 04 REPORT — Preserve comments and gexp syntax in config edits

Branch: `stage-04-preserve-comments`
Base: `0f68210` (`main` at launch)

## Checklist echo

| Prompt item | Done |
|---|---|
| `read-config` uses `read-with-comments`; `write-config` uses `pretty-print-with-comments` | yes |
| Delete `install-gexp-reader!`, its `read-hash-extend` calls, and `read-config/gexp` | yes |
| All six subcommands preserve comments and `#~` | yes, asserted per-subcommand |
| Clear message if `(guix read-print)` is unavailable | yes |
| Audit **every** `match` in the file | yes, all 25, table below |
| Tests 1-12 | yes, 79 checks |
| Register in `run-tests.sh` behind `command -v guile` | yes |
| `lib/guile-config-helper_purpose.txt` | yes |

## What changed per file

| File | Change |
|---|---|
| `lib/guile-config-helper.scm` | +103/-52. `(guix read-print)` resolved at run time; `read-config`/`write-config` migrated; gexp reader deleted; `code?`/`map-code` added; two `match` forms fixed. |
| `lib/tests/test-config-helper-comments.scm` | New. 79 checks over the 12 enumerated tests. |
| `lib/guile-config-helper_purpose.txt` | New. Required content plus the two measured findings below. |
| `run-tests.sh` | +17. Registration only, outside the `command -v guix` guard. |
| `oracle/tests/test-oracle-preferences.scm` | +28/-10. Only where assertions named the deleted reader — justified below. |

`oracle/image/oracle-image.scm` is **used as a fixture but never modified**; every
test edits a copy in `/tmp`. `git status` shows it unmodified.

## Gates

Baseline measured on the unmodified base commit `0f68210` before any edit.

| Gate | Baseline | Final |
|---|---|---|
| `lib/validate-before-deploy.sh --verbose` | Passed 6, Warnings 15, **Failed 0**, exit 0 | Passed 6, Warnings 15, **Failed 0**, exit 0 |
| `./run-tests.sh` | exit 0, 14/14 converted-script tests failing | exit 0, 14/14 converted-script tests failing |
| `guile --no-auto-compile -s lib/tests/test-config-helper-comments.scm` | n/a (new) | exit 0, 79/79 |

Both inherited conditions are unchanged: the 15 warnings and the 14/14
converted-script failures are exactly as the pipeline README records them.

### `lib/validate-before-deploy.sh --verbose` (final, tail)

```
[PASS] Source manifest is up-to-date

Checking for common anti-patterns...
[WARN] Found direct os.Stdin usage (should use /dev/tty for user input)
[WARN] Found 'done < file' pattern (may consume stdin, use process substitution)

=== Validation Summary ===
Passed:   6
Warnings: 15
Failed:   0

[WARN] VALIDATION PASSED WITH WARNINGS
Review warnings before deploying
EXIT=0
```

### `./run-tests.sh` (final, tail)

```
[WARN] Converted script tests: 14/14 failed
  These are auto-generated tests that need manual fixes.
  ...
=== All Tests Completed Successfully! ===
EXIT=0
```

The new suite inside that run:

```
Testing Config Helper Comment Preservation...
----------------------------------------

0. Every subcommand ran and changed the file
  fixture: .../oracle/image/oracle-image.scm
  baseline: 134 ';;' lines, 3 '#~' gexps, 13 '#$' ungexps
```

### The new suite (final, tail)

```
11. The stage-03 gexp reader has been removed
  [OK]   install-gexp-reader! is gone from the helper
  [OK]   read-hash-extend is gone from the helper
  [OK]   read-config/gexp is gone from the helper
  [OK]   the helper uses (guix read-print)
  [OK]   the helper reads with read-with-comments
  [OK]   the helper writes with pretty-print-with-comments

12. ASCII only, no octal ANSI escape
  [OK]   guile-config-helper.scm is ASCII only
  [OK]   guile-config-helper.scm uses no octal ANSI escape
  [OK]   test-config-helper-comments.scm is ASCII only
  [OK]   test-config-helper-comments.scm uses no octal ANSI escape
  [OK]   guile-config-helper_purpose.txt is ASCII only
  [OK]   guile-config-helper_purpose.txt uses no octal ANSI escape

All 79 comment-preservation checks passed!
```

### `git diff 0f68210 --stat`

```
 lib/guile-config-helper.scm              | 155 ++++++++++++++++++++-----------
 oracle/tests/test-oracle-preferences.scm |  38 ++++++--
 run-tests.sh                             |  17 ++++
 3 files changed, 148 insertions(+), 62 deletions(-)
```
(plus the two new untracked files and this report, all added in the same commit)

## Before/after excerpt of a real edited config

`oracle/image/oracle-image.scm` copied to `/tmp`, then
`set-host-name ... my-box`. This is the swapfile shepherd service — comments
several levels deep inside a `#~` gexp, which is the hard case.

**Before** (fixture, lines 88-100):

```scheme
     (start
      #~(lambda _
          (define (run . args)
            (zero? (apply system* args)))
          (and (or (file-exists? #$%swapfile)
                   ;; dd rather than fallocate: fallocate produces unwritten
                   ;; extents on ext4 and swapon refuses to use such a file.
                   (and (run #$(file-append coreutils "/bin/dd")
                             "if=/dev/zero"
                             (string-append "of=" #$%swapfile)
                             "bs=1M"
                             #$(string-append
                                "count=" (number->string %swapfile-size-mib)))
```

**After** (edited copy, lines 92-106):

```scheme
                                          (start #~(lambda _
                                                     (define (run . args)
                                                       (zero? (apply system*
                                                                     args)))
                                                     (and (or (file-exists? #$%swapfile)
                                                              ;; dd rather than fallocate: fallocate produces unwritten
                                                              ;; extents on ext4 and swapon refuses to use such a file.
                                                              (and (run #$(file-append
                                                                           coreutils
                                                                           "/bin/dd")
                                                                    "if=/dev/zero"
                                                                    (string-append
                                                                     "of="
                                                                     #$%swapfile)
                                                                    "bs=1M"
```

Both comment lines survive, `#~` and `#$` are still spelled as reader syntax
rather than `(gexp ...)`, and the `dd rather than fallocate` comment is still
immediately above the `dd` call it explains. On the base commit this same
command deleted all 134 comment lines.

Measured over the whole file, for every subcommand: `;;` lines 134 -> 134,
`#~` 3 -> 3, `#$` 13 -> 13. The edited config still evaluates to an
`<operating-system>` under `guix repl` (`OS-OK`).

The indentation *is* reflowed — see Deviation 1.

## Every `match` audited

25 `match` forms. Line numbers are post-change. "Inert" means a `<comment>`,
`<vertical-space>` or `<page-break>` is a **record, not a pair**, so it cannot
match a list pattern and falls to the catch-all.

| # | Line | Form | Interleaving risk | Action |
|---|---|---|---|---|
| 1 | 93 | `has-module?` | none — `member` lookup only | none |
| 2 | 100 | `add-module-to-use-modules` | rebuild `,@modules ,module` | none; comments keep position, new module appended last |
| 3 | 109 | `has-service?` | none — lookup only | none |
| 4 | 118 | `add-service-to-services` | rebuild `(list ,@services ,new)` | none; comments preserved in place |
| 5 | 140 | `modify-os-services` outer | `('operating-system fields ...)` | none |
| 6 | 144 | `modify-os-services` inner loop | head pattern `(('services v) rest ...)` needs a pair | none — comments fall to `((field rest ...))` and are consed through in order |
| 7 | 159 | `process-exprs` | top-level dispatch | none — comments hit `((expr rest ...))` |
| 8 | 221 | `bare-duplicate?` | inert -> `#f`, so never removed | none |
| 9 | 227 | `configured-duplicate?` | inert -> `#f` | none |
| 10 | 234 | `service->modify-clause` | only ever called on pre-filtered code | none |
| 11 | 241 | `switch-services-to-desktop` outer | `keep` uses `remove`, comments survive | none |
| 12 | **261** | **base-tail dispatch** | **REAL BREAK** | **CHANGED** — see below |
| 13 | 283 | `switch-os-to-desktop` | `('operating-system fields ...)` | none |
| 14 | 287 | per-field match inside it | comments -> `(_ field)` | none |
| 15 | 302 | `cmd-switch-to-desktop` per-expr | comments -> `(_ expr)` | none |
| 16 | 324 | `cmd-check-service` loop | comments -> `((_ rest ...))` | none |
| 17 | 331 | services-field `filter-map` | comments -> `(_ #f)` | none |
| 18 | 379 | `field-name` | **the keystone** — returns `#f` for a record | none needed; documented |
| 19 | 395 | `record-field-ref` inner | only reached for a real matched field | none |
| 20 | 420 | `operating-system-form?` | inert -> `#f` | none |
| 21 | 423 | `user-account-form?` | inert -> `#f` | none |
| 22 | **526** | **`add-package-to-packages`** | **`cons*` tail hazard** | **CHANGED** — see below |
| 23 | 578 | `config-has-module?` | lookup only | none |
| 24 | 598 | `ensure-module` inner | comments -> `(_ #f)`, preserved by the accumulator | none |
| 25 | 666 | `main` | argv strings, never config data | none |

Also audited, not `match` but structural: `rewrite-base-services`,
`collect-forms`, `replace-form` and `map-operating-systems` all recurse on
`pair?` only, so records reach the `else` branch untouched.

### The two that genuinely broke

**#12 — `switch-services-to-desktop`'s base tail.** It matched the tail with
`((single) ...)`, a pattern requiring a **one-element** list. A single blank
line inside the `append` makes the tail two items long, the pattern stops
matching, and control falls through to a catch-all that **drops the accumulated
`modify-services` clauses** — silently discarding the NetworkManager
configuration this function exists to preserve. It now decides on
`(filter code? base*)` and rebuilds through `map-code`, so blanks stay put.

This is not hypothetical: the real `oracle/image/oracle-image.scm` has a blank
line before `%base-services` and hits this shape. It happens to have no
configured duplicates, so on that file the loss would have been zero — but
`postinstall/tests/run-guile-tests.sh` Test 6 exists precisely because a config
with a configured NetworkManager is the case that matters.

**#22 — `add-package-to-packages`'s `cons*`.** It matched
`('cons* items ... base)`. `base` is the improper-list tail, and an unguarded
`items ... base` binds it to a **trailing comment**, which would move the real
base into the middle of the list and leave a `<comment>` record as the tail.
`base` is now guarded with `(? code? base)`; a trailing comment falls to the
catch-all, which yields a different shape but never a broken one.

### Why so little else needed changing

Worth recording because it is load-bearing and non-obvious: `field-name`
returns `#f` for a record, and every generic accessor
(`record-has-field?`, `record-field-ref`, `record-field-set`,
`record-field-remove`) is driven by `field-name`. Comments are therefore
invisible to inspection and rewritten around for free, with no explicit test
for them anywhere. The pass-through property is structural, not a patch
applied 25 times — which is also why a future editor can break it in one line.
That is the point of the RULE section in the purpose file.

## Deviations

1. **`pretty-print-with-comments` reflows the file to `guix style` conventions,
   so an edited config comes back restyled** (visible in the excerpt above:
   deeply nested forms end up heavily indented, past 78 columns). This is not a
   regression — the old `pretty-print` reflowed too, *and* deleted the comments
   — and the prompt's Definition of Done does not ask for byte-preserving
   formatting. It is bounded by `run-config-edit`, which writes nothing when the
   transform changed nothing, so a config is only ever restyled by an edit that
   was actually requested. Flagged because it is the most visible user-facing
   consequence of this stage. `(guix read-print)` exposes no
   "preserve original layout" mode.

2. **`oracle/tests/test-oracle-preferences.scm` was modified**, under the
   allow-list's conditional permission. Three changes, all forced by the
   prompt's own instruction to delete the gexp reader:
   - It bound `read-config/gexp`, which no longer exists -> now binds
     `read-config`.
   - It asserted `(= 3 (length before))` on a config's top-level items. Item
     count is no longer form count now that comments are nodes -> it filters
     through a new `code-forms` helper first.
   - It asserted **`"#~ reads as (gexp ...) and #$ as (ungexp ...)"`**. That
     assertion is now false *by design* — it described the deleted reader's
     representation, which is exactly the behaviour this stage removes. It is
     replaced by the inverted assertion: the written config must still spell
     gexps `#~`/`#$` and must **not** contain `(gexp `. Net check count is
     unchanged at 61, and all 61 pass.

3. **`(ice-9 pretty-print)` was removed from the imports.** It was imported
   solely for `pretty-print`, the lossy printer this stage replaces. This is a
   removal I was not explicitly told to make (guardrail 7), so it is disclosed
   here rather than assumed; it is directly entailed by the mandated
   `write-config` change, and leaving it would invite confusion about which
   printer is in use. Trivially revertible.

4. **`read-with-comments` in a loop, not `read-with-comments/sequence`.** The
   `/sequence` variant is the obvious API choice and is wrong here: it discards
   the `<vertical-space>` nodes. Measured on the fixture, loop = 106 top-level
   items, `/sequence` = 100. Those nodes are what keep a comment on its own
   line; without them a comment following a blank line is re-emitted **glued to
   the previous form as a margin comment**:
   `(use-service-modules networking shepherd ssh);; wget: for %metadata-ssh-...`
   That is a *relocated* comment, which is worse than a deleted one. Recorded
   in the purpose file so nobody "simplifies" it back.

5. **`(guix read-print)` is resolved with `resolve-interface` inside a `catch`
   rather than `use-modules`,** to satisfy the prompt's requirement of a clear
   message instead of a `no code for module` backtrace. Cost: the bindings are
   runtime values rather than syntax. Nothing here needs them to be syntax, and
   `oracle/tests/test-oracle-preferences.scm`'s `load-helper-bindings`
   (which `eval`s the helper's top-level forms one at a time) still works.

6. **The prompt's "`#$` orig=13" is an occurrence count, not a line count.**
   The fixture has 13 `#$` occurrences on **11** lines — lines 104 and 107 carry
   two each. My first draft asserted line counts and failed, because reflowing
   legitimately splits those lines (11 -> 13). The suite now counts
   **occurrences** for `#~`/`#$`, which is the invariant that actually holds and
   the one worth enforcing, and **lines** for `;;` (134 -> 134). Noted because
   the prompt's table reads as though both were line counts.

## Not done / coordinator follow-up

- **`SOURCE_MANIFEST.txt` is now stale and I did not touch it**, per the
  pipeline README (shared file, coordinator regenerates after merge).
  `lib/guile-config-helper.scm` is covered by the manifest and its hash changed:
  manifest has `0ece64fe...`, the file is now `c7f1547d...`. **The coordinator
  must run `./update-manifest.sh`.** Note that
  `lib/validate-before-deploy.sh` reports `[PASS] Source manifest is
  up-to-date` in this state, so that check does not catch it — it evidently does
  not compare hashes.

## Open questions (noticed, deliberately not acted on)

1. **`rewrite-base-services` does not rewrite comment text.** A comment saying
   "we use %base-services here" goes stale when the code switches to
   `%desktop-services`. I left prose alone deliberately — mechanically editing a
   human's sentence is how a comment starts lying about more than it did — but
   `switch-to-desktop` can now leave a config whose comments contradict its
   code. Worth a human decision.

2. **New list elements are appended after any trailing comment.** In
   `add-module-to-use-modules` and `add-service-to-services`, a new item goes at
   the very end, so a non-margin trailing comment ends up *above* it. Inserting
   before the comment instead would break **margin** comments (`(gnu) ; about
   gnu`), which attach to the preceding item — the new item would silently
   acquire that comment. Appending is the safe choice; a position-aware
   insertion that distinguishes `margin?` would be better and is more work than
   this stage warrants.

3. **`has-module?` appears to be unused.** Dead since before this stage; not
   removed (guardrail 7). Flagging for the human.

4. **The reflow in Deviation 1 pushes deeply nested code well past 78 columns.**
   If restyling a user's config is judged unacceptable, the fix is not to revert
   this stage but to make `write-config` layout-preserving, which
   `(guix read-print)` does not currently support and would be its own stage.

## Unverified claims

- Everything above about comment/gexp preservation, counts, evaluation and the
  two `match` fixes was **measured on this machine** on 2026-08-08 against the
  real `oracle/image/oracle-image.scm`.
- **Not verified on real hardware or a live OCI instance.** The helper is
  exercised here only through `guile` on a developer machine and through
  `guix repl` evaluation. No `guix system reconfigure` was run, and no edited
  config was booted. The claim "the edited config still evaluates to an
  `<operating-system>`" is exactly that — evaluation, not a build and not a boot.
- The availability claim for `(guix read-print)` (system profile, bare `guile`,
  no `guix repl`) was re-confirmed on this machine, which is a Guix system. It
  is **asserted, not tested,** for the Oracle image and a fresh install; the
  reasoning is that `guix` is in `%base-packages`. The new "unavailable" error
  path was written but **never triggered on a machine that actually lacks the
  module.**
- Deviation 4's `/sequence` finding is measured on one fixture. I did not read
  `(guix read-print)`'s source to confirm *why* `/sequence` drops vertical
  space; the behaviour is reproduced by a four-line test, not explained.
