# GIPS Substitute Benchmark Protocol

**Status: pre-registered 2026-09-20. No live trial has been run. The GIPS arm
is now *time-to-available* (amendment 3, section 9); the harness implements it
but has never executed on a Guix machine. Blocked on live two-node discovery
(amendment 3(e)).** Everything
below was fixed before any data existed, and the analysis code
(`oracle/scripts/gips-benchmark.scm report`) has so far only seen synthetic
rows. When the first real numbers land, this file gets a dated results section
appended; sections 1-7 do not get edited to fit them. If the protocol has to
change, the change is recorded in section 9 with the reason, and data collected
under the old rules is reported separately.

**Terms used below.** NAR, narinfo and the IPFS vocabulary are defined in
[`gips/docs/glossary.md`](../gips/docs/glossary.md). Six Guix terms that
glossary does not cover:

- *store* -- `/gnu/store`, the directory where Guix keeps every installed
  package; a *store item* is one entry in it.
- *substitute* -- a pre-built store item downloaded instead of compiled.
- *closure* -- a store item plus everything it needs to run, transitively.
- *derivation* -- the build recipe for a store item; without one, Guix can
  only download the item, never compile it.
- *GC root* -- a reference that protects a store item from `guix gc`; anything
  with no root is deleted by the next collection.
- *arm* -- one of the two conditions compared: `central` or `gips`.

## 1. The question

On the same Guix machine, fetching the same store items into an equally cold
store, is substitution through GIPS faster than substitution from the central
servers (`ci.guix.gnu.org`, `bordeaux.guix.gnu.org`) -- and by how much, with
what uncertainty?

"Is there any improvement" is a legitimate outcome space of three: faster,
slower, no detectable difference. The harness is built so that all three can
be reported; section 6 of `oracle/tests/test-gips-benchmark.scm` proves the
verdict goes red on slower data and stays neutral on noise.

## 2. Why the obvious measurement is wrong

The tempting benchmark is `time guix build hello` against each URL, repeated a
few times. `gips/scripts/benchmark-sync.sh --full` does exactly this, and it
cannot produce a valid comparison: after the first fetch the item is *in the
store*, so every later run -- including the whole second arm -- is a no-op that
finishes in well under a second. Its best-of-N then reports the no-op. Four
separate caches have to be cold for a trial to mean anything:

| Cache | Survives between runs because | Reset |
|---|---|---|
| The store itself | the item is valid once fetched | `guix gc` (trial fetches hold no GC root) |
| Daemon narinfo cache | `/var/guix/substitute/cache` keeps hits *and* misses | delete its contents |
| Consumer's IPFS block store | kubo keeps fetched blocks | `ipfs repo gc` (GIPS arm) -- **insufficient: gipsd pins what it mirrors; see amendment 2(a)** |
| Kernel page cache | recently written nars stay in RAM | `drop_caches` |

Every reset step except the IPFS one is applied identically before both arms,
so the reset cannot itself favour an arm.

## 3. Design

**Randomized complete blocks, analysed as pairs.** A block is one `central`
trial and one `gips` trial, back to back, in an order drawn from a recorded
seed. Network conditions drift over an hour; inside a block both arms see about
the same weather, and the within-block difference cancels it. Running ten of
one arm and then ten of the other would let time of day pose as a GIPS effect.

**The workload is a list of literal store paths, fixed once on the hub.**
`hub-prepare` realizes a manifest and writes `workload.paths` and
`workload.closure`. Each trial then runs `guix build /gnu/store/...` on those
paths. Three consequences, all intended:

- the timed section is substitution only -- no package evaluation, no
  derivation computation, which on a 1/8-OCPU micro would swamp the signal;
- both arms fetch byte-identical closures regardless of the consumer's channel
  state;
- a trial cannot silently compile: a bare store path has no derivation to fall
  back to, so a missing substitute is a loud failure.

> **Superseded in part by amendment 2 (section 9).** The paragraphs below
> describe a cold on-demand GIPS fetch, which gipsd does not do today. They are
> kept as drafted so the record shows what was planned; which design replaces
> them is an open decision (`CHECKLIST.md` G1.0b).

