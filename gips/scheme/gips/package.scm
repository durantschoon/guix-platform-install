;;; GNU Guix Package Definition for GIPS
;;;
;;; Defines `<gips-package>` record and `gips-package` definition for
;;; building GIPS with GNU Guix.

(define-module (gips package)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:export (<gips-package>
            gips-package
            gips-package?
            gips-package-name
            gips-package-version
            gips-package-synopsis
            gips-package-description
            gips-package-home-page
            gips-package-license
            gips-package-build-system
            gips-package-dependencies
            gips-package->manifest-entry))

(define-record-type <gips-package>
  (%make-gips-package name version synopsis description home-page license build-system dependencies)
  gips-package?
  (name         gips-package-name)
  (version      gips-package-version)
  (synopsis     gips-package-synopsis)
  (description  gips-package-description)
  (home-page    gips-package-home-page)
  (license      gips-package-license)
  (build-system gips-package-build-system)
  (dependencies gips-package-dependencies))

(define* (gips-package #:key
                       (name "gips")
                       (version "0.1.0")
                       (synopsis "Guix IPFS Substitute Daemon and Peer-to-Peer Mirror Fabric")
                       (description "GIPS provides peer-to-peer distribution of GNU Guix substitutes over IPFS and GNUnet. It features transitive web-of-trust capability vouches, objective mathematical fraud proofs, privacy-preserving k-anonymity queries, offline snapshot tarball bundles, and direct UnixFS directory tree publishing.")
                       (home-page "https://github.com/ds/GIPS")
                       (license "GPL-3.0-or-later")
                       (build-system "cargo-build-system")
                       (dependencies '("openssl" "sqlite" "pkg-config")))
  (%make-gips-package name version synopsis description home-page license build-system dependencies))

(define (gips-package->manifest-entry pkg)
  "Convert a <gips-package> record to a declarative manifest entry specification."
  `((name ,(gips-package-name pkg))
    (version ,(gips-package-version pkg))
    (synopsis ,(gips-package-synopsis pkg))
    (home-page ,(gips-package-home-page pkg))
    (license ,(gips-package-license pkg))))
