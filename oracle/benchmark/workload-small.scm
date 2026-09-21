;;; workload-small.scm --- GIPS benchmark workload: a handful of small items.
;;;
;;; Dominated by per-item latency (narinfo lookups, connection setup) rather
;;; than throughput.  See docs/GIPS_BENCHMARK_PROTOCOL.md.

(specifications->manifest
 '("hello" "sed" "grep" "which"))
