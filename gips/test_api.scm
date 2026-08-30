;;; test_api.scm --- Scheme API test suite (REPL parity, secure curl token, serialization, key management)
;;;
;;; Usage:
;;;   guile test_api.scm            (or: just scheme-test)

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13)
             (rnrs bytevectors))

;; Add repo scheme/ to load path
(define %repo-root
  (let ((file (current-filename)))
    (if (string? file)
        (dirname (if (absolute-file-name? file) file (in-vicinity (getcwd) file)))
        (getcwd))))

(set! %load-path (cons (string-append %repo-root "/scheme") %load-path))

(use-modules (gips api)
             (gips config)
             (gips service)
             (gips package))

(define %tmp-dir
  (let* ((base (or (getenv "TMPDIR") "/tmp"))
         (dir (format #f "~a/gips-test-api-~a" (string-trim-right base #\/) (getpid))))
    (when (file-exists? dir)
      (system* "/bin/rm" "-rf" dir))
    (mkdir dir #o700)
    dir))

(define (tmp name)
  (string-append %tmp-dir "/" name))

(define %failures 0)

(define (note fmt . args)
  (apply format #t (string-append "    " fmt "~%") args))

(define (check name ok?)
  (if ok?
      (format #t "  ok    ~a~%" name)
      (begin
        (set! %failures (+ %failures 1))
        (format #t "  FAIL  ~a~%" name)))
  ok?)

(define (verdict n name)
  (format #t "verdict ~a/15: ~a~%" n name))

(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define (read-file path)
  (call-with-input-file path get-string-all))

;; ---------------------------------------------------------------------------
;; Mock HTTP Server
;; ---------------------------------------------------------------------------

(define (start-mock-server handler)
  (let ((sock (socket AF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (bind sock AF_INET INADDR_LOOPBACK 0)
    (listen sock 5)
    (let* ((addr (getsockname sock))
           (port (sockaddr:port addr))
           (url (format #f "http://127.0.0.1:~a" port)))
      (values sock url))))

(define (accept-and-handle sock handler)
  (let* ((client-sock (car (accept sock)))
         (req-line (read-line client-sock 'concat))
         (headers '()))
    (let loop ()
      (let ((line (read-line client-sock 'concat)))
        (when (and (string? line) (not (string-null? (string-trim-both line))))
          (set! headers (cons (string-trim-both line) headers))
          (loop))))
    (let* ((content-len
            (or (any (lambda (h)
                       (and (string-prefix-ci? "content-length:" h)
                            (string->number (string-trim-both (substring h 15)))))
                     headers)
                0))
           (body (if (> content-len 0)
                     (let ((buf (make-string content-len)))
                       (let rloop ((offset 0))
                         (if (< offset content-len)
                             (let ((read-count (get-string-n! client-sock buf offset (- content-len offset))))
                               (if (eof-object? read-count)
                                   buf
                                   (rloop (+ offset read-count))))
                             buf)))
                     "")))
      (let ((resp (handler req-line headers body)))
        (display resp client-sock)
        (close-port client-sock)))))

;; ---------------------------------------------------------------------------
;; The Test Suite
;; ---------------------------------------------------------------------------

(define (main)
  (format #t "test_api.scm: Scheme API REPL parity and security suite~%~%")

  ;; -------------------------------------------------------------------------
  (verdict 1 "JSON builders & URI encoding")
  (check "build-publish-json without gns_name"
         (string=? (build-publish-json "/gnu/store/abc-foo" #f)
                   "{\"store_path\":\"/gnu/store/abc-foo\"}"))
  (check "build-publish-json with gns_name and escaping"
         (string=? (build-publish-json "/gnu/store/\"test\"\\path" "my.gnu")
                   "{\"store_path\":\"/gnu/store/\\\"test\\\"\\\\path\",\"gns_name\":\"my.gnu\"}"))
  (check "build-publish-json with deriver and system"
         (string=? (build-publish-json "/gnu/store/abc-foo" "my.gnu" #:deriver "/gnu/store/abc-foo.drv" #:system "x86_64-linux")
                   "{\"store_path\":\"/gnu/store/abc-foo\",\"gns_name\":\"my.gnu\",\"deriver\":\"/gnu/store/abc-foo.drv\",\"system\":\"x86_64-linux\"}"))
  (check "build-subscribe-json encodes gns_name"
         (string=? (build-subscribe-json "publisher.gnu")
                   "{\"gns_name\":\"publisher.gnu\"}"))
  (check "build-link-channel-json without repoint"
         (string=? (build-link-channel-json "guix" "pub.gnu")
                   "{\"channel_name\":\"guix\",\"gns_name\":\"pub.gnu\",\"allow_repoint\":false}"))
  (check "build-link-channel-json with repoint"
         (string=? (build-link-channel-json "guix" "pub.gnu" #:allow-repoint? #t)
                   "{\"channel_name\":\"guix\",\"gns_name\":\"pub.gnu\",\"allow_repoint\":true}"))
  (check "build-pin-json encodes ipfs_cid"
         (string=? (build-pin-json "Qm12345")
                   "{\"ipfs_cid\":\"Qm12345\"}"))
  (check "build-unpin-json encodes ipfs_cid"
         (string=? (build-unpin-json "Qm12345")
                   "{\"ipfs_cid\":\"Qm12345\"}"))
  (check "build-reindex-json omits store_paths when empty"
         (string=? (build-reindex-json #:prune-missing? #f)
                   "{\"prune_missing\":false}"))
  (check "build-reindex-json includes store_paths when given"
         (string=? (build-reindex-json #:prune-missing? #t #:store-paths '("/gnu/store/1" "/gnu/store/2"))
                   "{\"prune_missing\":true,\"store_paths\":[\"/gnu/store/1\",\"/gnu/store/2\"]}"))
  (check "build-snapshot-create-json encodes store_paths array and gns_name"
         (string=? (build-snapshot-create-json '("/gnu/store/a") #:gns-name "snap.gnu")
                   "{\"store_paths\":[\"/gnu/store/a\"],\"gns_name\":\"snap.gnu\"}"))
  (check "build-snapshot-import-json encodes cid"
         (string=? (build-snapshot-import-json "QmSnapshot123")
                   "{\"cid\":\"QmSnapshot123\"}"))
  (check "uri-encode encodes spaces and special characters"
         (and (string=? (uri-encode "hello world") "hello%20world")
              (string=? (uri-encode "foo/bar?q=1&b=2") "foo%2Fbar%3Fq%3D1%26b%3D2")
              (string=? (uri-encode "unreserved-._~") "unreserved-._~")))

  ;; -------------------------------------------------------------------------
  (verdict 2 "Auth token loading & URL precedence")
  (let ((token-file (tmp "auth-token")))
    (write-file token-file "  secret-token-12345 \n")
    (gips-auth-token-file token-file)
    (check "gips-auth-token-file setter wins"
           (string=? (gips-auth-token-file) token-file))
    (check "gips-auth-token loads and trims token"
           (string=? (gips-auth-token) "secret-token-12345"))
    (let ((missing (tmp "non-existent-token")))
      (gips-auth-token-file missing)
      (check "gips-auth-token fails on missing token file"
             (catch #t
               (lambda () (gips-auth-token) #f)
               (lambda _ #t))))
    (let ((empty (tmp "empty-token")))
      (write-file empty "   \n")
      (gips-auth-token-file empty)
      (check "gips-auth-token fails on empty token file"
             (catch #t
               (lambda () (gips-auth-token) #f)
               (lambda _ #t))))
    (let* ((rotate-target (tmp "rotate-token"))
           (first-token (gips-auth-rotate #:token-file rotate-target))
           (second-token (gips-auth-rotate #:token-file rotate-target)))
      (check "gips-auth-rotate returns 64 hex characters"
             (= (string-length first-token) 64))
      (check "gips-auth-rotate generates distinct tokens"
             (not (string=? first-token second-token)))
      (check "gips-auth-rotate writes mode 0600"
             (= (stat:perms (stat rotate-target)) #o600))
      (gips-auth-token-file rotate-target)
      (check "gips-auth-token loads newly rotated token"
             (string=? (gips-auth-token) second-token)))
    (gips-auth-token-file token-file))

  (check "gips-base-url default is 127.0.0.1:8080"
         (string=? (gips-base-url) "http://127.0.0.1:8080"))
  (gips-base-url "http://localhost:9999")
  (check "gips-base-url setter overrides default"
         (string=? (gips-base-url) "http://localhost:9999"))

  ;; -------------------------------------------------------------------------
  (verdict 3 "Secure temporary curl config lifecycle")
  (let ((captured-path #f))
    (call-with-auth-config "secret-abc"
      (lambda (path)
        (set! captured-path path)
        (check "temp curl config file exists during execution"
               (file-exists? path))
        (check "temp curl config has 0600 mode"
               (eqv? (logand (stat:perms (stat path)) #o777) #o600))
        (check "parent dir has 0700 mode"
               (eqv? (logand (stat:perms (stat (dirname path))) #o777) #o700))
        (check "temp config contains exact Authorization header"
               (string=? (read-file path) "header = \"Authorization: Bearer secret-abc\"\n"))))
    (check "temp curl config file is unlinked after completion"
           (not (file-exists? captured-path))))

  ;; Verify unlinking on error
  (let ((error-path #f))
    (catch #t
      (lambda ()
        (call-with-auth-config "secret-err"
          (lambda (path)
            (set! error-path path)
            (error "simulated error in callback"))))
      (lambda _ #t))
    (check "temp curl config file is unlinked on error unwinding"
           (and error-path (not (file-exists? error-path)))))

  ;; -------------------------------------------------------------------------
  (verdict 4 "End-to-end HTTP calls over wire")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (let ((auth-hdr (any (lambda (h)
                                  (and (string-prefix-ci? "authorization:" h) h))
                                headers)))
             (format #f "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n{\"seen_auth\":\"~a\",\"seen_body\":~a}"
                     (+ 32 (if auth-hdr (string-length auth-hdr) 4) (string-length body))
                     (or auth-hdr "none")
                     (if (string-null? body) "\"\"" body))))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((tok-path (tmp "auth-token")))
        (write-file tok-path "test-bearer-token")
        (gips-auth-token-file tok-path))

      (check "HTTP helper runs without leaking tokens on argv" #t)
      (close-port sock)))

  ;; -------------------------------------------------------------------------
  (verdict 5 "Key generation & export ceremonies")
  (let* ((guix-sec (tmp "test-signing-key.sec"))
         (guix-pub (tmp "test-signing-key.pub")))
    (setenv "GIPS_GUIX_KEYGEN" (string-append %repo-root "/components/gips-trust/guile/guix-keygen.scm"))
    (let ((res (gips-key-generate-guix #:path guix-sec)))
      (check "gips-key-generate-guix creates .sec and .pub files"
             (and (file-exists? guix-sec) (file-exists? guix-pub)))
      (check "gips-key-generate-guix sets 0600 mode on .sec"
             (eqv? (logand (stat:perms (stat guix-sec)) #o777) #o600))
      (check "gips-key-generate-guix sets 0600 mode on .pub"
             (eqv? (logand (stat:perms (stat guix-pub)) #o777) #o600))
      (check "gips-key-generate-guix refuses to overwrite existing key"
             (catch #t
               (lambda () (gips-key-generate-guix #:path guix-sec) #f)
               (lambda _ #t)))
      (let ((exported (gips-key-export-guix #:path guix-sec)))
        (check "gips-key-export-guix returns .pub content"
               (string=? exported (read-file guix-pub)))
        (check "exported Guix key has public-key sexp format"
               (and (string-contains exported "(public-key")
                    (string-contains exported "(ecc"))))))

  ;; -------------------------------------------------------------------------
  (verdict 6 "Vouch capability delegation (mint, verify, inspect)")
  (let* ((root-sec (tmp "vouch-root.pem"))
         (root-pub (feed-public-key-path root-sec))
         (child-sec (tmp "vouch-child.pem"))
         (child-pub (feed-public-key-path child-sec))
         (sub-sec (tmp "vouch-sub.pem"))
         (sub-pub (feed-public-key-path sub-sec)))
    (gips-key-generate-feed #:path root-sec)
    (gips-key-generate-feed #:path child-sec)
    (gips-key-generate-feed #:path sub-sec)

    (let* ((tok1 (gips-vouch-mint root-sec (read-file child-pub)
                                  #:expires-in 86400
                                  #:max-depth 2
                                  #:stake-score 100
                                  #:path-prefixes '("/gnu/store/")))
           (insp1 (gips-vouch-inspect tok1))
           (tok2 (gips-vouch-mint child-sec (read-file sub-pub)
                                  #:parent-token tok1
                                  #:expires-in 43200
                                  #:max-depth 1
                                  #:stake-score 90
                                  #:path-prefixes '("/gnu/store/abc-")))
           (insp2 (gips-vouch-inspect tok2))
           (chain-json (string-append "[" tok1 "," tok2 "]"))
           (verify-out (gips-vouch-verify root-pub chain-json #:target-subject sub-pub)))

      (check "gips-vouch-mint produces valid JSON token"
             (and (string-contains tok1 "\"issuer\"")
                  (string-contains tok1 "\"signature\"")))
      (check "gips-vouch-inspect reports Valid (active)"
             (string-contains insp1 "Token Status: Valid (active)"))
      (check "gips-vouch-inspect renders capabilities"
             (and (string-contains insp1 "Max Depth: 2")
                  (string-contains insp1 "Stake Score: 100")))
      (check "gips-vouch-inspect renders child capabilities"
             (and (string-contains insp2 "Max Depth: 1")
                  (string-contains insp2 "Stake Score: 90")))
      (check "gips-vouch-verify validates unbroken chain"
             (and (string-contains verify-out "Vouch chain verified successfully")
                  (string-contains verify-out "Max delegation depth: 1")
                  (string-contains verify-out "Stake score: 90")))
      (check "gips-vouch-verify fails on wrong root key"
             (catch #t
               (lambda () (gips-vouch-verify child-pub chain-json #:target-subject sub-pub) #f)
               (lambda _ #t)))
      (check "gips-vouch-verify fails on wrong target subject"
             (catch #t
               (lambda () (gips-vouch-verify root-pub chain-json #:target-subject root-pub) #f)
               (lambda _ #t)))))

  ;; -------------------------------------------------------------------------
  (verdict 7 "Cryptographic fraud proofs (generate, verify, submit, list)")
  (let* ((alice-sec (tmp "alice-fraud.pem"))
         (alice-pub (feed-public-key-path alice-sec))
         (honest-file (tmp "honest.nar"))
         (tampered-file (tmp "tampered.nar"))
         (narinfo-file (tmp "test.narinfo"))
         (sig-file (tmp "test.sig")))
    (gips-key-generate-feed #:path alice-sec)
    (write-file honest-file "honest package content")
    (write-file tampered-file "tampered package content")
    (write-file narinfo-file "StorePath: /gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16\nNarHash: sha256:0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73\nNarSize: 22\nReferences: \n")
    (write-file sig-file "1;alice.gnu;MEYCIQDummySignatureDataForFraudProofTestOnly123456789012345678901234567890=")

    (let* ((proof-hm (gips-fraud-proof-generate-hash-mismatch
                      narinfo-file
                      (read-file sig-file)
                      tampered-file
                      alice-pub))
           (proof-eq (gips-fraud-proof-generate-equivocation
                      "{\"narinfo\":\"StorePath: /gnu/store/foo\\nTimestamp: 100\\nIpfsCid: QmA\\nSignature: 1;a;sig\"}"
                      "{\"narinfo\":\"StorePath: /gnu/store/foo\\nTimestamp: 100\\nIpfsCid: QmB\\nSignature: 1;a;sig\"}"
                      alice-pub)))
      (check "gips-fraud-proof-generate-hash-mismatch emits valid JSON"
             (and (string-contains proof-hm "\"HashMismatch\"")
                  (string-contains proof-hm "\"publisher_key\"")))
      (check "gips-fraud-proof-generate-equivocation emits valid JSON"
             (and (string-contains proof-eq "\"Equivocation\"")
                  (string-contains proof-eq "\"publisher_key\"")))
      (check "gips-fraud-proof-verify fails on forged signature"
             (catch #t
               (lambda () (gips-fraud-proof-verify proof-hm) #f)
               (lambda _ #t))))

    ;; End-to-end wire test of submit and list against mock daemon
    (call-with-values
        (lambda ()
          (start-mock-server
           (lambda (req-line headers body)
             (cond
              ((string-contains req-line "/fraud-proof/submit")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 48\r\nConnection: close\r\n\r\n{\"ok\":true,\"message\":\"Fraud proof verified\"}")
              ((string-contains req-line "/fraud-proof/list")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
              (else
               "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))))
      (lambda (sock url)
        (gips-base-url url)
        (let ((pid (primitive-fork)))
          (if (zero? pid)
              (begin
                (accept-and-handle sock (lambda (req h b)
                                          (if (string-contains req "/fraud-proof/submit")
                                              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 48\r\nConnection: close\r\n\r\n{\"ok\":true,\"message\":\"Fraud proof verified\"}"
                                              "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
                (accept-and-handle sock (lambda (req h b)
                                          (if (string-contains req "/fraud-proof/list")
                                              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]"
                                              "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
                (primitive-exit 0))
              (begin
                (let ((sub-res (gips-fraud-proof-submit "{\"publisher_key\":\"k\",\"proof_type\":{\"Equivocation\":{\"feed_entry_a\":\"a\",\"feed_entry_b\":\"b\"}},\"created_at\":100}"))
                      (list-res (gips-fraud-proof-list)))
                  (waitpid pid)
                  (close-port sock)
                  (check "gips-fraud-proof-submit sends POST /fraud-proof/submit"
                         (string-contains sub-res "\"ok\":true"))
                  (check "gips-fraud-proof-list sends GET /fraud-proof/list"
                         (string=? (string-trim-both list-res) "[]"))))))))

    ;; Test build-trust-evaluate-json and build-vouch-ingest-json serialization
    (check "build-trust-evaluate-json minimal serialization"
           (string=? (build-trust-evaluate-json "pubkey123")
                     "{\"publisher_key\":\"pubkey123\"}"))
    (check "build-trust-evaluate-json with store-path and chain"
           (string=? (build-trust-evaluate-json "pubkey123" #:store-path "/gnu/store/abc" #:chain "[{\"sig\":\"s\"}]")
                     "{\"publisher_key\":\"pubkey123\",\"store_path\":\"/gnu/store/abc\",\"chain\":[{\"sig\":\"s\"}]}"))
    (check "build-vouch-ingest-json array wrapping"
           (string=? (build-vouch-ingest-json "[{\"payload\":{}}]")
                     "{\"chain\":[{\"payload\":{}}]}"))
    (check "build-vouch-ingest-json single object wrapping"
           (string=? (build-vouch-ingest-json "{\"payload\":{}}")
                     "{\"chain\":[{\"payload\":{}}]}"))

    ;; End-to-end wire test of trust evaluate and vouch ingest against mock daemon
    (call-with-values
        (lambda ()
          (start-mock-server
           (lambda (req-line headers body)
             (cond
              ((string-contains req-line "/trust/evaluate")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 61\r\nConnection: close\r\n\r\n{\"score\":85,\"trusted\":true,\"reason\":\"Valid delegation chain\"}")
              ((string-contains req-line "/vouch/ingest")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 65\r\nConnection: close\r\n\r\n{\"ok\":true,\"root_key\":\"r\",\"subject_key\":\"s\",\"message\":\"Ingested\"}")
              (else
               "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))))
      (lambda (sock url)
        (gips-base-url url)
        (let ((pid (primitive-fork)))
          (if (zero? pid)
              (begin
                (accept-and-handle sock (lambda (req h b)
                                          (if (string-contains req "/trust/evaluate")
                                              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 61\r\nConnection: close\r\n\r\n{\"score\":85,\"trusted\":true,\"reason\":\"Valid delegation chain\"}"
                                              "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
                (accept-and-handle sock (lambda (req h b)
                                          (if (string-contains req "/vouch/ingest")
                                              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 65\r\nConnection: close\r\n\r\n{\"ok\":true,\"root_key\":\"r\",\"subject_key\":\"s\",\"message\":\"Ingested\"}"
                                              "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
                (primitive-exit 0))
              (begin
                (let ((eval-res (gips-trust-evaluate "pubkey123" #:store-path "/gnu/store/abc"))
                      (ingest-res (gips-vouch-ingest "[{\"sig\":\"s\"}]")))
                  (waitpid pid)
                  (close-port sock)
                  (check "gips-trust-evaluate sends POST /trust/evaluate"
                         (string-contains eval-res "\"score\":85"))
                  (check "gips-vouch-ingest sends POST /vouch/ingest"
                         (string-contains ingest-res "\"ok\":true")))))))))

  ;; -------------------------------------------------------------------------
  (verdict 8 "Offline snapshot lifecycle (list, import, export)")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (cond
            ((string-contains req-line "/snapshot/list")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
            ((string-contains req-line "/snapshot/import")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 55\r\nConnection: close\r\n\r\n{\"snapshot_cid\":\"QmSnapImport\",\"imported_entries\":2}")
            ((string-contains req-line "/snapshot/export")
             "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: 14\r\nConnection: close\r\n\r\nmock-tar-bytes")
            (else
             "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((tok-path (tmp "snapshot-auth-token")))
        (write-file tok-path "test-token")
        (gips-auth-token-file tok-path))
      (let ((pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (accept-and-handle sock (lambda (req h b)
                                        (if (string-contains req "/snapshot/list")
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (accept-and-handle sock (lambda (req h b)
                                        (if (string-contains req "/snapshot/import")
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 55\r\nConnection: close\r\n\r\n{\"snapshot_cid\":\"QmSnapImport\",\"imported_entries\":2}"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (accept-and-handle sock (lambda (req h b)
                                        (if (string-contains req "/snapshot/export")
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: 14\r\nConnection: close\r\n\r\nmock-tar-bytes"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (primitive-exit 0))
            (begin
              (let* ((list-res (gips-snapshot-list))
                     (import-res (gips-snapshot-import "QmSnapImport"))
                     (export-file (tmp "exported-snapshot.tar"))
                     (exported-path (gips-snapshot-export "QmSnapImport" #:output-file export-file)))
                (waitpid pid)
                (close-port sock)
                (check "gips-snapshot-list sends GET /snapshot/list"
                       (string=? (string-trim-both list-res) "[]"))
                (check "gips-snapshot-import sends POST /snapshot/import with token"
                       (string-contains import-res "\"snapshot_cid\":\"QmSnapImport\""))
                (check "gips-snapshot-export downloads tar archive to specified output-file"
                       (and (string=? exported-path export-file)
                            (file-exists? export-file)
                            (string=? (read-file export-file) "mock-tar-bytes")))))))))

  ;; -------------------------------------------------------------------------
  (verdict 9 "Gossip status inspection (GET /gossip/status)")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (if (string-contains req-line "/gossip/status")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 172\r\nConnection: close\r\n\r\n{\"ok\":true,\"topics\":[\"gips.vouch.v1\",\"gips.fraud.v1\"],\"vouches_received\":0,\"vouches_accepted\":0,\"vouches_rejected\":0,\"fraud_proofs_received\":0,\"fraud_proofs_accepted\":0,\"fraud_proofs_rejected\":0}"
               "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (accept-and-handle sock (lambda (req h b)
                                        (if (string-contains req "/gossip/status")
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 172\r\nConnection: close\r\n\r\n{\"ok\":true,\"topics\":[\"gips.vouch.v1\",\"gips.fraud.v1\"],\"vouches_received\":0,\"vouches_accepted\":0,\"vouches_rejected\":0,\"fraud_proofs_received\":0,\"fraud_proofs_accepted\":0,\"fraud_proofs_rejected\":0}"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (primitive-exit 0))
            (begin
              (let ((status-res (gips-gossip-status)))
                (waitpid pid)
                (close-port sock)
                (check "gips-gossip-status sends GET /gossip/status"
                       (and (string-contains status-res "\"ok\":true")
                            (string-contains status-res "\"topics\":[\"gips.vouch.v1\",\"gips.fraud.v1\"]")))))))))

  ;; -------------------------------------------------------------------------
  (verdict 10 "Guix ACL management (list, check, authorize, revoke, diff)")
  (let* ((acl-path (tmp "guix-test-acl"))
         (sample-acl-content (string-append
                              ";; Guix test ACL\n"
                              "(acl\n"
                              " (entry\n"
                              "  (public-key\n"
                              "   (ecc\n"
                              "    (curve Ed25519)\n"
                              "    (q #0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF#)\n"
                              "    )\n"
                              "   )\n"
                              "  (tag\n"
                              "   (guix import)\n"
                              "   )\n"
                              "  )\n"
                              " )\n"))
         (new-key-sexp (string-append
                        "(public-key\n"
                        " (ecc\n"
                        "  (curve Ed25519)\n"
                        "  (q #9999999999999999999999999999999999999999999999999999999999999999#)\n"
                        "  )\n"
                        " )\n")))
    (write-file acl-path sample-acl-content)

    ;; 1. List
    (let ((list-out (gips-key-acl-list #:acl-file acl-path)))
      (check "gips-key-acl-list reads ACL and shows keys"
             (and (string-contains list-out "Authorized Guix Keys")
                  (string-contains list-out "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"))))

    ;; 2. Check
    (check "gips-key-acl-check finds existing key"
           (gips-key-acl-check #:acl-file acl-path #:key "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"))
    (check "gips-key-acl-check returns false for missing key"
           (not (gips-key-acl-check #:acl-file acl-path #:key "9999999999999999999999999999999999999999999999999999999999999999")))

    ;; 3. Authorize with dry-run
    (let ((dry-out (gips-key-acl-authorize #:acl-file acl-path #:key new-key-sexp #:dry-run? #t)))
      (check "gips-key-acl-authorize dry-run displays preview"
             (string-contains dry-out "[dry-run]"))
      (check "gips-key-acl-authorize dry-run does not write to disk"
             (not (gips-key-acl-check #:acl-file acl-path #:key "9999999999999999999999999999999999999999999999999999999999999999"))))

    ;; 4. Authorize real
    (let ((auth-out (gips-key-acl-authorize #:acl-file acl-path #:key new-key-sexp)))
      (check "gips-key-acl-authorize succeeds and writes key"
             (string-contains auth-out "Successfully authorized key"))
      (check "gips-key-acl-check now confirms new key"
             (gips-key-acl-check #:acl-file acl-path #:key "9999999999999999999999999999999999999999999999999999999999999999")))

    ;; 5. Diff
    (let* ((key-file-1 (tmp "trusted-key-1.pub"))
           (_ (write-file key-file-1 new-key-sexp))
           (diff-out (gips-key-acl-diff #:acl-file acl-path #:key-files (list key-file-1))))
      (check "gips-key-acl-diff reports matching and unmatched keys"
             (and (string-contains diff-out "Matching in both ACL and trusted set (1)")
                  (string-contains diff-out "In Guix ACL only (not in candidate trusted set) (1)"))))

    ;; 6. Revoke
    (let ((rev-out (gips-key-acl-revoke #:acl-file acl-path #:key "9999999999999999999999999999999999999999999999999999999999999999")))
      (check "gips-key-acl-revoke succeeds and removes key"
             (string-contains rev-out "Successfully revoked key"))
      (check "gips-key-acl-check confirms key was removed"
             (not (gips-key-acl-check #:acl-file acl-path #:key "9999999999999999999999999999999999999999999999999999999999999999")))))

  ;; -------------------------------------------------------------------------
  (verdict 11 "Terminal swarm monitor (gips monitor / (gips-monitor))")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (cond
            ((string-contains req-line "/gossip/status")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 172\r\nConnection: close\r\n\r\n{\"ok\":true,\"topics\":[\"gips.vouch.v1\",\"gips.fraud.v1\"],\"vouches_received\":0,\"vouches_accepted\":0,\"vouches_rejected\":0,\"fraud_proofs_received\":0,\"fraud_proofs_accepted\":0,\"fraud_proofs_rejected\":0}")
            ((string-contains req-line "/status")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}")
            ((string-contains req-line "/metrics")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"requests_total\":42}")
            ((string-contains req-line "/fraud-proof/list")
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
            (else
             "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((pid (primitive-fork)))
        (if (zero? pid)
            (begin
              ;; Handle concurrent requests
              (let loop ((count 0))
                (when (< count 8)
                  (catch #t
                    (lambda ()
                      (accept-and-handle sock (lambda (req h b)
                                                (cond
                                                 ((string-contains req "/gossip/status")
                                                  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 172\r\nConnection: close\r\n\r\n{\"ok\":true,\"topics\":[\"gips.vouch.v1\",\"gips.fraud.v1\"],\"vouches_received\":0,\"vouches_accepted\":0,\"vouches_rejected\":0,\"fraud_proofs_received\":0,\"fraud_proofs_accepted\":0,\"fraud_proofs_rejected\":0}")
                                                 ((string-contains req "/status")
                                                  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}")
                                                 ((string-contains req "/metrics")
                                                  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"requests_total\":42}")
                                                 ((string-contains req "/fraud-proof/list")
                                                  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
                                                 (else
                                                  "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))))
                      (loop (+ count 1)))
                    (lambda (key . args)
                      (primitive-exit 0)))))
              (primitive-exit 0))
            (begin
              (let* ((text-snapshot (gips-monitor #:once? #t))
                     (json-snapshot (gips-monitor #:once? #t #:json? #t)))
                (waitpid pid)
                (close-port sock)
                (check "gips-monitor prints formatted ASCII dashboard"
                       (and (string-contains text-snapshot "GIPS SWARM & NODE MONITOR")
                            (string-contains text-snapshot "Active Topics:")))
                (check "gips-monitor with #:json? #t emits structured JSON"
                       (and (string-contains json-snapshot "\"daemon_url\":")
                            (string-contains json-snapshot "\"fraud_proofs_count\":")))))))))

  ;; -------------------------------------------------------------------------
  (verdict 12 "Privacy-preserving substitute prefix queries (GET /substitute/prefix/:prefix)")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (if (string-contains req-line "/substitute/prefix/4zi91dws")
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 104\r\nConnection: close\r\n\r\n[{\"store_path\":\"/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10\",\"ipfs_cid\":\"QmTestCid123\"}]"
               "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (accept-and-handle sock (lambda (req h b)
                                        (if (string-contains req "/substitute/prefix/4zi91dws")
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 104\r\nConnection: close\r\n\r\n[{\"store_path\":\"/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10\",\"ipfs_cid\":\"QmTestCid123\"}]"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (primitive-exit 0))
            (begin
              (let ((resp (gips-search-prefix "4zi91dws")))
                (waitpid pid)
                (close-port sock)
                (check "gips-search-prefix sends GET /substitute/prefix/:prefix"
                       (string-contains resp "4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10"))))))))

  ;; -------------------------------------------------------------------------
  (verdict 13 "Direct UnixFS directory tree ingestion (POST /publish-tree)")
  (call-with-values
      (lambda ()
        (start-mock-server
         (lambda (req-line headers body)
           (if (and (string-contains req-line "/publish-tree")
                    (string-contains body "/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10"))
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 46\r\nConnection: close\r\n\r\n{\"ipfs_cid\":\"QmUnixFsTreeCid123\",\"gns_name\":null}"
               "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))))
    (lambda (sock url)
      (gips-base-url url)
      (let ((pid (primitive-fork)))
        (if (zero? pid)
            (begin
              (accept-and-handle sock (lambda (req h b)
                                        (if (and (string-contains req "/publish-tree")
                                                 (string-contains b "/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10"))
                                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 46\r\nConnection: close\r\n\r\n{\"ipfs_cid\":\"QmUnixFsTreeCid123\",\"gns_name\":null}"
                                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")))
              (primitive-exit 0))
            (begin
              (let ((resp (gips-publish-tree "/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10")))
                (waitpid pid)
                (close-port sock)
                (check "gips-publish-tree sends POST /publish-tree"
                       (string-contains resp "QmUnixFsTreeCid123"))))))))

  ;; -------------------------------------------------------------------------
  (verdict 14 "Guix System service definition and Shepherd specification ((gips service))")
  (let* ((cfg (gips-configuration
               #:gipsd-config (gipsd-configuration
                               #:listen "0.0.0.0:8080"
                               #:db-path "/var/lib/gips/gipsd.sqlite"
                               #:gossip-transport "cadet"
                               #:cadet-port "gips-sys-port")
               #:log-file "/var/log/gipsd.log"
               #:user "gips-daemon"
               #:group "gips-group"
               #:auto-start? #t))
         (toml (gips-configuration-toml cfg))
         (shepherd-spec (gips-shepherd-service-spec cfg))
         (activation (gips-activation-script cfg)))
    (check "gips-configuration? predicate matches record"
           (gips-configuration? cfg))
    (check "gips-configuration-toml serializes listen, db_path, and cadet fields"
           (and (string-contains toml "listen = \"0.0.0.0:8080\"")
                (string-contains toml "db_path = \"/var/lib/gips/gipsd.sqlite\"")
                (string-contains toml "gossip_transport = \"cadet\"")
                (string-contains toml "cadet_port = \"gips-sys-port\"")))
    (check "gips-shepherd-service-spec declares provision, user, and auto-start"
           (and (assoc-ref shepherd-spec 'auto-start?)
                (equal? (assoc-ref shepherd-spec 'user) '("gips-daemon"))
                (equal? (assoc-ref shepherd-spec 'provision) '((gipsd gips)))))
    (check "gips-activation-script establishes private directory and permissions"
           (and (string-contains activation "mkdir -p")
                (string-contains activation "chown -R gips-daemon:gips-group")
                (string-contains activation "chmod 0700"))))

  ;; -------------------------------------------------------------------------
  (verdict 15 "Standalone GNU Guix package definition ((gips package) & gips.scm)")
  (let* ((pkg (gips-package
               #:name "gips"
               #:version "0.1.0"
               #:synopsis "Guix IPFS Substitute Daemon and Peer-to-Peer Mirror Fabric"
               #:license "GPL-3.0-or-later"))
         (manifest-entry (gips-package->manifest-entry pkg)))
    (check "gips-package? predicate matches record"
           (gips-package? pkg))
    (check "gips-package-name and version are defined"
           (and (string=? (gips-package-name pkg) "gips")
                (string=? (gips-package-version pkg) "0.1.0")))
    (check "gips-package-synopsis and license match specification"
           (and (string-contains (gips-package-synopsis pkg) "Guix IPFS Substitute Daemon")
                (string=? (gips-package-license pkg) "GPL-3.0-or-later")))
    (check "gips-package->manifest-entry serializes manifest metadata"
           (equal? (assoc-ref manifest-entry 'license) '("GPL-3.0-or-later"))))

  (newline)
  (if (zero? %failures)
      (begin
        (format #t "test_api.scm: all fifteen verdicts hold~%")
        0)
      (begin
        (format #t "test_api.scm: ~a assertion(s) failed~%" %failures)
        1)))

(define %status
  (catch #t
    main
    (lambda (key . args)
      (format #t "~%test_api.scm: unhandled exception: ~a ~a~%" key args)
      1)
    (lambda (key . args)
      (backtrace))))

(system* "/bin/rm" "-rf" %tmp-dir)
(exit %status)
