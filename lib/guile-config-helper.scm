#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Guile helper for safely modifying Guix config.scm files
;;; This script properly parses and manipulates S-expressions
;;;
;;; Note: Shebang uses env -S for portability between Guix and other systems
;;; On Guix, you can also run with: guile --no-auto-compile -s guile-config-helper.scm

(use-modules (ice-9 match)
             (ice-9 rdelim)
             (srfi srfi-1))

;;; --- The reader/printer: (guix read-print) ----------------------------------
;;;
;;; This module is the engine behind `guix style'.  It is used here for one
;;; reason above all others: it represents comments as NODES IN THE TREE rather
;;; than discarding them.  Guile's stock `read' throws every comment away, so
;;; the previous read/pretty-print pair silently deleted all 134 comment lines
;;; of oracle/image/oracle-image.scm on any edit -- in a repository whose entire
;;; documentation convention is that non-obvious decisions are explained where
;;; they live.
;;;
;;; It also parses #~ / #$ / #$@ / #+ / #+@ natively and prints them back in
;;; that same spelling, which is why the stage-03 reader-macro workaround that
;;; used to live here is gone.  See lib/guile-config-helper_purpose.txt.
;;;
;;; Resolved at run time rather than with `use-modules' so that a machine
;;; without guix on its load path gets the sentence below instead of Guile's
;;; "no code for module (guix read-print)" backtrace.
(define %read-print
  (catch #t
    (lambda () (resolve-interface '(guix read-print)))
    (lambda _ #f)))

(unless %read-print
  (display
   (string-append
    "[ERROR] The Guile module (guix read-print) is not available.\n"
    "        It ships with Guix itself, and this helper needs it to edit a\n"
    "        configuration without deleting its comments.\n"
    "        Run this on a Guix system, or with guix on GUILE_LOAD_PATH.\n")
   (current-error-port))
  (exit 1))

(define read-with-comments        (module-ref %read-print 'read-with-comments))
(define pretty-print-with-comments
  (module-ref %read-print 'pretty-print-with-comments))
(define comment? (module-ref %read-print 'comment?))

;;; blank? is TRUE for comments as well as for vertical space and page breaks:
;;; it is the "this item is not code" predicate, and therefore the one to use
;;; for pass-through.  comment? alone would let vertical space be mistaken for
;;; a field.
(define blank? (module-ref %read-print 'blank?))

(define (code? item)
  "Is ITEM a real S-expression rather than a comment or blank line?"
  (not (blank? item)))

(define (map-code proc items)
  "Apply PROC to each code item of ITEMS, leaving comments and blank lines
   exactly where they are.  Rebuilding a form with `map' alone would hand PROC
   a <comment> record and corrupt the configuration."
  (map (lambda (item) (if (blank? item) item (proc item))) items))

