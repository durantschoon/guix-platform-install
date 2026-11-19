# Hardware-Faceted Solution Sharing

**Status: idea, not started.** Documented now so it is not re-derived later.
No commitment, no schedule.

## The idea

You have a problem. You know some facts about your situation, and nothing
else. You should be able to name those facts, one at a time, and have the
candidate set narrow until one answer is left:

```
guix-system                        -> thousands
guix-system + framework-13         -> dozens
guix-system + framework-13 + amd   -> a handful
guix-system + framework-13 + amd + audio-capture  -> one
```

That is **faceted classification** -- a concept lattice, not a tag cloud.
Stack Overflow already has tags, but they are flat and unordered: you search
with them, you do not *descend* through them, and nothing tells you that
adding `amd` would cut the set from 40 to 3.

The analogy that prompted this: `wikidata : wikipedia :: this : stackoverflow`.
A structured, queryable layer over what is currently prose.

## Prior art, and the one that actually works

| | What it is | Verdict |
|---|---|---|
| [`nixos-hardware`](https://github.com/NixOS/nixos-hardware) | Per-machine modules in a directory tree: `framework/13-inch/7040-amd`. You import the path and your hardware works. | **This is the idea, already working.** |
| linux-hardware.org | Faceted database of hardware probes. | Good at "does it work", not "here is the fix". |
| Arch Wiki per-laptop pages | Prose, one page per model. | The page title *is* the facet join. Decays silently. |
| Stack Overflow tags | Flat, unordered. | Search, not descent. |

**`nixos-hardware` is the design to copy, and the reason it works is worth
stating plainly: the leaf node is executable config, not prose.** That single
property fixes the failure mode of every wiki and Q&A site -- prose answers rot
silently, while config answers break loudly on somebody's machine and get
fixed. Freshness is enforced by use, not by moderation.

It is also implemented as a **directory tree, not a website**. The facets are
path components. No search box, no database, no hosting.

## The gap

**There is no Guix equivalent.** Not a crowded space -- an empty one.

## Why this repo

This repo is already faceted by hardware; it just has not been named as such:

```
framework/                       single-boot
framework-dual/                  dual-boot
known-good/framework-dual-geeeks hardware + layout + machine
```

`known-good/framework-dual-geeeks` is already a three-facet join. The same
pattern independently appeared in the author's dot_files as
`docs/learning/<facets>.md`:

```
amd-strix-point-gfx1152-mesa.md    vendor-arch-chipid-subsystem
linux-tty-keyd-hidpi.md            os-surface-tool-property
wayland-tty-drm-seat.md
```

So the convention is already in use in two repos by accident. This document is
about doing it on purpose, and publishing it.

## The worked example that motivated this

Facets: `framework-13` + `amd` + `guix-system` + `audio-capture`.

Claude Code's voice mode reported "No speech detected" on a machine whose
microphone was fine. The chain: its bundled native capture module cannot load
on Guix (the launcher's `--library-path` has no `libasound`, and the load is
inside a `try/catch`), `arecord` was not installed, so it fell through to
sox `rec`, which appends `silence 1 0.1 3% 1 2.0 3%` and discards everything
below 3% amplitude. The internal mic idles at 0.43% and speech barely clears
the gate, so the whole stream was thrown away before Claude Code saw a sample.

The fix is one package: `alsa-utils`, because the `arecord` path streams raw
with no silence gate. Recorded in dot_files as commit `533ffbf`.

Nothing about that was discoverable from the error message, and every element
of the diagnosis was specific to the facet join. This is exactly the shape of
knowledge that currently has nowhere to live.

## The GIPS angle

GIPS is a peer-to-peer alternative to Guix substitute servers. Hardware
profiles are small, content-addressed artifacts -- the same shape as the
substitutes GIPS already moves. So the distribution problem may already be
solved:

- a machine computes a **hardware fingerprint** (PCI/DMI ids, codec names,
  `/proc/asound/cards`) and subscribes to profiles matching it
- publishing a fix is a push, not a pull request to a central repo
- no website, no moderation queue, no hosting bill

**The hard part is trust, and it is harder than for substitutes.** A substitute
is a build of a package you already chose, verifiable against its derivation. A
hardware profile is *arbitrary config you have not read*, which is to say code
execution. "Everyone with your hardware can send you system configuration" is a
supply-chain attack with extra steps unless it is gated.

Radicle gives signed refs and an explicit delegate set, and GIPS stage 18
already added auth for mutating endpoints, so the primitives exist. But the
policy question -- whose profiles do I accept, and does matching hardware imply
any trust at all (it does not) -- has to be answered before this is built, not
after.

## Open questions

1. **Facet vocabulary.** Who defines the axes? `nixos-hardware` dodges this by
   using vendor/model paths, which is honest and limited: it cannot express
   `audio-capture` as a facet at all. A real lattice needs a controlled
   vocabulary, and that is where this kind of project usually dies.
2. **Leaf granularity.** A whole machine profile (nixos-hardware) or a single
   fix (`alsa-utils` for voice capture)? The example above is a one-line fix,
   not a machine profile. Probably both, at different depths.
3. **Channel or repo?** A Guix channel exposing `(framework 13 amd)` modules is
   the direct analogue and needs no infrastructure. GIPS distribution is a
   later layer, not a prerequisite.
4. **Relationship to upstream.** Guix has no hardware-modules tradition.
   Whether this lives as a third-party channel or is proposed upstream changes
   the vocabulary question a lot.

## Smallest useful first step

A channel with exactly one module, `(framework 13 amd)`, containing the fixes
already proven on `geeeks` -- gfx1152 Mesa override, keyd, audio capture. One
real module beats a schema for zero modules, and it is the artifact that would
tell us whether the facet vocabulary question needs solving at all.
