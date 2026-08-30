# Replay Protection: Timestamps vs. Merkle DAGs

## 1. The Distributed Synchronization Problem

When someone publishes updates to their software, those updates need to be sent out in the correct order. If a publisher uses multiple computers to build and publish updates at the same time, the clocks on those computers might be slightly off. If a mirror server downloading these updates strictly only accepts "newer" times, a perfectly good update might arrive late due to network lag and get rejected forever because the mirror server thinks it's old news.

In a distributed system, relying on monotonic `timestamp` fields for replay and rollback protection introduces race conditions due to clock skew and network propagation delays. If a `Publisher` utilizes multiple concurrent build nodes, out-of-order IPFS delivery can cause a valid `Feed` message to be permanently rejected by a `Mirror` whose `mirror_tip.time` has already advanced past the delayed feed's timestamp, breaking eventual consistency.

## 2. Modeling the Timestamp Failure

We can write a mathematical blueprint to prove this failure happens. In our blueprint, if Update A is made at 1:00 PM and Update B is made at 1:05 PM, but the mirror server sees B before A, it updates its clock to 1:05 PM. When Update A finally arrives, the server sees 1:00 PM and throws it away, leaving the system permanently missing Update A.

The `ReceiveTimestamp(feed)` action in the TLA+ model requires `feed.time > mirror_tip.time`. An interleaving where `Publish(pkgB, 5)` is followed by `ReceiveTimestamp(pkgB)` advances `mirror_tip.time` to `5`. A subsequent `ReceiveTimestamp(pkgA)` where `pkgA.time = 4` is disabled because `4 > 5` evaluates to `FALSE`. The liveness property `<> (mirror_pkgs = {pkgA, pkgB})` is violated, demonstrating a permanent state divergence and dropped updates.

## 3. The Merkle DAG Solution

The fix is to stop looking at clocks and start chaining the updates together like links in a chain. Each new update firmly points to the exact update that came right before it. The server will only accept an update if it correctly snaps into the current end of the chain, guaranteeing perfect order no matter how long the network takes to deliver it.

We replace the monotonic timestamp constraint with a Merkle DAG structure via a `previous_cid` pointer. In the TLA+ model, the `ReceiveMerkle(feed)` action requires `feed.prev = mirror_tip.cid`. This imposes a strict topological ordering (causality) on state transitions. Concurrent builds must branch or serialize explicitly, and the `Mirror` traverses the DAG by matching `prev_cid` edges, completely eliminating clock-skew vulnerabilities and satisfying the liveness property under arbitrary network delays.
