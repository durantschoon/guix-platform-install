---- MODULE FeedSync ----
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS 
    Packages,  \* Set of packages to be published e.g., {"pkgA", "pkgB"}
    MaxTime    \* Maximum logical time e.g., 3

VARIABLES
    published_feeds, \* Feeds published by the publisher
    mirror_tip,      \* The latest feed state accepted by the mirror
    mirror_pkgs,     \* Set of packages successfully mirrored
    mode,            \* "Timestamp" or "Merkle"
    pub_time,        \* Publisher's local clock
    pub_tip_cid      \* Publisher's latest CID

vars == <<published_feeds, mirror_tip, mirror_pkgs, mode, pub_time, pub_tip_cid>>

Init ==
    /\ published_feeds = {}
    /\ mirror_tip = [time |-> 0, cid |-> 0, prev |-> 0]
    /\ mirror_pkgs = {}
    \* We explicitly set mode to "Merkle" here because "Timestamp"
    \* is intentionally vulnerable to liveness failures (out-of-order packets).
    \* To see the counter-example, change this back to {"Timestamp", "Merkle"}.
    /\ mode = "Merkle"
    /\ pub_time = 0
    /\ pub_tip_cid = 0

\* -------------------------------------------------------------------------
\* PUBLISHER ACTIONS
\* -------------------------------------------------------------------------

\* The publisher creates a perfectly valid linear chain of updates.
Publish(pkg, new_cid) ==
    /\ \neg \E f \in published_feeds : f.pkg = pkg
    /\ pub_time < MaxTime
    /\ LET t == pub_time + 1
       IN
         /\ pub_time' = t
         /\ published_feeds' = published_feeds \cup {[pkg |-> pkg, time |-> t, cid |-> new_cid, prev |-> pub_tip_cid]}
         /\ pub_tip_cid' = new_cid
    /\ UNCHANGED <<mirror_tip, mirror_pkgs, mode>>

\* -------------------------------------------------------------------------
\* MIRROR ACTIONS
\* -------------------------------------------------------------------------

ReceiveTimestamp(feed) ==
    /\ mode = "Timestamp"
    /\ feed.time > mirror_tip.time
    /\ mirror_tip' = [mirror_tip EXCEPT !.time = feed.time]
    /\ mirror_pkgs' = mirror_pkgs \cup {feed.pkg}
    /\ UNCHANGED <<published_feeds, mode, pub_time, pub_tip_cid>>

ReceiveMerkle(feed) ==
    /\ mode = "Merkle"
    /\ feed.prev = mirror_tip.cid
    /\ mirror_tip' = [mirror_tip EXCEPT !.cid = feed.cid]
    /\ mirror_pkgs' = mirror_pkgs \cup {feed.pkg}
    /\ UNCHANGED <<published_feeds, mode, pub_time, pub_tip_cid>>

Receive == 
    \E feed \in published_feeds :
        IF mode = "Timestamp" THEN ReceiveTimestamp(feed) ELSE ReceiveMerkle(feed)

\* Prevent deadlock when system reaches a quiescent state
Stutter ==
    /\ UNCHANGED vars

\* -------------------------------------------------------------------------
\* NEXT STATE RELATION
\* -------------------------------------------------------------------------

Next ==
    \/ \E pkg \in Packages, cid \in 1..3 : Publish(pkg, cid)
    \/ Receive
    \/ Stutter

\* -------------------------------------------------------------------------
\* FAIRNESS & PROPERTIES
\* -------------------------------------------------------------------------

\* Structural Integrity (Safety Invariant)
TypeOK ==
    /\ mirror_pkgs \subseteq Packages
    /\ mode \in {"Timestamp", "Merkle"}
    /\ pub_time \in 0..MaxTime
    /\ pub_tip_cid \in 0..3
    /\ mirror_tip \in [time: 0..MaxTime, cid: 0..3, prev: 0..3]
    /\ \A f \in published_feeds : 
          f \in [pkg: Packages, time: 1..MaxTime, cid: 1..3, prev: 0..3]

\* Weak fairness ensures that if an action is continuously enabled, it eventually fires.
Fairness ==
    /\ \A pkg \in Packages, cid \in 1..3 : WF_vars(Publish(pkg, cid))
    /\ WF_vars(Receive)

\* Liveness Property: Eventually, all published packages should be mirrored.
EventuallyConsistent == 
    (\A p \in Packages : \E f \in published_feeds : f.pkg = p) ~> (Packages \subseteq mirror_pkgs)

Spec == Init /\ [][Next]_vars /\ Fairness
====