**The GIPS arm gets GIPS only** (`--substitute-urls=http://127.0.0.1:8080`, no
central fallback). With a fallback, a GIPS miss is quietly served by
`ci.guix.gnu.org` and credited to GIPS.

**Provenance is checked per trial, from guix's own log.** Every
`downloading from <url>` line is attributed. A trial is `ok` only if the build
succeeded *and* every download came from the arm under test. Other statuses --
`failed`, `contaminated`, `unattributed` (zero downloads parsed), `not-cold`
(workload still in the store after reset) -- are kept in the results file and
counted in `attempted`, but excluded from timing. A block with one non-`ok` arm
is dropped whole, because keeping its good half would unpair the design.

**Preflight is a gate.** Before any trial, every closure item must have a
narinfo on each arm. A trial that fails because an arm never had the item
measures nothing about speed.

## 4. What is recorded

One tab-separated row per trial, schema `gips-benchmark-trial-v1`, appended and
flushed immediately so a lost guest keeps every finished trial:

`run_id workload block position arm status exit_code wall_ms rx_bytes tx_bytes
downloads_total downloads_from_arm downloads_other load1 started_utc`

`rx_bytes` (non-loopback, from `/proc/net/dev`) matters for interpretation:
the central servers send lzip/zstd-compressed nars, so if GIPS moves more bytes
and is still faster (or fewer and slower), the reader should see that. Raw
guix logs are kept next to the results file.

Failed trials are never re-run into better ones: `run` skips any
(workload, block, arm) that already has a row, whatever its status.

## 5. Conditions that must be written down with the results

The answer depends on these, so a result without them is not a result:

