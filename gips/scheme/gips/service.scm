;;; GNU Guix System Service Definition for GIPS daemon (gipsd)
;;;
;;; Defines `<gips-configuration>` and `gips-service-type` for integrating
;;; GIPS into GNU Guix System configurations (`/etc/config.scm`).

(define-module (gips service)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (gips config)
  #:export (<gips-configuration>
            gips-configuration
            gips-configuration?
            gips-configuration-package
            gips-configuration-gipsd-config
            gips-configuration-log-file
            gips-configuration-user
            gips-configuration-group
            gips-configuration-auto-start?
            gips-configuration-toml
            gips-shepherd-service-spec
            gips-activation-script
            gips-service-type))

;;; Record representing the full Guix System service configuration for GIPS.
(define-record-type <gips-configuration>
  (%make-gips-configuration package gipsd-config log-file user group auto-start?)
  gips-configuration?
  (package        gips-configuration-package)
  (gipsd-config   gips-configuration-gipsd-config)
  (log-file       gips-configuration-log-file)
  (user           gips-configuration-user)
  (group          gips-configuration-group)
  (auto-start?    gips-configuration-auto-start?))

(define* (gips-configuration #:key
                             (package #f)
                             (gipsd-config (gipsd-configuration
                                            #:db-path "/var/lib/gips/gipsd.sqlite"))
                             (log-file "/var/log/gipsd.log")
                             (user "gips")
                             (group "gips")
                             (auto-start? #t))
  "Construct a <gips-configuration> record.
GIPSD-CONFIG must be a <gipsd-configuration> record from (gips config).
LOG-FILE is where daemon stdout/stderr will be redirected.
USER and GROUP specify the system account under which gipsd runs."
  (unless (gipsd-configuration? gipsd-config)
    (error "gips-configuration: #:gipsd-config must be a <gipsd-configuration>"
           gipsd-config))
  (unless (string? log-file)
    (error "gips-configuration: #:log-file must be a string" log-file))
  (unless (string? user)
    (error "gips-configuration: #:user must be a string" user))
  (unless (string? group)
    (error "gips-configuration: #:group must be a string" group))
  (%make-gips-configuration package gipsd-config log-file user group (and auto-start? #t)))

;;; Generate the configuration TOML file content for this service instance.
(define (gips-configuration-toml config)
  (gipsd-configuration->toml (gips-configuration-gipsd-config config)))

;;; Returns a portable specification list representing the Shepherd service definition.
(define (gips-shepherd-service-spec config)
  (let ((gconfig (gips-configuration-gipsd-config config)))
    `((provision (gipsd gips))
      (requirement (networking loopback ipfs))
      (documentation "GNU Guix IPFS substitute daemon (gipsd)")
      (auto-start? ,(gips-configuration-auto-start? config))
      (user ,(gips-configuration-user config))
      (group ,(gips-configuration-group config))
      (log-file ,(gips-configuration-log-file config))
      (listen ,(gipsd-configuration-listen gconfig))
      (db-path ,(gipsd-configuration-db-path gconfig))
      (ipfs-api ,(gipsd-configuration-ipfs-api gconfig))
      (gossip-transport ,(gipsd-configuration-gossip-transport gconfig)))))

;;; Activation script actions (creating directories and establishing owner-only permissions).
(define (gips-activation-script config)
  (let* ((gconfig (gips-configuration-gipsd-config config))
         (db-path (gipsd-configuration-db-path gconfig))
         (user (gips-configuration-user config))
         (group (gips-configuration-group config)))
    (format #f "#!/bin/sh
mkdir -p $(dirname ~a)
chown -R ~a:~a $(dirname ~a)
chmod 0700 $(dirname ~a)
" db-path user group db-path db-path)))

;;; Portable service type identifier for Guix System
(define gips-service-type
  (list 'service-type 'gips-service-type gips-shepherd-service-spec))
