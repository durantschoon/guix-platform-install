# Stage 02 — Presentation-only web page for the Oracle flow

## Motivation

The repo's owner wants to convince friends to run Guix System on Oracle Cloud's
free tier, and needs something to show them. Today the flow lives in
`oracle/README.md` and `docs/PERSONAL_CONFIG_CONTRACT.md` — accurate, but they
are reference documents written for someone already inside the project.

[docs/ORACLE_ONE_CLICK_ROADMAP.md](../ORACLE_ONE_CLICK_ROADMAP.md) step 6 records
the scoping decision that governs this stage:

> The honest recommendation: build the presentation-only version first. It is
> most of the value at a fraction of the risk, and OCI's console already
> provides the authenticated UI.

## The change

Add a single self-contained static page: `web/index.html`.

**Presentation only.** It explains the flow, shows the exact commands to copy,
and links to the real docs. It performs no deployment.

Content, in order:

1. **What this is** — Guix System, declarative and reproducible, on an
   always-free Oracle VM. Short and honest; no marketing superlatives.
2. **What you need** — an OCI account, an SSH key pair, ~20 minutes. State
   plainly that Always Free capacity is sometimes exhausted and that this is
   normal (see stage 01).
3. **The steps**, numbered, matching the roadmap's step 3 console-only path:
   import the image, launch pasting your public key into the console's
   **Add SSH keys** field, `ssh guix@<ip>`, then run the personal-config
   one-liner.
4. **The one-liner**, in a copy-friendly block:
   ```
   wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
     | guile --no-auto-compile -s /dev/stdin
   ```
5. **Bring your own config** — a short explanation of `guix-personal.scm` with
   the example from `docs/PERSONAL_CONFIG_CONTRACT.md`, linking to that doc.
6. **Status / honesty section.** Required, not optional: state which parts are
   verified and which are not. As of now the published generic image
   (roadmap step 2) **does not exist yet**, and the metadata SSH key service
   **has not been verified on a live instance**. The page must not imply
   otherwise.

## Ground rules

- **Self-contained**: one HTML file, inline CSS. No external stylesheets,
  fonts, scripts, analytics, or trackers. No network requests at runtime.
- **No build step.** No npm, bundler, or framework. It opens with
  `file://` and works.
- **Readable in both light and dark**, via `prefers-color-scheme`.
- **Responsive**: usable on a phone; wide content (command blocks) scrolls
  inside its own container rather than making the page scroll sideways.
- Unicode **is** allowed here — this renders in a browser, not on the Guix ISO
  console. The ASCII rule applies to scripts, not to this page.
- **Accuracy over polish.** Every command shown must be one that actually
  works today, or be clearly marked as not-yet-available. Do not invent a
  download URL for an image that has not been published.
- **Absolutely no credential collection.** No forms, no inputs that accept OCI
  API keys, tenancy OCIDs, or private keys. This is guardrail 9 in
  [README.md](README.md) — if the design seems to need it, **STOP**.

## Allowed files (whitelist)

```
web/index.html               (new)
web/README.md                (new -- what this is, how to view, how to publish)
docs/ORACLE_ONE_CLICK_ROADMAP.md   (update step 6 status only)
```

Do **not** touch `run-tests.sh` — stage 01 owns it this round. Do not touch
`SOURCE_MANIFEST.txt` or `CHECKLIST.md`.

## Tests (enumerated — all required)

There is no test framework for HTML here and you must not add one. Instead,
verify and record the following in the report, each with the command used:

1. The file is valid standalone HTML — opens and renders with no console
   errors.
2. `rg -n "http://|https://" web/index.html` — every external URL is a **link**
   (`href`), never a runtime fetch (`src`, `@import`, `fetch`). List them.
3. No `<form>`, `<input>`, or `<textarea>` anywhere.
4. No `<script src=`, no `<link rel="stylesheet"`, no `@import`.
5. The one-liner in the page is character-for-character identical to the one in
   `docs/PERSONAL_CONFIG_CONTRACT.md`. Show the diff proving it.
6. The honesty section is present and names both unverified items.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
```

Neither gate covers HTML; they must still pass, proving nothing was broken.
Baseline (inherited, do not fix): validation Passed 6 / Failed 0 / ~15 warnings;
`run-tests.sh` exit 0 with 14/14 converted-script tests failing.

## Commit message (exact, single line)

```
feat(web): presentation-only page for the Oracle free-tier flow
```

## Report requirements

Write `docs/stages/stage-02-REPORT.md` with:

- **What changed**, file by file.
- **Gate output**: actual tails, pasted.
- **The six verification results** above, each with its command and output.
- **Deviations** and why.
- **Open questions** — in particular, anything the page had to hedge because
  the underlying capability is not built yet.

## Blocked protocol

If the design appears to require collecting any credential, launching any cloud
resource, or claiming something is available when it is not — **stop and write
the REPORT with a `Blocked:` section**. Do not improvise.
