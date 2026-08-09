# Stage 02 — REPORT

**Prompt:** `docs/stages/stage-02-PROMPT.md` (committed on `main` at `cdd3683`)
**Branch:** `stage-02-web-page`
**Base commit:** `cdd3683` — *docs(stages): scaffold the stage pipeline and author stages 01-02*
**Result:** completed, not blocked. No guardrail conflict arose.

---

## Checklist echo

| # | Prompt requirement | Done |
|---|---|---|
| 1 | Section "What this is" — Guix, declarative, on an always-free Oracle VM | yes |
| 2 | Section "What you need" — account, SSH key pair, ~20 min, capacity is normal | yes |
| 3 | Numbered steps matching roadmap step 3 (import, launch + Add SSH keys, `ssh guix@<ip>`, one-liner) | yes |
| 4 | The one-liner in a copy-friendly block | yes |
| 5 | "Bring your own config" with the `guix-personal.scm` example, linking the contract | yes |
| 6 | Status/honesty section naming both unverified items | yes |
| — | Self-contained, inline CSS, no external anything, no runtime network | yes |
| — | No build step; works from `file://` | yes |
| — | Light + dark via `prefers-color-scheme` | yes |
| — | Responsive; wide blocks scroll inside their own container | yes |
| — | No `<form>`, `<input>`, `<textarea>` | yes |
| — | Did not touch `run-tests.sh`, `SOURCE_MANIFEST.txt`, `CHECKLIST.md` | yes |

---

## What changed, file by file

### `web/index.html` (new, 639 lines, 22215 bytes)

The page. One file, one `<style>` block, zero script tags, zero `<link>` tags.

Order of content follows the prompt exactly: a "read this first" callout that
points at the status section, then **What this is**, **What you need**, **The
steps** (5 numbered), **The one command**, **Bring your own config**,
**Status: what is verified and what is not**, **Where to read further**,
footer.

Content decisions worth recording:

- **Step 1 does not give an image URL.** It says the published image does not
  exist and that the interim path is for someone who already runs Guix to build
  it via `oracle/README.md`. No invented URL anywhere in the file.
- **Step 2 names the two non-optional import fields** (QCOW2, Paravirtualized)
  and states what `Native` costs you, from `oracle/README.md` §4.
- **Step 3** describes the console's **Add SSH keys** box as the mechanism, and
  carries an inline note linking to the status section, so a reader cannot meet
  that instruction without meeting the caveat.
- **The capacity callout** in "What you need" states "Out of host capacity" is
  normal, names the two remedies (another availability domain, or the ARM
  `VM.Standard.A1.Flex` shape), and says a retry loop does not reliably fix it.
  Sourced from roadmap step 5, which stage 01 is implementing concurrently;
  this page only describes the situation, it does not describe stage 01's code.
- **The footer states the page will never ask for a credential**, and that
  anything claiming to be part of this project which does is a signal to stop.
  That is a deliberate anti-phishing line, since the page's whole subject is a
  cloud account.
- Theme: CSS custom properties on `:root` overridden inside a
  `@media (prefers-color-scheme: dark)` block. `<meta name="color-scheme">` is
  set so the browser's own UI (scrollbars, form-less default backdrop) matches.
- Scroll containment: `body { overflow-x: hidden }` plus `.scroll { overflow-x:
  auto }` around every `<pre>`, and `overflow-wrap: anywhere` on inline `<code>`
  so long store paths cannot widen the page either.

### `web/README.md` (new, 70 lines)

What the directory is, how to view it (`firefox web/index.html`, no server), how
to publish it (GitHub Pages or any static host — it is one file with no absolute
asset paths), and five constraints stated as constraints with the reason each
exists. Also records the two things that *do not* apply here: the repo's
ASCII-only rule (that is about the ISO terminal and the serial console, not a
browser), and the manifest (which covers Go, the bootstrap shell scripts, and
`postinstall/recipes/*.scm` — not HTML).

### `docs/ORACLE_ONE_CLICK_ROADMAP.md` (modified — step 6 status only)

Three edits, all status:

1. Header line: "Step 1 is implemented; steps 2-6 are not started" →
   step 6 is implemented in its presentation-only form; steps 2-5 are not started.
