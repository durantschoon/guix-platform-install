;;; workload-medium.scm --- GIPS benchmark workload: a realistic install.
;;;
;;; Roughly what a person pulls onto a fresh machine in one sitting: dominated
;;; by nar throughput, with enough items that lookup latency still shows.
;;; See docs/GIPS_BENCHMARK_PROTOCOL.md.

(specifications->manifest
 '("emacs-minimal" "git" "python"))