;;; Read all S-expressions from config file, comments included.
;;;
;;; Deliberately a read-with-comments LOOP and not read-with-comments/sequence,
;;; which looks like the obvious choice and is not: /sequence discards the
;;; <vertical-space> nodes between top-level forms.  Those nodes are what tell
;;; the printer to keep a comment on its own line, so without them a comment
;;; that followed a blank line is re-emitted glued to the end of the preceding
;;; form as a margin comment -- measured on oracle-image.scm, 2026-08-08.
(define (read-config config-file)
  (call-with-input-file config-file
    (lambda (port)
      (let loop ((exprs '()))
        (let ((expr (read-with-comments port)))
          (if (eof-object? expr)
              (reverse exprs)
              (loop (cons expr exprs))))))))

;;; Write all S-expressions back to file, comments and #~ syntax included.
(define (write-config exprs config-file)
  (call-with-output-file config-file
    (lambda (port)
      (for-each (lambda (expr)
                  (pretty-print-with-comments port expr))
                exprs))))

;;; Check if a module is in use-modules
(define (has-module? use-modules-expr module)
  (match use-modules-expr
    (('use-modules modules ...)
     (member module modules))
    (_ #f)))

;;; Add a module to use-modules if not present
(define (add-module-to-use-modules use-modules-expr module)
  (match use-modules-expr
    (('use-modules modules ...)
     (if (member module modules)
         use-modules-expr
         `(use-modules ,@modules ,module)))
    (_ use-modules-expr)))

;;; Check if a service is in the services list
(define (service-type-matches? svc target-type)
  (match svc
    (('service type-sym _ ...) (eq? type-sym target-type))
    (('service type-sym) (eq? type-sym target-type))
    (_ #f)))

(define (has-service-type? services-expr target-type)
  (match services-expr
    (('append ('list services ...) rest ...)
     (any (lambda (s) (service-type-matches? s target-type)) services))
    (('list services ...)
     (any (lambda (s) (service-type-matches? s target-type)) services))
    (_ #f)))

(define (has-service? services-expr service-expr)
  (match services-expr
    (('append ('list services ...) rest ...)
     (member service-expr services))
    (('list services ...)
     (member service-expr services))
    (_ #f)))

;;; Add a service to the services field
(define (add-service-to-services services-expr service-expr)
  (match services-expr
    ;; Already using append with a list
    (('append ('list services ...) base-services ...)
     (if (member service-expr services)
         services-expr
         `(append (list ,@services ,service-expr) ,@base-services)))

    ;; Just %base-services - wrap in append
    ('%base-services
     `(append (list ,service-expr) %base-services))

    ;; Just %desktop-services - wrap in append
    ('%desktop-services
     `(append (list ,service-expr) %desktop-services))

    ;; Simple list - add to it
    (('list services ...)
     (if (member service-expr services)
         services-expr
         `(list ,@services ,service-expr)))

    ;; Unknown structure - return as-is
    (_ services-expr)))

;;; Modify the services field in operating-system
(define (modify-os-services os-expr service-expr)
  (match os-expr
    (('operating-system fields ...)
     (let loop ((fields fields)
                (result '()))
       (match fields
         (() `(operating-system ,@(reverse result)))
         ((('services services-expr) rest ...)
          (loop rest
                (cons `(services ,(add-service-to-services services-expr service-expr))
                      result)))
         ((field rest ...)
          (loop rest (cons field result))))))
    (_ os-expr)))

;;; Process all expressions, adding module and service
(define (process-exprs exprs module service-expr)
  (let loop ((exprs exprs)
             (result '())
             (module-added? #f))
    (match exprs
      (() (reverse result))

      ;; Handle use-modules - add our module if needed
      (((and use-mod ('use-modules mods ...)) rest ...)
       (loop rest
             (cons (add-module-to-use-modules use-mod module) result)
             #t))

      ;; Handle operating-system - add our service
      (((and os-expr ('operating-system fields ...)) rest ...)
       (loop rest
             (cons (modify-os-services os-expr service-expr) result)
             module-added?))

      ;; Other expressions - keep as-is
      ((expr rest ...)
       (loop rest (cons expr result) module-added?)))))

;;; ---------------------------------------------------------------------------
;;; Switching to %desktop-services
;;;
;;; %desktop-services is a SUPERSET of %base-services. A config written against
;;; %base-services must instantiate networking itself; once the base becomes
;;; %desktop-services those same services are provided twice, and the build
;;; fails with:
;;;
;;;   guix system: error: more than one target service of type 'dbus'
;;;
;;; A plain sed of %base-services -> %desktop-services therefore produces a
;;; config that cannot build. The duplicates have to be removed from the
;;; explicit list at the same time.
;;;
;;; The subtle case is a service carrying a CONFIGURATION RECORD, e.g.
;;;
;;;   (service network-manager-service-type
;;;            (network-manager-configuration (extra-configuration-files ...)))
;;;
;;; Deleting that outright silently discards the configuration -- for
;;; framework-dual it would drop the DNS block and reintroduce the getaddrinfo
;;; failure of 2026-08-02. Such a service is instead rewritten as a
;;; modify-services clause against the new base, preserving the settings.

;;; Service types %desktop-services already provides, which a %base-services
;;; config commonly lists explicitly.
(define %desktop-provided-services
  '(network-manager-service-type
    wpa-supplicant-service-type
    dbus-root-service-type
    polkit-service-type
    ntp-service-type))

;;; Recursively replace %base-services with %desktop-services.
(define (rewrite-base-services expr)
  (cond
   ((eq? expr '%base-services) '%desktop-services)
   ((pair? expr) (cons (rewrite-base-services (car expr))
                       (rewrite-base-services (cdr expr))))
   (else expr)))

;;; A bare (service TYPE) -- no configuration argument to lose.
(define (bare-duplicate? expr)
  (match expr
    (('service type) (memq type %desktop-provided-services))
    (_ #f)))

;;; A (service TYPE CONFIG) whose CONFIG must be preserved.
(define (configured-duplicate? expr)
  (match expr
    (('service type config) (and (memq type %desktop-provided-services) #t))
    (_ #f)))

;;; Turn (service TYPE (record FIELDS ...)) into a modify-services clause that
;;; inherits the base service's value and applies the same fields.
(define (service->modify-clause expr)
  (match expr
    (('service type (record fields ...))
     `(,type config => (,record (inherit config) ,@fields)))
    (_ #f)))

;;; Rewrite a services expression for %desktop-services.
(define (switch-services-to-desktop services-expr)
  (match services-expr
    (('append ('list services ...) base ...)
     (let* ((keep    (remove (lambda (s)
                               (or (bare-duplicate? s)
                                   (configured-duplicate? s)))
                             services))
            (clauses (filter-map service->modify-clause
                                 (filter configured-duplicate? services)))
            (base*   (rewrite-base-services base)))
       ;; Fold the preserved clauses into an existing modify-services on the
       ;; base if there is one; otherwise wrap the base in a new one.
       ;;
       ;; The decision is taken on the CODE items only.  Matching base* itself
       ;; would be a real bug now that comments are nodes: a single blank line
       ;; inside the append makes base* two items long, the ((single) ...)
       ;; pattern stops matching, and control falls to the catch-all -- which
       ;; drops CLAUSES on the floor, silently discarding the very
       ;; network-manager configuration this function exists to preserve.  The
       ;; rebuild then goes through map-code so the blanks stay put.
       (let ((base-code (filter code? base*)))
         (match base-code
           ((('modify-services base-sym existing ...))
            `(append (list ,@keep)
                     ,@(map-code
                        (lambda (_)
                          `(modify-services ,base-sym ,@clauses ,@existing))
                        base*)))
           ((single)
            (if (null? clauses)
                `(append (list ,@keep) ,@base*)
                `(append (list ,@keep)
                         ,@(map-code
                            (lambda (s) `(modify-services ,s ,@clauses))
                            base*))))
           (_ `(append (list ,@keep) ,@base*))))))

    ;; Bare %base-services with no explicit list -- nothing to de-duplicate.
    ('%base-services '%desktop-services)

    (_ (rewrite-base-services services-expr))))

(define (switch-os-to-desktop os-expr)
  (match os-expr
    (('operating-system fields ...)
     `(operating-system
       ,@(map (lambda (field)
                (match field
                  (('services services-expr)
                   `(services ,(switch-services-to-desktop services-expr)))
                  (_ field)))
              fields)))
    (_ os-expr)))

(define (cmd-switch-to-desktop config-file)
  ;; %desktop-services is exported by (gnu services desktop). Rewriting the base
  ;; without importing that module leaves a config that fails with
  ;; "%desktop-services: unbound variable" -- so the module goes in here rather
  ;; than relying on a subsequent add-service call to bring it along.
  (let* ((exprs (read-config config-file))
         (desktop-module '(gnu services desktop))
         (modified (map (lambda (expr)
                          (match expr
                            (('use-modules _ ...)
                             (add-module-to-use-modules expr desktop-module))
                            (('operating-system _ ...) (switch-os-to-desktop expr))
                            (_ expr)))
                        exprs)))
    (write-config modified config-file)
    (display "Switched to %desktop-services\n")))

;;; Main command handlers
(define (cmd-add-service config-file module-name service-expr-str)
  (let* ((exprs (read-config config-file))
         (service-expr (call-with-input-string service-expr-str read))
         (module (call-with-input-string module-name read))
         (modified-exprs (process-exprs exprs module service-expr)))
    (write-config modified-exprs config-file)
    (display "Service added successfully\n")))

(define (cmd-check-service config-file service-type)
  (let ((exprs (read-config config-file))
        (target-service `(service ,(string->symbol service-type))))
    (let loop ((exprs exprs))
      (match exprs
        (() (display "no\n") (exit 1))

        ;; Found operating-system with services
        ((('operating-system fields ...) rest ...)
         (let ((services-field (assoc 'services
                                      (filter-map (lambda (f)
                                                    (match f
                                                      (('services val) (cons 'services val))
                                                      (_ #f)))
                                                  fields))))
           (if (and services-field
                    (has-service? (cdr services-field) target-service))
               (begin
                 (display "yes\n")
                 (exit 0))
               (loop rest))))

        ;; Not an operating-system, keep looking
        ((_ rest ...)
         (loop rest))))))

;;; ---------------------------------------------------------------------------
;;; First-boot preferences: host name, timezone, login shell
;;;
;;; oracle/image/oracle-image.scm bakes (host-name "guix-oracle") and
;;; (timezone "America/New_York") into the image.  That was correct while every
;;; user built their own image; it stops being correct the moment ONE image is
;;; published for everyone, because you cannot bake a stranger's timezone.  So
;;; the preferences move out of the build and into first boot, and these
;;; subcommands are what oracle/postinstall/preferences.scm calls to apply them.
;;;
;;; Everything below the CLI layer is a pure function from S-expression to
;;; S-expression.  That is not stylistic: it is what lets
;;; oracle/tests/test-oracle-preferences.scm assert on the transformation
;;; directly, offline, without a config file, a guix, or a network.
;;;
;;; A sed-based path is deliberately absent.  One was removed on 2026-08-03 in
;;; 954bb8b and must not come back -- `s/(host-name ...)/.../` cannot tell the
;;; field from the same text inside a comment or a string, and the failure mode
;;; is a config that no longer parses on a machine reachable only by SSH.

;;; --- Generic record-form field access ---------------------------------------
;;;
;;; Both (operating-system (field value) ...) and (user-account (field value) ...)
;;; are the same shape, so one set of accessors serves both.
;;;
;;; These are comment-safe for a structural reason worth stating, because it is
;;; what everything below relies on: a <comment> or <vertical-space> node is a
;;; RECORD, not a pair, so field-name returns #f for it.  Every lookup here is
;;; driven by field-name, so comments are invisible to inspection and untouched
;;; by rewriting, without a single explicit test for them.

(define (field-name field)
  "Return the field name of a (NAME VALUE) form, or #f if FIELD is not one."
  (match field
    (((? symbol? name) . _) name)
    (_ #f)))

(define (record-has-field? record name)
  (and (pair? record)
       (any (lambda (f) (eq? (field-name f) name)) (cdr record))))

(define (record-field-ref record name)
  "Return the value of field NAME in RECORD, or #f when it is absent.
   Callers that must distinguish an absent field from a #f value use
   record-has-field? first."
  (if (pair? record)
      (let loop ((fields (cdr record)))
        (cond ((not (pair? fields)) #f)
              ((eq? (field-name (car fields)) name)
               (match (car fields) ((_ value) value) (_ #f)))
              (else (loop (cdr fields)))))
      #f))

(define (record-field-set record name value)
  "Return RECORD with field NAME set to VALUE.

   An absent field is INSERTED rather than ignored.  Silently returning the
   record unchanged would report success while changing nothing, which on a
   remote machine is discovered only after a reconfigure that did not do what
   was asked."
  (if (record-has-field? record name)
      (cons (car record)
            (map (lambda (f)
                   (if (eq? (field-name f) name) (list name value) f))
                 (cdr record)))
      (cons (car record) (cons (list name value) (cdr record)))))

(define (record-field-remove record name)
  (cons (car record)
        (remove (lambda (f) (eq? (field-name f) name)) (cdr record))))

;;; --- Walking the configuration ----------------------------------------------

(define (operating-system-form? expr)
  (match expr (('operating-system _ ...) #t) (_ #f)))

(define (user-account-form? expr)
  (match expr (('user-account _ ...) #t) (_ #f)))

(define (collect-forms pred expr)
  "Every subform of EXPR satisfying PRED, outermost first."
  (cond ((pred expr) (list expr))
        ((pair? expr) (append (collect-forms pred (car expr))
                              (collect-forms pred (cdr expr))))
        (else '())))

(define (replace-form expr target replacement)
  "EXPR with every subform equal? to TARGET replaced by REPLACEMENT."
  (cond ((equal? expr target) replacement)
        ((pair? expr) (cons (replace-form (car expr) target replacement)
                            (replace-form (cdr expr) target replacement)))
        (else expr)))

(define (map-operating-systems proc exprs)
  "Apply PROC to every (operating-system ...) form anywhere in EXPRS.

   Searched recursively rather than only at top level, because a config may
   bind it -- (define %system (operating-system ...)) -- instead of ending in
   it.  Finding none is an error, not a no-op."
  (let ((seen 0))
    (define (walk expr)
      (cond ((operating-system-form? expr)
             (set! seen (+ seen 1))
             (proc expr))
            ((pair? expr) (cons (walk (car expr)) (walk (cdr expr))))
            (else expr)))
    (let ((result (map walk exprs)))
      (when (zero? seen)
        (throw 'config-edit-error
               "no (operating-system ...) form found in the configuration"))
      result)))

;;; --- Host name and timezone -------------------------------------------------

(define (set-os-host-name os-expr host-name)
  (record-field-set os-expr 'host-name host-name))

(define (set-os-timezone os-expr timezone)
  (record-field-set os-expr 'timezone timezone))

;;; --- Login shell ------------------------------------------------------------
;;;
;;; NAME PACKAGE BINARY MODULE.
;;;
;;; bash has no package and no binary on purpose.  It is already the default, so
;;; the correct representation of "I want bash" is the ABSENCE of a shell field,
;;; not (shell (file-append bash "/bin/bash")): writing the field pins one
;;; particular bash store path into the account for no benefit, and it is the
;;; thing that has to be undone if the user later changes their mind.
;;;
;;; Every other shell carries its package and its module, because
;;; (file-append zsh "/bin/zsh") is only meaningful if zsh is (a) a bound
;;; variable, which needs (gnu packages shells) imported, and (b) actually in
;;; the system closure, which needs it in the packages field.  Miss either and
;;; the account gets a login shell that does not exist -- on a machine whose
;;; only access path is SSH, which runs that shell.
(define %login-shells
  '(("bash" #f   #f          #f)
    ("zsh"  zsh  "/bin/zsh"  (gnu packages shells))
    ("fish" fish "/bin/fish" (gnu packages shells))))

(define (login-shell-names)
  (map car %login-shells))

(define (login-shell-spec name)
  (or (assoc name %login-shells)
      (throw 'config-edit-error
             (string-append "unknown login shell \"" name
                            "\"; choose one of: "
                            (string-join (login-shell-names) ", ")))))

(define (select-user-account accounts user-name)
  "Pick the account whose shell is to be set.

   Matching on the literal name handles (name \"guix\").  It cannot handle
   (name %user-name), which is what oracle-image.scm writes and therefore what
   /run/current-system/configuration.scm contains -- the value is a symbol, not
   the string the user typed.  A config with exactly one user-account is
   unambiguous regardless, so that is the fallback.  Anything genuinely
   ambiguous is refused rather than guessed."
  (let ((named (filter (lambda (a) (equal? (record-field-ref a 'name) user-name))
                       accounts)))
    (cond
     ((= 1 (length named)) (car named))
     ((> (length named) 1)
      (throw 'config-edit-error
             (string-append "several user-account forms are named \""
                            user-name "\"; refusing to guess which to edit")))
     ((= 1 (length accounts)) (car accounts))
     ((null? accounts)
      (throw 'config-edit-error
             "no (user-account ...) form found in the configuration"))
     (else
      (throw 'config-edit-error
             (string-append "found " (number->string (length accounts))
                            " user-account forms and none is named \""
                            user-name "\"; set the shell field by hand"))))))

(define (add-package-to-packages packages-expr package)
  "Add PACKAGE to a packages field value, preserving whatever shape it has."
  (match packages-expr
    (('append ('list items ...) rest ...)
     (if (memq package items)
         packages-expr
         `(append (list ,@items ,package) ,@rest)))
    (('list items ...)
     (if (memq package items) packages-expr `(list ,@items ,package)))
    ;; `base' is guarded with code? because it is the improper-list tail: an
    ;; unguarded `items ... base' binds BASE to a trailing comment node, and
    ;; the rebuild would then move the real base into the middle of the list
    ;; and leave a <comment> record as the tail.  A trailing comment instead
    ;; falls through to the catch-all below, which is merely a different shape,
    ;; not a broken one.
    (('cons* items ... (? code? base))
     (if (memq package items) packages-expr `(cons* ,@items ,package ,base)))
    (('cons item base)
     (if (equal? item package) packages-expr `(cons* ,item ,package ,base)))
    ((? symbol? base) `(append (list ,package) ,base))
    (_ `(append (list ,package) ,packages-expr))))

(define (add-package-to-os os-expr package)
  (if (record-has-field? os-expr 'packages)
      (record-field-set os-expr 'packages
                        (add-package-to-packages
                         (record-field-ref os-expr 'packages) package))
      ;; An absent packages field means the default, which is %base-packages.
      (record-field-set os-expr 'packages `(append (list ,package) %base-packages))))

(define (set-os-login-shell os-expr user-name shell-name)
  "Return OS-EXPR with USER-NAME's login shell set to SHELL-NAME.

   Pure, and deliberately does both halves of the job: the shell field on the
   account and the package in the system closure.  Splitting them into two
   functions is how you end up shipping one without the other."
  (let* ((spec     (login-shell-spec shell-name))
         (package  (list-ref spec 1))
         (binary   (list-ref spec 2))
         (accounts (collect-forms user-account-form? os-expr))
         (target   (select-user-account accounts user-name))
         (edited   (if package
                       (record-field-set target 'shell
                                         `(file-append ,package ,binary))
                       (record-field-remove target 'shell)))
         (result   (replace-form os-expr target edited)))
    (if package
        (add-package-to-os result package)
        result)))

;;; --- Module imports ---------------------------------------------------------

(define (config-has-module? exprs module)
  (any (lambda (e)
         (match e
           (('use-modules mods ...) (and (member module mods) #t))
           (_ #f)))
       exprs))

(define (ensure-module exprs module)
  "Ensure MODULE is imported, so a package variable it exports is bound.
   Without this, (file-append zsh ...) fails with 'zsh: unbound variable' and
   the reconfigure aborts before it changes anything -- noisy, but only after
   the user has waited for it."
  (if (config-has-module? exprs module)
      exprs
      (let loop ((rest exprs) (acc '()) (added? #f))
        (cond
         ((null? rest)
          (if added?
              (reverse acc)
              ;; No use-modules form at all: add one ahead of everything else.
              (cons `(use-modules ,module) (reverse acc))))
         ((and (not added?)
               (match (car rest) (('use-modules _ ...) #t) (_ #f)))
          (loop (cdr rest)
                (cons (add-module-to-use-modules (car rest) module) acc)
                #t))
         (else (loop (cdr rest) (cons (car rest) acc) added?))))))

;;; --- Whole-config transformations (pure) ------------------------------------

(define (config-set-host-name exprs host-name)
  (map-operating-systems (lambda (os) (set-os-host-name os host-name)) exprs))

(define (config-set-timezone exprs timezone)
  (map-operating-systems (lambda (os) (set-os-timezone os timezone)) exprs))

(define (config-set-login-shell exprs user-name shell-name)
  (let* ((spec   (login-shell-spec shell-name))
         (module (list-ref spec 3))
         (edited (map-operating-systems
                  (lambda (os) (set-os-login-shell os user-name shell-name))
                  exprs)))
    (if module (ensure-module edited module) edited)))

(define (config-has-gips-service? exprs)
  "Check whether any operating-system in EXPRS contains gips-service-type."
  (any (lambda (expr)
         (match expr
           (('operating-system fields ...)
            (any (lambda (f)
                   (match f
                     (('services services-expr)
                      (has-service-type? services-expr 'gips-service-type))
                     (_ #f)))
                 fields))
           (_ #f)))
       (filter code? exprs)))

(define (config-add-gips-service exprs . maybe-config)
  "Pure transform: ensure (gips service) is imported and (service gips-service-type ...)
   is added to operating-system services without corrupting comments or duplicate entries."
  (let* ((service-expr (if (and (pair? maybe-config) (car maybe-config))
                           `(service gips-service-type ,(car maybe-config))
                           `(service gips-service-type)))
         (gips-module '(gips service)))
    (if (config-has-gips-service? exprs)
        exprs
        (let ((with-module (ensure-module exprs gips-module)))
          (map-operating-systems
           (lambda (os)
             (modify-os-services os service-expr))
           with-module)))))

;;; --- CLI layer --------------------------------------------------------------

(define (run-config-edit config-file transform)
  "Apply TRANSFORM to CONFIG-FILE's forms and write the result back.

   Two properties matter here.  TRANSFORM runs to completion before anything is
   written, so a refusal leaves the file byte-for-byte as it was.  And a
   transform that changes nothing writes nothing -- re-running with the value
   already in place must not reformat the user's file as a side effect."
  (let* ((original (read-config config-file))
         (edited   (transform original)))
    (if (equal? original edited)
        (display "[OK] Already set; configuration left untouched\n")
        (begin
          (write-config edited config-file)
          (display "[OK] Configuration updated\n")))))

(define (guarded thunk)
  "Turn a config-edit-error into an ASCII [ERROR] line and exit 1."
  (catch 'config-edit-error
    thunk
    (lambda (key message)
      (display (string-append "[ERROR] " message "\n") (current-error-port))
      (exit 1))))

(define (cmd-set-host-name config-file host-name)
  (guarded (lambda ()
             (run-config-edit config-file
                              (lambda (exprs)
                                (config-set-host-name exprs host-name))))))

(define (cmd-set-timezone config-file timezone)
  (guarded (lambda ()
             (run-config-edit config-file
                              (lambda (exprs)
                                (config-set-timezone exprs timezone))))))

(define (cmd-set-login-shell config-file user-name shell-name)
  (guarded (lambda ()
             (run-config-edit config-file
                              (lambda (exprs)
                                (config-set-login-shell exprs user-name
                                                        shell-name))))))

(define (cmd-add-gips-service config-file . maybe-config-str)
  (guarded (lambda ()
             (let ((custom-config (if (pair? maybe-config-str)
                                      (call-with-input-string (car maybe-config-str) read)
                                      #f)))
               (run-config-edit config-file
                                (lambda (exprs)
                                  (if custom-config
                                      (config-add-gips-service exprs custom-config)
                                      (config-add-gips-service exprs))))))))

(define (cmd-check-gips-service config-file)
  (let* ((exprs (read-config config-file))
         (has?  (config-has-gips-service? exprs)))
    (if has?
        (begin (display "yes\n") (exit 0))
        (begin (display "no\n") (exit 1)))))

;;; Main entry point
(define (main args)
  (match args
    ((_ "add-service" config-file module-name service-expr)
     (cmd-add-service config-file module-name service-expr))

    ((_ "check-service" config-file service-type)
     (cmd-check-service config-file service-type))

    ((_ "add-gips-service" config-file)
     (cmd-add-gips-service config-file))

    ((_ "add-gips-service" config-file config-expr-str)
     (cmd-add-gips-service config-file config-expr-str))

    ((_ "check-gips-service" config-file)
     (cmd-check-gips-service config-file))

    ((_ "has-gips-service" config-file)
     (cmd-check-gips-service config-file))

    ((_ "switch-to-desktop" config-file)
     (cmd-switch-to-desktop config-file))

    ((_ "set-host-name" config-file host-name)
     (cmd-set-host-name config-file host-name))

    ((_ "set-timezone" config-file timezone)
     (cmd-set-timezone config-file timezone))

    ((_ "set-login-shell" config-file user-name shell-name)
     (cmd-set-login-shell config-file user-name shell-name))

    (_
     (display "Usage:\n")
     (display "  guile-config-helper.scm add-service CONFIG-FILE MODULE SERVICE-EXPR\n")
     (display "  guile-config-helper.scm check-service CONFIG-FILE SERVICE-TYPE\n")
     (display "  guile-config-helper.scm add-gips-service CONFIG-FILE [CONFIG-EXPR]\n")
     (display "  guile-config-helper.scm check-gips-service CONFIG-FILE\n")
     (display "  guile-config-helper.scm switch-to-desktop CONFIG-FILE\n")
     (display "  guile-config-helper.scm set-host-name CONFIG-FILE HOST-NAME\n")
     (display "  guile-config-helper.scm set-timezone CONFIG-FILE TIMEZONE\n")
     (display "  guile-config-helper.scm set-login-shell CONFIG-FILE USER SHELL\n")
     (exit 1))))

(main (command-line))