2. Step 6 section: added a status paragraph recording that the scope question is
   settled in favour of presentation-only, that the "driving the deployment"
   bullet remains not started and not approved, and that the page's hedges come
   out only when steps 2 and 3 actually land. The original scoping bullets are
   kept verbatim below it, relabelled as the reasoning.
3. Effort table row 6: `Blocked by: Step 3` → `**DONE** — web/index.html; hedges
   on steps 2-3 until they land`.

Nothing else in that file was touched. Steps 1-5 read as before.

---

## Gate output

Both gates were run on the unmodified base commit **before** any edit, and again
after. The numbers are identical; the page changed nothing either gate can see,
which is the point.

### `lib/validate-before-deploy.sh --verbose`

**Baseline (at `cdd3683`, no edits) — exit 0**

```
Checking source manifest...
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
```

**Final — exit 0**

```
Checking source manifest...
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
```

| | baseline | final |
|---|---|---|
| exit code | 0 | 0 |
| Passed | 6 | 6 |
| Warnings | 15 | 15 |
| **Failed** | **0** | **0** |

The 15 warnings are the inherited set named in `docs/stages/README.md`. None
were introduced and none were "fixed".

`Source manifest is up-to-date` still passes: `update-manifest.sh` hashes
`*.go`, a fixed list of `lib/*.sh` and root `*.sh`, and
`postinstall/recipes/**/*.scm`. It does not cover `.html` or `.md`, so this
stage does not make the manifest stale. The coordinator does not need to
regenerate it for stage 02.

### `./run-tests.sh`

**Baseline (at `cdd3683`, no edits) — exit 0**

```
[WARN] Converted script tests: 14/14 failed
  These are auto-generated tests that need manual fixes.
  ...
=== All Tests Completed Successfully! ===

Test Summary:
[OK] Common library functions (MakePartitionPath, DetectDeviceFromState, etc.)
[OK] Framework-dual integration tests
[OK] String operations and error handling
[OK] Function signatures and accessibility
[OK] State management and persistence
```

**Final — exit 0**

```
[WARN] Converted script tests: 14/14 failed
  These are auto-generated tests that need manual fixes.
  ...
=== All Tests Completed Successfully! ===

Test Summary:
[OK] Common library functions (MakePartitionPath, DetectDeviceFromState, etc.)
[OK] Framework-dual integration tests
[OK] String operations and error handling
[OK] Function signatures and accessibility
[OK] State management and persistence
```

| | baseline | final |
|---|---|---|
| exit code | 0 | 0 |
| converted-script tests | 14/14 failing | 14/14 failing |

Unchanged, as expected: `run-tests.sh` was not touched (stage 01 owns it) and
nothing in this stage is executable.

*(The `[OK]` markers above are transcribed from the runner's `✓`; the runner
prints Unicode, this report does not depend on it.)*

### `git diff cdd3683 --stat`

```
 docs/ORACLE_ONE_CLICK_ROADMAP.md | 20 ++++++++++++++++----
 1 file changed, 16 insertions(+), 4 deletions(-)
```

Plus two untracked new files, which `--stat` does not show:

```
 web/index.html   | 639 +++++++++++++++++++++++++++++++++++++++++++
 web/README.md    |  70 +++++
```

`git status --porcelain` before staging showed exactly:

```
 M docs/ORACLE_ONE_CLICK_ROADMAP.md
?? web/
```

Nothing outside the whitelist was modified.

---

## The six enumerated verifications

### 1. Valid standalone HTML, renders with no console errors

Structural parse with Python's `html.parser`, checking doctype, tag balance,
and the absence of any element or attribute that can issue a request:

```
$ python3 htmlcheck.py
file:            .../web/index.html
bytes:           22215
doctype:         'doctype html'
unclosed at EOF: none
nesting errors:  none
resource/event attrs (src, on*, ping, ...): none
forbidden elements present: none

element counts: {'a': 13, 'body': 1, 'code': 32, 'dd': 5, 'div': 12, 'dl': 1,
'dt': 5, 'em': 7, 'footer': 1, 'h1': 1, 'h2': 7, 'h3': 5, 'head': 1,
'header': 1, 'html': 1, 'li': 11, 'meta': 4, 'ol': 1, 'p': 30, 'pre': 4,
'span': 9, 'strong': 15, 'style': 1, 'table': 1, 'tbody': 1, 'td': 6, 'th': 2,
'thead': 1, 'title': 1, 'tr': 4, 'ul': 2}

RESULT: PASS
EXIT=0
```

