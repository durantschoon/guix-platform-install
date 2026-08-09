# `web/` — the page you show a friend

One file: `index.html`. It explains how to get Guix System onto an Oracle Cloud
Always Free VM, shows the exact commands, and links to the reference docs in
this repository.

**It is presentation only.** It deploys nothing, calls nothing, and collects
nothing. This is [ORACLE_ONE_CLICK_ROADMAP.md](../docs/ORACLE_ONE_CLICK_ROADMAP.md)
step 6, resolved in favour of the option the roadmap recommends — OCI's own
console is already the authenticated UI, and a page that launched resources on
someone's behalf would have to hold their credentials.

## How to view it

```sh
firefox web/index.html          # or: open web/index.html
```

No server, no build step, no dependencies. It is designed to work from a
`file://` URL, which is also the fastest way to check a change.

## How to publish it

`web/index.html` is the whole deliverable, so publishing is copying one file.

- **GitHub Pages** — in the repository's *Settings → Pages*, serve from the
  `main` branch with folder `/docs`, or point a Pages workflow at `web/`. The
  file has no absolute asset paths, so it does not care what directory it is
  served from.
- **Object Storage / any static host** — upload `index.html`. There is nothing
  else to upload.

## What must stay true of this file

These are constraints, not preferences. Each one exists because breaking it
changes what the page *is*.

1. **One file, self-contained.** Inline CSS only. No external stylesheet, font,
   script, image, analytics, or tracker; no runtime network request of any
   kind. A page about not trusting a third party with your cloud account should
   not itself phone one. Practically: it also means the file works offline and
   from a USB stick.
2. **No `<form>`, `<input>`, or `<textarea>`. Ever.** Not for an OCI API key,
   not for a tenancy OCID, not for a private key, not for an email address.
   This repository must never be a place someone types a credential — see
   guardrail 9 in [../docs/stages/README.md](../docs/stages/README.md). If a
   change appears to need an input field, that change is out of scope for this
   page.
3. **No JavaScript at all**, not even inline. A copy-to-clipboard button is the
   obvious temptation; it is not worth being the reason this page stops being
   auditable by reading it. Selecting text works.
4. **Unverified stays labelled unverified.** The status section near the bottom
   names what has not been proven. Delete a row from it only when the thing it
   describes has actually been done — currently the published generic image
   (roadmap step 2) and a live-instance test of the metadata SSH key service.
5. **Commands are copied, not paraphrased.** The `personal-config.scm`
   one-liner in the page is byte-identical to the one in
   [../docs/PERSONAL_CONFIG_CONTRACT.md](../docs/PERSONAL_CONFIG_CONTRACT.md).
   If you change one, change both, and diff them.

## What does not apply here

The repository's **ASCII-only** rule (`CLAUDE.md`) is about the Guix ISO
terminal and the OCI serial console, which mangle non-ASCII. This page renders
in a browser, so `→`, `—` and typographic quotes are fine. Do not "fix" them.

Neither `lib/validate-before-deploy.sh` nor `run-tests.sh` inspects HTML, and
`SOURCE_MANIFEST.txt` does not cover it — the manifest hashes Go, the bootstrap
shell scripts, and `postinstall/recipes/*.scm`. Changing this file does not
require regenerating the manifest.