- consumer shape, region and image; hub shape, region, and whether hub and
  consumer share a VCN (Oracle's term for a private virtual network -- two
  guests in one VCN talk over the datacentre's internal links);
- number of GIPS peers holding the closure (the claim "one nearby peer beats a
  transatlantic server" differs from "a swarm beats a server");
- `guix describe` on the consumer, `gipsd` and `kubo` versions;
- workload name, item count, closure size in bytes;
- schedule seed, block count, wall-clock span of the run.

**The honest framing of topology.** The central servers are in Europe; an
Oracle consumer in Ashburn with a hub in the same VCN is close to GIPS's best
case. That is a real and common scenario (your second machine already has the
package), and it is the scenario the personal-sync use case is about -- but the
write-up must say it is that scenario and not imply a general result. A
far-hub or NAT-ed-home-hub configuration is a separate experiment with its own
results file.

## 6. Sample size

**20 blocks per workload per configuration, fixed in advance, analysed once.**
With the exact sign-flip test, fewer than 6 pairs cannot reach p < 0.05 at all;
20 leaves room for a few dropped blocks. There is no interim look: `report` may
be run on partial data to check the harness is healthy, but no verdict is read
from it and the run is neither stopped nor extended because of what it shows.
(The first draft said "10, extend to 20 if the interval straddles 1". That is
optional stopping -- two looks, stop at the first if significant -- and lifts
the false-positive rate from 5% to roughly 8%. See amendment 2.)

## 7. Analysis and decision rule

Per workload, `report` prints for each arm: attempted, ok, median, mean, SD,
median rx. Then, over complete pairs:

- mean and median of (central - gips) in ms, with a 10,000-resample percentile
  bootstrap 95% interval -- positive means GIPS was faster;
- **speedup** = geometric mean of central/gips, with a bootstrap 95% interval;
- exact two-sided sign-flip permutation p-value (no normality assumption;
  download times are right-skewed).

**Verdict:** `faster` if the speedup interval lies entirely above 1, `slower`
if entirely below, otherwise `no-detectable-difference`. The headline is the
speedup with its interval, not the p-value. The bootstrap and schedule use a
fixed, recorded LCG rather than Guile's `random`, so anyone can regenerate the
same numbers from the results file.

## 8. Known boundaries not yet crossed

Per `AGENTS.md`, these are beliefs about other systems that have not been
tested against those systems. Each is cheap to check on the first live guest
and must be checked before trusting a run:

| Assumed | How to check |
|---|---|
| Non-tty `guix build` logs `downloading from <url>` per item | one manual fetch; if not, every row is `unattributed`, which fails safe |
| `guix gc` removes the whole fetched closure (nothing else roots it) | `not-cold` status catches the outputs; spot-check a dependency |
| ~~`ipfs repo gc` empties what gipsd fetched (gipsd does not pin on the consumer)~~ **FALSE -- the mirror worker pins everything; see amendment 2(a)** | read from source 2026-09-20 |
| gipsd keeps no consumer-side nar cache outside IPFS | read `gips-http` nar handler; compare trial 1 vs trial 2 rx_bytes |
| `gips publish` of each closure item makes it fetchable from a second node | preflight on the consumer |
| The guest user can `sudo -n` | first reset step warns loudly if not |

`rx_bytes` is the backstop for all of them: a "cold" GIPS trial that received
almost nothing over the network was not cold.

## 9. Amendments

- **2026-09-20, before any data.** Added section 10 (claims) and section 11
  (deferred Goal 2 recommendations). Neither changes the design, the recorded
  fields, the sample size or the decision rule in sections 1-7.

- **Amendment 2, 2026-09-20, before any data -- from the seasoned-Guix review,
  with the gipsd claims re-checked against source by hand.** This one does
  change the design, which is what pre-registration before data is for.

  **(a) The cold GIPS arm in section 3 cannot exist with gipsd as it is
  today.** The route `guix-daemon` actually uses (`GET /<hash>.narinfo`,
  `get_native_narinfo_inner` in `gips/components/gips-http/src/lib.rs`) answers
  only from the local `substitutes` table or an imported snapshot, else 404; it
  never resolves through subscriptions. The only thing that creates those rows
  on a second node is the mirror worker, which every 60 s walks each subscribed
  feed and calls `ipfs.pin_add(artifact_cid)` **before** inserting the row
  (`lib.rs` ~4007-4016). So on the consumer, an item becomes visible to guix
  only after it has been fully downloaded and pinned. `ipfs repo gc` does not
  remove pinned blocks. Consequences: preflight passes only once the whole
  closure is already local; every GIPS trial would then be a loopback read
  from local disk with `rx_bytes` near zero; and it would have been reported
  as `ok` and as a very large speedup. Section 8 row 3 is **false**, and
  row 5 resolves as "fetchable only via subscribe + mirror, never on demand".

  This is not a bug in GIPS -- background sync then local serve is its design
  for personal sync -- but it means "install through GIPS vs install from
  central" is not a like-for-like network comparison. **Open design decision
  for the user; three honest options:**

  1. *Measure what GIPS really does:* time-to-available. Start a cold consumer,
     subscribe, and time from subscribe until the mirror worker has the full
     closure pinned, plus the (small) local install. Compare against central
     cold install. Needs no gipsd change; needs a consumer reset that unpins,
     `ipfs repo gc`s, deletes the mirrored rows and restarts gipsd. The 60 s
     mirror tick adds up to a minute of pure waiting and must be reported
     separately rather than hidden or subtracted quietly.
  2. *Add on-demand resolve to gipsd* (the native narinfo/nar handlers fall
     through to `resolve_manifest_entry`, without pinning). Then section 3
     stands as written. This is a GIPS feature, in `../GIPS`, with its own
     review -- and arguably the behaviour a newcomer assumes GIPS already has.
  3. *Both*, reported as two different claims.

  Recommendation: 1 first (it measures the shipped system and needs no new
  code in the thing under test), 2 as a follow-up if on-demand fetch is wanted
  for its own sake.

  **(b) Consumer-side state the reset missed.** gipsd holds an in-memory
  narinfo signature cache (TTL 3600 s) and resolve caches (TTL 300 s). Signing
  forks Guile per narinfo, which is expensive at 1/8 OCPU, so GIPS trial 1
  would pay it and trials 2..n within the hour would not. The reset must
  restart gipsd. Not yet implemented in `benchmark-reset-commands`; blocked on
  (a), since the reset's shape depends on the option chosen.

  **(c) rx_bytes promoted from "backstop" to a status.** `run --min-rx-bytes N`
  marks a trial `not-cold` if it received fewer than N network bytes (or the
  counter was unreadable). Set N to a conservative fraction of the closure's
  summed `NarSize`. Implemented and tested. Under the original design this
  would have turned every GIPS row red, which is the correct outcome.

  **(d) Compression is a confound, not a caveat.** gipsd advertises
  `Compression: none` (hard-coded); central serves lzip/zstd. On a starved CPU
  over a fast link, "uncompressed beats lzip" could produce a `faster` verdict
  that has nothing to do with peer-to-peer. The control that separates them is
  a third arm: plain `guix publish` on the hub, once with `-C none` and once
  with zstd. If GIPS matches `guix publish -C none`, the honest headline is
  about compression and topology, not IPFS. Planned as arm `publish`; not yet
  implemented (the harness's arm list is a constant, `%arms`).

  **(e) Sample size:** section 6 rewritten to a fixed n = 20 with no interim
  look.

  **(f) Known and accepted, now stated:** the verdict uses a percentile
  bootstrap, which under-covers slightly at small n (nominal 95% is nearer
  90-92% at n = 10; better at 20), and can disagree with the sign-flip p-value
  near the boundary. Both are reported; if they disagree, the write-up says so
  and the verdict is `no-detectable-difference`. `position` (which arm ran
  first) is recorded and will be reported as a covariate, because a burstable
  1/8-OCPU guest may favour whichever arm runs first in a block.

  **(g) Other preconditions found in source, to add to preflight when the arm
  design is settled:** narinfos served to guix are signed by the *consumer's
  own* gipsd key, so that key must be in the consumer's `/etc/guix/acl` (not
  only the hub's); an unconfigured key yields unsigned narinfos that guix
  rejects. And the mirror worker refuses more than 1000 pinned items per
  publisher, which bounds workload size.

  **(h) Correction to section 10 caveat 2.** It called a micro-measured speedup
  "plausibly a lower bound for faster machines". The reviewer's objection
  holds: a faster CPU shrinks central's decompression cost, so the advantage
  could just as well *shrink*. The direction is unknown. Caveat 2 is withdrawn
  as worded; what stands is only "the micro is CPU-starved, and we have not
  measured another shape".

  **(i) Not adopted, with reasons.** Replacing `guix gc` with `guix gc -D
  <closure>`: closure items that are live on the consumer (glibc, bash) make
  `-D` error, and whether it then deletes the rest is unverified. The
  underlying point is right, though -- live items are never fetched, so
  "closure size" overstates the work. `downloads_total` already records items
  actually substituted per trial; the results section must quote that, not the
  closure count.

- **Amendment 3, 2026-09-21, before any data -- user decision on 2(a):
  option 1 (time-to-available) first, option 2 (on-demand fetch in gipsd)
  later, reported as two separate claims.**

  **(a) What the `gips` arm now measures.** From a consumer with no
  subscription, no mirrored rows, no pins and a freshly started gipsd:
  `gips subscribe <name>` starts the clock; the harness polls the local gipsd
  until every item guix would actually fetch (closure minus what is already
  live in the consumer's store) has a narinfo; then `guix build <paths>` with
  the local gipsd as the only substitute URL. `wall_ms` is the whole span.
  The `central` arm is unchanged: one cold `guix build` from the central
  servers. Both answer the same user question -- "how long from wanting the
  package to having it" -- which is why they are comparable.

  **(b) Sub-phases are recorded, never subtracted.** `first_available_ms`
  (dominated by the mirror worker's 60 s tick: up to a minute of idling that is
  a property of GIPS as shipped), `available_ms`, `install_ms`. `report`
  prints their medians beside the total. A write-up may say "of which about N s
  is tick wait"; it may not quote a speedup with the wait removed.

  **(c) The reset is now identical for both arms**, which is stronger than
  before: `guix gc`; clear the narinfo cache; stop gipsd; delete its database
  (subscription + mirrored rows; keys and config are separate files); remove
  every recursive IPFS pin; `ipfs repo gc`; restart gipsd and wait for
  `/status`; drop the page cache. This also resolves 2(b) (the restart empties
  the signature cache) and guarantees no mirror is still pulling data while a
  central trial is timed. New status `mirror-timeout` (default 3600 s).

  **(d) A cost GIPS pays that central does not, left in on purpose.** The
  mirror worker pulls the publisher's *whole feed*, including items the
  consumer already has (glibc, bash); guix fetches only what is missing. The
  clock stops when the needed items are available, but the extra transfer
  competes for the same link meanwhile and shows up in `rx_bytes`. That is how
  the shipped system behaves, so it is measured, not engineered away.

  **(e) New blocker found while implementing this -- discovery may never have
  worked between two machines.** A consumer finds a hub's feed only through
  GNS, and `gips-gns` shells out to `gns_command` (default `gnunet-gns`).
  Read from `gips/components/gips-gns/src/lib.rs`: publishing runs
  `gnunet-gns record -n -- NAME -t TYPE -a -- VALUE`. *From memory, unverified
  against a GNUnet install:* `gnunet-gns` is a lookup tool with no `record`
  subcommand; records are written with `gnunet-namestore`. A source comment
  calls the resolve parsing "MVP". GNUnet is not in `gips/manifest.scm`, is not
  installed on `minius-02`, and `docs/GIPS_MULTI_MACHINE_SYNC.md` never
  mentions it. If this reading is right, hub -> spoke sync has never run end to
  end, and G1.2 includes making it run: a working GNUnet peer with a shared
  zone on both nodes, or a different `gns_command` (it is configurable). This
  is a GIPS design question for the user, not something the benchmark can
  paper over. Cheapest check: on any machine with GNUnet, run the exact
  command above and read the error.

  **Verified 2026-09-21 on `guix-oracle-minius-02`, GNUnet 0.27.0 from Guix:**
  `gnunet-gns --help` lists only lookup options (`-u`, `-t`, `-r`, `-T`, ...),
  and the exact publish invocation GIPS uses fails with
  `gnunet-gns: invalid option -- n`, exit 1. Records are written with
  `gnunet-namestore -a`. So publishing a feed to GNS has never worked against
  real GNUnet, and therefore neither has hub -> spoke sync. The *resolve*
  invocation (`-t TYPE -u NAME`) does match the real tool. Also found: the
  Guix package (`gips/guix.scm`) has `#:cargo-inputs ()` with a note that an
  offline build needs every `rust-*` crate listed, so `guix build -f` cannot
  succeed in the build sandbox for the 315-crate workspace; gipsd has to be
  built with plain `cargo` inside `guix shell` (network on).

  **(f) Option 2 stays planned** as a second `gips` arm variant
  (`gips-ondemand`) once gipsd can resolve through subscriptions without
  pinning. Section 3's original text describes that arm and is kept for it.

- **Amendment 4, 2026-09-21, before any data -- user decision: run the
  compression controls.** Implements 2(d).

  **(a) Two control arms**, both plain `guix publish` on the *hub* -- same
  machine, same link, same closure as the GIPS hub, no IPFS anywhere:
  `publish-none` (`-C none`, what gipsd serves) and `publish-zstd` (compressed,
  like the central servers). Enabled with `run --publish-none-url URL
  --publish-zstd-url URL`; a block is then four trials in seeded random order.
  They get the identical reset and the same provenance, rx-floor and
  cold-store checks as every other arm.

  **(b) One primary comparison, three explanatory ones, fixed now:**

  | Role | Baseline vs treatment | Holds constant | Isolates |
  |---|---|---|---|
  | **primary** | `central` vs `gips` | consumer, closure | the user-facing question; the only verdict that may be a headline |
  | explanatory | `publish-none` vs `gips` | hub, link, no compression | IPFS + mirror design itself |
  | explanatory | `publish-zstd` vs `publish-none` | hub, link, protocol | compression, on this CPU |
  | explanatory | `central` vs `publish-zstd` | protocol, compression | topology (near vs far) |

  Four arms must not become four chances at a significant result, so the
  explanatory comparisons are printed with a *direction*, not a verdict, and
  exist to explain the primary. The write-up rule that follows: **if `gips`
  does not beat `publish-none`, a `faster` primary verdict is attributed to
  topology and/or compression, in those words, and not to peer-to-peer.**
  Conversely, if `gips` loses to `publish-none` by about the mirror tick, say
  that too -- it points at the 60 s interval, which is a tunable, not at IPFS.

  **(c) Cost.** 4 arms x 20 blocks x 2 workloads = 160 trials, each with a full
  reset. On a 1/8-OCPU guest expect this to take days, not hours; the pilot
  (G1.4) exists to turn that guess into a number before committing.

  **(d) Boundaries not yet crossed for these arms:** the hub's
  `/etc/guix/signing-key.pub` (what `guix publish` signs with -- *not* the
  gipsd key) must be in the consumer's ACL; the OCI security list and the
  guest firewall must admit the two ports from the consumer's private address;
  use the hub's **private** VCN address so the control arms and IPFS travel
  the same kind of path -- and record which path IPFS actually took
  (`ipfs swarm peers` shows the address), because if libp2p dials the hub's
  *public* address while `guix publish` uses the private one, the topology is
  no longer held constant and the explanatory rows say less than they appear
  to. `guix publish -C zstd` compresses on the fly by default, putting
  compression CPU on the *hub's* 1/8 OCPU; start it with `--cache` and warm the
  cache (one untimed fetch) before trials, as the central servers effectively
  are.

## 10. What we can and cannot claim

Written before the data so that the wording cannot drift toward whatever the
numbers turn out to flatter. Each claim is licensed by a specific
configuration; a claim whose configuration was not run is not made.

**Configuration A (first run):** two `VM.Standard.E2.1.Micro` guests in the
same Ashburn availability domain and VCN (the account's two existing micros,
`guix-oracle-minius-02` and `guix-oracle-z5-02`, are both in AD-1; which is
hub and which is consumer is not yet chosen), one hub holding the full closure, one
consumer, central arm = `ci.guix.gnu.org` + `bordeaux.guix.gnu.org`.

| If A shows | We may say | We may NOT say |
|---|---|---|
| `faster` | "With one peer in the same cloud region already holding the closure, going from *subscribed to nothing* to *installed* through GIPS (mirror wait included) was N.Nx faster (95% CI a-b) than from the central servers, on a 1/8-OCPU x86_64 VM, for these two workloads." | "GIPS is faster than Guix substitutes." "GIPS speeds up installs." Anything about NAT-ed, home, or cross-region peers. Anything about swarms -- one peer is not a swarm. |
| `no-detectable-difference` | "We could not measure a difference at n pairs; an effect smaller than the interval width may exist." | "GIPS is as fast as the central servers" (absence of evidence), or "GIPS has no overhead". |
| `slower` | The same sentence as `faster` with the ratio inverted. It gets published with the same prominence. | That the result is an artefact, unless a specific artefact is demonstrated. |

**Attribution rule (amendment 4(b)):** the sentence above names *what was
measured*. Any sentence about *why* must cite the explanatory comparisons, and
"because it is peer-to-peer" requires `gips` to beat `publish-none`.

**Standing caveats that go in every write-up, whatever the verdict:**

1. *Cold-to-cold only.* The central servers are fronted by caches and are warm
   for popular items; the hub is warm by construction. We compare what a user
   experiences, not the two systems at equal advantage.
2. *The micro is CPU-starved.* (**Last sentence withdrawn -- amendment 2(h):
   the direction of the effect on faster machines is unknown.**) At 1/8 OCPU, decompression and store
   registration may dominate both arms and compress any network difference
   toward 1. A speedup measured here is plausibly a lower bound for faster
   machines, but that is a conjecture until a second shape is run.
3. *Byte counts differ by design, and this is a confound, not only a caveat
   -- amendment 2(d) plans a `guix publish` control arm.* Central nars are compressed; whatever gipsd
   serves may not be. `median_rx_MB` is reported beside every timing so a
   reader can see whether GIPS won on fewer bytes, or despite more.
4. *Availability is not speed.* GIPS's main pitch for personal sync -- a
   locally *built* package that no central server has -- is a case where the
   central arm's time is "compile it", not a download. This benchmark
   deliberately excludes it (preflight requires both arms to have the item).
   It is a real advantage and a different experiment; we do not smuggle it in.
5. *n is small and from one week, one region, one account.* The interval
   covers trial-to-trial noise, not day-to-day or region-to-region variation.

**Configuration B (G1.6)** exists to find where A's result stops holding:
either a hub outside the region / behind NAT, or 3+ peers. Until B is run, the
write-up carries the sentence "we have not tested distant or NAT-ed peers".

**Who ran it.** The author of GIPS ran the benchmark of GIPS. The mitigation is
that the protocol, seed, raw rows and raw guix logs are all published, the
analysis is deterministic, and failed trials cannot be dropped. Say so; do not
claim independence.

## 11. Deferred: recommendations for Goal 2 (local models)

**Decision deferred until Goal 1 is complete** (user, 2026-09-20). These are
recommendations recorded so the reasoning is not lost, not commitments, and
none of it has been verified on a live machine.

1. **Shape: `VM.Standard.A1.Flex`, not the micro.** 1 GiB RAM cannot hold a
   useful model plus a Guix system; A1.Flex is Always Free up to 4 OCPU /
   24 GiB, which fits a 7-8B model at 4-bit quantization with room to spare.
   It draws on a separate capacity pool from the micros, so Goal 1's two
   instances can stay up beside it.
2. **The aarch64 image is the long pole.** No aarch64 Oracle image exists.
   Options, best first: build natively on an aarch64 Guix host; build on the
   x86_64 Guix machine through `qemu-binfmt` (works, slow -- hours); offload to
   a temporary aarch64 builder. `04-deploy.scm` also needs `--shape-config`
   (OCPUs + memory) for a flex shape, which a fixed shape does not take. A1
   capacity in Ashburn is frequently exhausted; the existing capacity-retry
   handling should carry over but has never been exercised on A1.
3. **Check packaging before promising ollama.** Whether `ollama` is in Guix at
   the pinned commit, and whether it or `llama-cpp` has aarch64 substitutes, is
   unverified. `llama-cpp` is the likelier fit: packaged, CPU-only is its
   normal mode, and a from-source build on 4 Ampere cores is tolerable. If
   ollama is wanted specifically and is unpackaged, it becomes a packaging task
   or a `guix shell --container --emulate-fhs` of the upstream binary -- decide
   then, not now.
4. **CPU inference expectations.** Ampere A1 has no GPU. Expect single-digit to
   low-double-digit tokens/s on a 7-8B Q4 model. Fine for batch and tool use,
   poor for interactive chat. Set that expectation in the docs before anyone
   is disappointed by it.
5. **Tie back to GIPS.** A model runtime plus weights is the workload where
   peer-to-peer distribution should matter most (GiB, not MiB). Model weights
   are not store items by default; if they are packaged as fixed-output
   derivations they become substitutable and therefore a `large` benchmark
   workload and a natural GIPS demo -- *on aarch64, which is a separate
   configuration from A and needs its own hub*.
6. **What Goal 1 should leave behind for Goal 2:** nothing shape-specific in
   `gips-benchmark.scm` (true today), and hub/consumer bring-up written as
   steps that do not assume x86_64.

## What `run` does to the machine it runs on

The plan of record uses two existing, in-use guests rather than fresh
disposable ones, so this matters. Before **every** trial (2 per block, so 80
times for the full `small` + `medium` run) `run` executes, machine-wide:

| Step | Destroys | Does not touch |
|---|---|---|
| `guix gc` | every unrooted store item: `guix shell` / `guix build` results, cached `guix pull` derivations, anything not in a profile | profile and system generations (they are GC roots), so `guix package --roll-back` and `guix system roll-back` still work |
| clear `/var/guix/substitute/cache` | cached narinfo lookups | nothing durable; refilled on next use |
| `ipfs repo gc` (gips trials) | every **unpinned** IPFS block, including anything you `ipfs add`ed without pinning | pinned content |
| `drop_caches` | nothing | -- |

**Putting it back.** There is nothing to roll back for installed software.
What is lost is cache: the next `guix shell` re-downloads, and the next
`guix pull` or `reconfigure` is slower once. Unpinned IPFS content you cared
about is gone for good -- `ipfs pin add` it *before* the run. Whether gipsd
itself relies on unpinned blocks on the consumer is boundary 3 in section 8.

**Guards, in code rather than in comments:**

- `run` requires `--consumer-host NAME` and refuses unless it equals the
  machine's hostname, so a command pasted into the wrong terminal fails there.
  **Weakness found 2026-09-21:** the generic Oracle image names every guest
  `guix-oracle`, so on the two benchmark machines this check cannot tell hub
  from consumer. It still stops a laptop or the controller. Convention
  adopted: hostname = OCI display name. `minius-02` was renamed transiently on
  2026-09-21; **a reboot silently undoes it**, so check `hostname` on both
  guests at the start of every run until the image sets it from metadata.
- `hub-prepare` leaves `/var/tmp/gips-benchmark-hub`; `run` refuses on any
  machine that has it. Collecting garbage on the hub deletes what it serves.
- `--yes` skips the question, never those two checks.
- A reset step that fails, or less than `--min-free-mib` (default 3072) free on
  `/gnu/store`, aborts **without recording a row**, so the trial is retried on
  resume instead of being stored as a half-cold measurement.

**Not guarded, so watch for it:** memory and traffic. `guix-daemon`, kubo and
gipsd together on a 1 GiB micro may be killed by the OOM killer mid-trial (it
would surface as a `failed` row; check `dmesg`). And 80 cold re-downloads of a
few hundred MiB is several GiB of ingress plus sustained libp2p traffic from an
Always Free account -- well inside the 10 TB/month egress allowance, but run
the 2-block pilot (G1.4) first and look at the traffic before committing to
the full run.

## Running it

Requires a hub and a consumer that are already GIPS peers: the hub's signing
key authorized on the consumer, the consumer's *own* gipsd key authorized too
(amendment 2(g)), and the consumer **subscribed** to the hub's GNS name: [GIPS_MULTI_MACHINE_SYNC.md](GIPS_MULTI_MACHINE_SYNC.md)
(`make gips-hub` on one, `make gips-spoke` on the other). That bring-up has not
yet been exercised between two live cloud nodes -- it is task G1.2 in
`CHECKLIST.md`.

```sh
# Hub (has the packages; never run `run' here -- it would gc what it serves)
guile --no-auto-compile -s oracle/scripts/gips-benchmark.scm hub-prepare \
  --manifest oracle/benchmark/workload-medium.scm --out-dir /tmp/wl-medium \
  --publish --gns-name bench.gnu

# Hub, for the control arms (amendment 4): two plain `guix publish` servers.
# Unverified on these guests -- see 4(d) for ACL, firewall and cache warming.
sudo guix publish --port=8081 -C none &
sudo guix publish --port=8082 -C zstd --cache=/var/cache/guix/publish &

# Consumer (disposable)
guile --no-auto-compile -s oracle/scripts/gips-benchmark.scm preflight \
  --closure wl-medium/workload.closure
guile --no-auto-compile -s oracle/scripts/gips-benchmark.scm run \
  --paths wl-medium/workload.paths --closure wl-medium/workload.closure \
  --workload medium --gns-name bench.gnu \
  --gipsd-database ~/.config/gips/gipsd.sqlite \
  --publish-none-url http://HUB_PRIVATE_IP:8081 \
  --publish-zstd-url http://HUB_PRIVATE_IP:8082 \
  --consumer-host "$(hostname)" \
  --blocks 20 --seed 20260920 --out results-medium.tsv --yes

# Anywhere with Guile (including the macOS controller)
make gips-benchmark-report RESULTS=results-medium.tsv
```