Rendered for real, from a `file://` URL, in headless Firefox with a throwaway
profile:

```
$ firefox --headless -profile <tmp> --no-remote --window-size 900,1400 \
    --screenshot page-light.png \
    file:///.../web/index.html
Screenshot saved to: .../page-light.png
```

Four screenshots were taken and inspected: light at 900px, dark at 380px, and
two showing the lower sections (steps, status table, footer). All render as
intended; the numbered step markers, the status badges, and the table are
correct in both themes, and at 380px nothing overflows.

**Console errors: none from the page.** Firefox emits a wall of
`console.error: services.settings: ... NetworkError` and
`AboutHomeStartupCache` messages, but every one has a `resource://gre/...` or
`resource://services-settings/...` filename — they are Firefox's own telemetry
and remote-settings machinery failing because this sandbox has no network. The
page contributes nothing, which it cannot: it has no JavaScript at all. That
those are the *only* errors, in an environment with no network, is itself
evidence for verification 2.

**Responsive / scroll containment**, verified at a 380px viewport: the page is
exactly 380px wide with no horizontal page scroll, and the one-liner block
carries its own horizontal scrollbar inside the rounded container. Screenshot
inspected.

**Dark mode** verified by setting `ui.systemUsesDarkTheme=1` in the throwaway
profile's `user.js` and re-shooting.

### 2. Every external URL is a link, never a runtime fetch

```
$ rg -n "http://|https://" web/index.html
351:<p><a href="https://guix.gnu.org/">Guix System</a> is a Linux distribution where
358:<p><a href="https://www.oracle.com/cloud/free/">Oracle Cloud's Always Free
375:  <li>An <a href="https://www.oracle.com/cloud/free/">Oracle Cloud account</a>.
414:    <a href="https://github.com/durantschoon/guix-platform-install/blob/main/oracle/README.md">oracle/README.md</a>,
481:  <div class="scroll"><pre>wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
557:<a href="https://github.com/durantschoon/guix-platform-install/blob/main/docs/PERSONAL_CONFIG_CONTRACT.md">docs/PERSONAL_CONFIG_CONTRACT.md</a>.</p>
607:  <dt><a href="https://github.com/durantschoon/guix-platform-install/blob/main/oracle/README.md">oracle/README.md</a></dt>
611:  <dt><a href="https://github.com/durantschoon/guix-platform-install/blob/main/oracle/postinstall/README.md">oracle/postinstall/README.md</a></dt>
616:  <dt><a href="https://github.com/durantschoon/guix-platform-install/blob/main/docs/PERSONAL_CONFIG_CONTRACT.md">docs/PERSONAL_CONFIG_CONTRACT.md</a></dt>
619:  <dt><a href="https://github.com/durantschoon/guix-platform-install/blob/main/docs/ORACLE_ONE_CLICK_ROADMAP.md">docs/ORACLE_ONE_CLICK_ROADMAP.md</a></dt>
623:  <dt><a href="https://guix.gnu.org/manual/en/html_node/">The GNU Guix manual</a></dt>
629:  <a href="https://github.com/durantschoon/guix-platform-install">guix-platform-install</a>.
```

Twelve occurrences. Eleven are `href` on an `<a>`. The twelfth, **line 481**, is
inside `<div class="scroll"><pre>` — it is the `wget` URL *displayed as text for
the reader to copy and run on the instance*, not a URL the page retrieves. The
enumerated list, by destination:

| Destination | Kind |
|---|---|
| `https://guix.gnu.org/` | href |
| `https://guix.gnu.org/manual/en/html_node/` | href |
| `https://www.oracle.com/cloud/free/` (×2) | href |
| `https://github.com/durantschoon/guix-platform-install` | href |
| `.../blob/main/oracle/README.md` (×2) | href |
| `.../blob/main/oracle/postinstall/README.md` | href |
| `.../blob/main/docs/PERSONAL_CONFIG_CONTRACT.md` (×2) | href |
| `.../blob/main/docs/ORACLE_ONE_CLICK_ROADMAP.md` | href |
| `https://raw.githubusercontent.com/.../personal-config.scm` | **text inside `<pre>`** |

And nothing that could fetch:

```
$ rg -n "src=|@import|fetch\(|XMLHttpRequest|url\(|integrity=|crossorigin" web/index.html
rc=1
```

