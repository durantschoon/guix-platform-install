(use-modules (guix packages)
             (guix gexp)
             (guix build-system cargo)
             ((guix licenses) #:prefix license:)
             (gnu packages sqlite)
             (gnu packages guile)
             (gnu packages gnunet)
             (gnu packages gnupg)
             (gnu packages pkg-config)
             (gnu packages rust-apps))

(define (gips-source-select? file stat)
  (let ((base (basename file)))
    (not (or (string-prefix? "." base) ; Excludes .git, .agents, .tools, .gitignore
             (string-suffix? ".pem" base)
             (string-suffix? ".key" base)
             (string=? base "gipsd.toml")
             (string=? base "manifest.json")
             (string=? base "states"))))) ; Exclude test states

(package
  (name "gips")
  (version "0.1.0")
  (source (local-file "." "gips-checkout" 
                      #:recursive? #t
                      #:select? gips-source-select?))
  (build-system cargo-build-system)
  (arguments
   `(#:cargo-inputs () ;; NOTE: A full offline Guix build requires all rust-* packages listed here
     #:tests? #f))
  (native-inputs
   (list pkg-config
         just))
  (inputs
   (list sqlite
         gnunet
         guile-3.0
         guile-json-4
         ;; `(gcrypt pk-crypto)`, used by the committed narinfo-signing helpers
         ;; in components/gips-trust/guile/. `gipsd` shells `guile` out to them
         ;; whenever `[guix_signing]` is configured, so without this a
         ;; Guix-deployed daemon can serve narinfos but cannot sign them --
         ;; every signing attempt would fail on an unbound module at run time,
         ;; which is a 500 per narinfo rather than a build error.
         ;; From (gnu packages gnupg), which is also where `guix publish` and
         ;; `guix archive` get it.
         guile-gcrypt))
  (synopsis "GNS + IPFS Package Substitutes")
  (description
   "GIPS provides a peer-to-peer alternative to traditional Guix substitute
servers by replacing centralized HTTP build farms with an IPFS swarm and GNS.")
  (home-page "https://radicle.network")
  (license license:gpl3+))