(`rc=1` is ripgrep for "no matches". Note this also rules out CSS `url(...)`,
so there is no background image or embedded font either.)

The `htmlcheck.py` run in verification 1 independently reports
`resource/event attrs (src, on*, ping, ...): none`.

### 3. No `<form>`, `<input>`, or `<textarea>`

```
$ rg -n -i "<form|<input|<textarea|<select|<button|contenteditable|autocomplete" web/index.html
rc=1
```

Checked wider than asked: also no `<select>`, no `<button>`, no
`contenteditable`, no `autocomplete`. `htmlcheck.py` confirms from the parse
side — `forbidden elements present: none`, against a list containing `form`,
`input`, `textarea`, `select`, `button`, `iframe`, `object`, `embed`, and
others. **There is nowhere on this page a person can type anything.**

### 4. No `<script src=`, no `<link rel="stylesheet"`, no `@import`

```
$ rg -n -i "<script|<link|@import|javascript:|on(click|load|error|submit|change|input)=" web/index.html
rc=1
```

No `<script>` **of any kind**, not merely no `src` — see deviation 2. No
`<link>` element at all, so no stylesheet and no preconnect/prefetch. No
`@import`, no `javascript:` URL, no inline event handler. The element counts in
verification 1 show `'style': 1` and no `script` or `link` key.

### 5. The one-liner matches the contract byte-for-byte

Extracted the first fenced block of `docs/PERSONAL_CONFIG_CONTRACT.md` and the
`<pre>` in `web/index.html` containing `personal-config.scm` (un-escaping HTML
entities), then diffed:

```
$ python3 verify.py
--- docs/PERSONAL_CONFIG_CONTRACT.md (first fenced block) ---
'wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \\\n  | guile --no-auto-compile -s /dev/stdin\n'
--- web/index.html (<pre> containing personal-config.scm) ---
'wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \\\n  | guile --no-auto-compile -s /dev/stdin\n'

sha256 contract: 4f7c35f7eaf615c0beea58fbc5054818d9fbb44bd4bdbe2ddf97edf143cc86a5
sha256 page:     4f7c35f7eaf615c0beea58fbc5054818d9fbb44bd4bdbe2ddf97edf143cc86a5

(diff is empty -- byte-for-byte identical)
RESULT: IDENTICAL
EXIT=0
```

`difflib.unified_diff` produced **zero lines** — that empty diff is the proof.
The `repr()` output above is included because it is the only form in which the
significant characters are visible: the trailing space before the `\`, the
two-space indent on the continuation line, and the final newline. Both are 172
bytes.

The same one-liner also appears verbatim in `oracle/postinstall/README.md`; all
three now agree.

### 6. The honesty section is present and names both unverified items

```
$ rg -n "does not exist yet|never run on a live|Status: what is verified" web/index.html
343:  ready-to-import image does not exist, and one piece of it has never been run on
559:<h2 id="status">Status: what is verified and what is not</h2>
579:      <td><strong>The published generic image does not exist yet.</strong> There
586:      <td><strong>The metadata SSH key service has never run on a live
```

The section is a three-row table at `#status`:

- **YES** — build, QEMU smoke test, upload, import, launch with sshd answering,
  done end-to-end 2026-08-08 with a key baked into the image.
- **NO** — *"The published generic image does not exist yet."* No URL to import
  from; the page does not link to one.
- **NO** — *"The metadata SSH key service has never run on a live instance."*
  Names why (QEMU has no metadata service, so only the "no metadata" path is
  covered) and tells the reader to assume they may need a baked-in key instead.

It is not only at the bottom. Line 343 is a **"read this first" callout above
the fold**, before any instruction, saying parts of the flow are not finished
and linking to `#status`; and line 448 is an inline note attached to step 3
itself, the one step that depends on the unverified service. A reader cannot
follow the instructions without meeting the caveat.

---

## Deviations

1. **Branch name.** Neither `stage-02-PROMPT.md` nor `docs/stages/README.md`
   specifies one, so I used `stage-02-web-page`.

2. **Zero JavaScript, which is stricter than asked.** Test 4 forbids
   `<script src=`, which permits an inline `<script>`. I wrote none. A
   copy-to-clipboard button was the obvious candidate — "copy-friendly" is the
   prompt's word — but the page's subject is *do not hand your cloud credentials
   to a web page*, and a page you can audit by reading it makes that argument
   better than a page with a button on it. Selecting the text works. Recorded
   as constraint 3 in `web/README.md` so the next editor knows it was a
   decision, not an omission. Flagged as an open question below.

3. **Base commit.** The worktree was created at `64b35fd`, three commits behind
   `main`. Since `docs/stages/stage-02-PROMPT.md` — the canonical text — exists
   only at `cdd3683`, I reset the branch to `main` (`cdd3683`) before doing
   anything, and measured the baseline there. Working tree was clean; nothing
   was discarded.

4. **The roadmap edit touches three places, not one.** The prompt says "update
   step 6 status only". Step 6's status is asserted in three places in that
   file: the document header ("steps 2-6 are not started"), the Step 6 section,
   and the effort table. Updating only the section would have left the header
   stating the opposite. All three edits are status; no step 1-5 text changed.

5. **Two facts on the page come from documents outside the four I was pointed
   at.** The capacity remedies (other availability domain, `VM.Standard.A1.Flex`)
   are from roadmap step 5. The `%base-packages` claim behind "a fresh Guix
   System already has `wget`, `guile` and `nss-certs`" is from
   `docs/PERSONAL_CONFIG_CONTRACT.md` — that one is in scope, noting it only
   because it is a factual claim a reviewer may want to trace.

6. **Diagnostic copies of the page were written to the scratchpad, not the
   repo.** To screenshot the lower sections, headless Firefox always renders
   from the top of the document, so I generated throwaway copies with earlier
   sections hidden by an appended CSS rule. Those live only in the session
   scratchpad. `web/index.html` was never modified for testing.

7. **No `--force` / no HTML validator binary available.** `tidy`, `vnu`, and
   any Chromium were absent from this environment; only Firefox was present. So
   verification 1's "valid HTML" is a strict `html.parser` structural parse plus
   real rendering in Firefox, not a W3C conformance run. A reviewer with the Nu
   validator may want to confirm.

---

## Open questions

1. **Should the page have a copy button?** See deviation 2. It is one small
   inline `<script>` and it genuinely helps on a phone, where selecting a
   two-line command inside a horizontally-scrolling box is fiddly. I judged the
   "no JS at all" property more valuable for *this* page. This is a call the
   repo owner may want to overturn; if so, it should be an explicit decision
   recorded in `web/README.md`, not a quiet addition.

2. **Step 1 currently has no path a Guix-less friend can follow.** The whole
   point of the page is a friend who does not have Guix, and step 1 tells them
   to find someone who does. That is honest, and it is exactly what roadmap
   step 2 fixes — but until step 2 lands, the page's premise is not yet
   deliverable. When the image is published, step 1 becomes a URL and a
   checksum, and the second status row is deleted.

3. **The page has no screenshots.** Roadmap step 3 says its deliverable is
   "documentation plus screenshots". Console screenshots would help enormously
   at steps 2 and 3 (the import dialog and the **Add SSH keys** box are where a
   novice gets lost), but embedding them means base64 data URIs in a
   self-contained file, which would multiply its size, and taking them requires
   a live OCI console session — which is human-gated. Not attempted. Worth a
   later stage once someone is in the console anyway for the live-instance test.

4. **Nothing links *to* `web/index.html` yet.** The root `README.md` and
   `oracle/README.md` do not mention it, and both are outside this stage's
   whitelist. Someone browsing the repo will not find the page. A one-line
   pointer in each is the obvious follow-up.

5. **Publishing is documented but not configured.** `web/README.md` explains
   GitHub Pages and static hosting; no Pages workflow or `.nojekyll` was added,
   since neither is in the whitelist and publishing is the owner's decision. If
   Pages is wanted from `/docs`, the file has to move or be copied — worth
   deciding before anyone links to a URL.

6. **The status table will rot silently.** It is prose, and nothing checks it
   against `docs/ORACLE_ONE_CLICK_ROADMAP.md`. When step 1's live-instance test
   passes, three files must change together (the roadmap, `oracle/README.md`'s
   "Not yet verified on a live instance" line, and this page). Nothing enforces
   that. A grep-based check in `lib/validate-before-deploy.sh` could — but that
   file is shared and coordinator-owned, so I did not touch it.

7. **`prefers-color-scheme` only; no manual theme toggle.** A toggle needs
   JavaScript. Consistent with deviation 2.
