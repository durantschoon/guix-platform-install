#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; 04-deploy.scm --- upload, import, network, launch on OCI.
;;;
;;; Encodes the exact sequence first run successfully on 2026-08-08:
;;;
;;;   Object Storage bucket -> multipart upload -> custom image import
;;;   (PARAVIRTUALIZED) -> poll AVAILABLE -> VCN + internet gateway +
;;;   default route + public subnet -> launch VM.Standard.E2.1.Micro
;;;   with a public IP -> wait for the SSH banner.
;;;
;;; The launch walks the availability domains rather than taking the
;;; first: Always Free E2.1.Micro capacity is routinely exhausted, and
;;; `Out of host capacity' in one AD says nothing about the next.  The
;;; walk is bounded (each AD once) and ends in advice, never in a retry
;;; loop -- see launch-error-kind and capacity-advice below.
;;;
;;; Idempotent throughout: every resource is looked up by display-name
;;; first and only created if absent, so a rerun after any failure
;;; continues instead of duplicating.  All state lives in OCI itself;
;;; nothing is stored locally between runs.  That property is what makes
;;; "come back in a few hours and rerun" a real answer to a capacity
;;; failure: the image and network are already there.
;;;
;;; No JSON parser needed: every oci call uses --query/--raw-output.
;;;
;;; The final SSH login is left to the user on purpose: the instance
;;; only trusts the key baked into the image, which is normally the
;;; user's passphrase-protected personal key.  This script verifies the
;;; SSH BANNER (sshd up, port reachable) -- an unattended full login
;;; check would need the private key unencrypted, which we do not ask
;;; for.  See 03-smoke-test.scm for why "Permission denied (publickey)"
;;; from a BatchMode probe is SUCCESS here, not failure.

(load (string-append (dirname (car (command-line))) "/oci-common.scm"))

(define %bucket "guix-images")
(define %object-name "guix-oracle.qcow2")
(define %image-name "guix-oracle")
(define %instance-name "guix-oracle")
(define %vcn-name "guix-vcn")
(define %shape "VM.Standard.E2.1.Micro")

;; Upper bound on the availability-domain walk.  Real tenancies have 1-3
;; ADs; this exists so an unexpected CLI response cannot turn the
;; enumeration below into an unbounded loop.  It is a guard, not policy.
(define %max-availability-domains 10)

(define (compartment)
  "The root compartment is the tenancy; free-tier resources live there."
  (or (oci-config-value "tenancy")
      (die "no tenancy in ~/.oci/config; run 01-setup-client.scm first")))

(define (ocid-or-false s)
  "Treat empty/None query output as #f."
  (and (not (string-null? s)) (not (string=? s "None")) s))

;;; ---------------------------------------------------------------------
;;; Launch-failure classification (PURE -- no I/O, no CLI call)
;;;
;;; These two procedures are deliberately free of side effects so that
;;; oracle/tests/test-oracle-capacity.scm can read them out of this file
;;; and assert on them offline, with no OCI account and no network.  Keep
;;; them dependent on core Guile only (string-contains, string-downcase,
;;; string-join); the test evaluates them in isolation from the rest of
;;; this script.

(define (launch-error-kind output)
  "Classify OUTPUT -- the combined stdout+stderr of a `compute instance
launch' -- as one of four symbols:

  capacity  Oracle has no free host for this shape in the availability
            domain that was tried.  This is the ONLY kind the caller
            walks past, because a different AD draws on a different
            pool and may well succeed.
  limit     A tenancy service limit or quota was hit.  Every AD draws on
            the same tenancy limit, so walking would only produce the
            same refusal three times.
  other     Any other launch failure -- bad subnet OCID, unavailable
            image, malformed parameter.  Reported verbatim; retrying it
            anywhere would be equally wrong.
  none      No error signature in OUTPUT.

Matching is case-insensitive because the phrase reaches us both as the
human message and as the machine service code."
  (let ((text (string-downcase output)))
    (cond
     ((string-null? (string-trim-both text)) 'none)
     ;; Oracle signals exhausted capacity two ways for the same event:
     ;; the message "Out of host capacity." and the service code
     ;; "OutOfCapacity".  It arrives with HTTP 500, so the status code
     ;; alone cannot tell it from a transient server fault -- the text
     ;; is the only reliable discriminator.
     ((or (string-contains text "out of host capacity")
          (string-contains text "outofcapacity"))
      'capacity)
     ;; A quota is NOT capacity, and the distinction is the whole point:
     ;; capacity says "not here, maybe next door", a quota says "not for
     ;; you, anywhere".  Advising an AD walk for a quota error would send
     ;; the user round a loop that cannot succeed.
     ((or (string-contains text "limitexceeded")
          (string-contains text "quotaexceeded")
          (string-contains text "service limit"))
      'limit)
     ;; Everything the CLI reports as a failure says "error" somewhere:
     ;; "ServiceError:" for API refusals, "Error:"/"Usage:" for
     ;; client-side ones.  Absent that, treat OUTPUT as not-an-error
     ;; rather than guessing -- a bare OCID lands here.
     ((or (string-contains text "error")
          (string-contains text "usage:"))
      'other)
     (else 'none))))

(define (capacity-advice)
  "The text printed when EVERY availability domain reports capacity
exhaustion.  Written for someone who has never used Guix or OCI: it says
what is not broken, then the three real options in increasing order of
effort.  Returned as a string rather than printed so the offline test can
assert that all three options survive future edits."
  (string-join
   (list
    "Oracle has no free Always Free host for this shape in ANY"
    "availability domain of your home region at the moment.  This is a"
    "capacity queue, not a mistake on your part, and not a bug in this"
    "script."
    ""
    "Nothing you have built is lost.  The bucket, the uploaded object,"
    "the imported custom image and the VCN/subnet all still exist, and"
    "every step of this script looks resources up before creating them."
    "Rerunning it later resumes at the launch and duplicates nothing."
    ""
    "Three things to try, least effort first:"
    ""
    "  1. Wait, then rerun this script."
    "     Capacity is released continuously as other tenancies delete"
    "     instances, so retrying later genuinely works; people commonly"
    "     succeed within hours to a few days.  Off-peak hours for the"
    "     region are the better bet.  Do not sit in a tight retry loop:"
    "     it will not make a host appear and it can get your tenancy"
    "     rate-limited."
    ""
    "  2. Try a different region."
    "     Always Free capacity is granted in your tenancy's HOME region"
    "     only, and the home region is fixed when the tenancy is created."
    "     A region with spare capacity therefore means a new tenancy (a"
    "     new free account) whose home region you choose at signup -- not"
    "     just editing the region in ~/.oci/config."
    ""
    "  3. Try the other Always Free shape, VM.Standard.A1.Flex."
    "     The Ampere ARM shape draws on a completely separate capacity"
    "     pool, which is often free when E2.1.Micro is not."
    ""
    "     [WARN] This is NOT a flag you can add to this script.  The"
    "     image this repo builds is x86_64, and an x86_64 image will not"
    "     boot on an ARM instance -- you would need to rebuild the Guix"
    "     image for aarch64 first.  A1.Flex is also a flexible shape, so"
    "     a launch additionally needs --shape-config with an OCPU count"
    "     and a memory size, which a fixed shape does not take."
    "     Treat this as a direction to go in, not a switch to flip.")
   "\n"))

;;; ---------------------------------------------------------------------
;;; Storage + image

(define (ensure-bucket)
  (if (command-succeeds?
       (string-append %oci-cli " os bucket get --bucket-name " %bucket " >/dev/null"))
      (say "[OK] bucket " %bucket " exists")
      (begin
        (oci (string-append "os bucket create --name " %bucket
                            " --compartment-id " (compartment) " >/dev/null"))
        (say "[OK] bucket " %bucket " created"))))

(define (upload-image image-path)
  "Multipart-upload the image.  --force overwrites a previous object, so
re-deploying a rebuilt image needs no manual cleanup."
  (say "Uploading " image-path " (a few minutes)...")
  (call-with-values
      (lambda ()
        (oci/status (string-append
                     "os object put --bucket-name " %bucket
                     " --name " %object-name
                     " --file " (sh-quote image-path)
                     " --part-size 128 --parallel-upload-count 4 --force"
                     " >/dev/null")))
    (lambda (output status)
      (if (zero? status)
          (say "[OK] uploaded as " %object-name)
          (die "upload failed; rerun (multipart uploads resume poorly, "
               "but the bucket and everything before this step are kept)")))))

(define (existing-available-image)
  "OCID of an AVAILABLE custom image named guix-oracle, or #f."
  (ocid-or-false
   (oci (string-append
         "compute image list --compartment-id " (compartment)
         " --display-name " %image-name
         " --lifecycle-state AVAILABLE"
         " --query 'data[0].id' --raw-output 2>/dev/null"))))

(define (ensure-imported-image)
  "Import the uploaded object as a custom image and wait for AVAILABLE.
PARAVIRTUALIZED launch mode is NOT optional: it must match the BIOS/MBR
layout the qcow2 image type produces (NATIVE would need qcow2-gpt +
grub-efi-bootloader)."
  (or (existing-available-image)
      (let ((namespace (oci "os ns get --query data --raw-output")))
        (say "Importing as custom image (takes ~5-20 minutes)...")
        (oci (string-append
              "compute image import from-object"
              " --compartment-id " (compartment)
              " --namespace " namespace
              " --bucket-name " %bucket
              " --name " %object-name
              " --display-name " %image-name
              " --source-image-type QCOW2"
              " --launch-mode PARAVIRTUALIZED"
              " --operating-system \"Guix System\""
              " --operating-system-version rolling >/dev/null"))
        (or (poll-until "image import to reach AVAILABLE"
                        existing-available-image
                        60 3600)
            (die "image import did not reach AVAILABLE within an hour; "
                 "check Compute -> Custom Images in the console")))))

;;; ---------------------------------------------------------------------
;;; Network (the CLI equivalent of the console's "Create VCN with
;;; Internet Connectivity" wizard; the default security list already
;;; allows SSH ingress on 22)

(define (ensure-network)
  "Return the OCID of a public subnet inside a VCN with internet access."
  (let ((vcn (ocid-or-false
              (oci (string-append
                    "network vcn list --compartment-id " (compartment)
                    " --display-name " %vcn-name
                    " --query 'data[0].id' --raw-output 2>/dev/null")))))
    (if vcn
        (begin
          (say "[OK] VCN " %vcn-name " exists")
          (ocid-or-false
           (oci (string-append
                 "network subnet list --compartment-id " (compartment)
                 " --vcn-id " vcn
                 " --query 'data[0].id' --raw-output"))))
        (let* ((vcn (oci (string-append
                          "network vcn create --compartment-id " (compartment)
                          " --display-name " %vcn-name
                          " --cidr-blocks '[\"10.0.0.0/16\"]'"
                          " --query data.id --raw-output")))
               (igw (oci (string-append
                          "network internet-gateway create"
                          " --compartment-id " (compartment)
                          " --vcn-id " vcn
                          " --is-enabled true --display-name guix-igw"
                          " --query data.id --raw-output")))
               (route-table (oci (string-append
                                  "network vcn get --vcn-id " vcn
                                  " --query 'data.\"default-route-table-id\"'"
                                  " --raw-output"))))
          (oci (string-append
                "network route-table update --rt-id " route-table
                " --route-rules '[{\"destination\":\"0.0.0.0/0\","
                "\"destinationType\":\"CIDR_BLOCK\","
                "\"networkEntityId\":\"" igw "\"}]'"
                " --force >/dev/null"))
          (let ((subnet (oci (string-append
                              "network subnet create"
                              " --compartment-id " (compartment)
                              " --vcn-id " vcn
                              " --cidr-block 10.0.0.0/24"
                              " --display-name guix-public-subnet"
                              " --query data.id --raw-output"))))
            (say "[OK] created VCN, internet gateway, route, public subnet")
            subnet)))))

;;; ---------------------------------------------------------------------
;;; Instance

(define (existing-instance)
  "OCID of a RUNNING/PROVISIONING/STARTING instance named guix-oracle, or #f."
  (ocid-or-false
   (oci (string-append
         "compute instance list --compartment-id " (compartment)
         " --display-name " %instance-name
         " --query '(data[?\"lifecycle-state\"==`RUNNING`"
         " || \"lifecycle-state\"==`PROVISIONING`"
         " || \"lifecycle-state\"==`STARTING`])[0].id'"
         " --raw-output 2>/dev/null"))))

(define (availability-domains)
  "Every availability domain name in the tenancy, in the order the CLI
lists them.

Indexed one at a time with --query 'data[N].name' instead of asking for
the whole array: --raw-output un-quotes a scalar but prints a LIST as
JSON, and there is no JSON parser here by design (see the purpose file).
N+1 tiny API calls for an N of 1-3 is a fair price for keeping that rule."
  (let loop ((index 0) (found '()))
    (if (>= index %max-availability-domains)
        (reverse found)
        ;; ocid-or-false is not OCID-specific: it is the empty/\"None\"
        ;; guard every --raw-output query needs, and an out-of-range
        ;; index yields exactly that.
        (let ((name (ocid-or-false
                     (oci (string-append
                           "iam availability-domain list"
                           " --query 'data[" (number->string index) "].name'"
                           " --raw-output 2>/dev/null")))))
          (if name
              (loop (+ index 1) (cons name found))
              (reverse found))))))

(define (first-ocid-line text)
  "The first line of TEXT that looks like an OCID, or #f.
The launch below merges stderr into stdout so a failure can be
classified, which means the OCID has to be picked out of possibly noisy
output rather than assumed to be the whole string."
  (let loop ((lines (string-split text #\newline)))
    (cond ((null? lines) #f)
          ((string-prefix? "ocid1." (string-trim-both (car lines)))
           (string-trim-both (car lines)))
          (else (loop (cdr lines))))))

(define (attempt-launch availability-domain image-ocid subnet-ocid)
  "One launch attempt in AVAILABILITY-DOMAIN.  Returns two values: the
new instance OCID or #f, and the combined output for classification.
2>&1 is required -- the CLI writes ServiceError to stderr, and without it
the capacity message never reaches launch-error-kind."
  ;; No --metadata ssh_authorized_keys here, but the reason changed: it is no
  ;; longer that Guix cannot consume it.  %metadata-ssh-key-service in
  ;; image/oracle-image.scm reads that exact field at boot, so passing it WOULD
  ;; work -- and is how a published generic image is meant to be launched (see
  ;; docs/ORACLE_ONE_CLICK_ROADMAP.md steps 2-3).
  ;;
  ;; This script still relies on the baked-in key because that is what it
  ;; builds: 02-build-image.scm bakes image/authorized-key.pub, and this deploy
  ;; path has been verified end to end that way.  Adding --metadata here is
  ;; deliberately deferred until the metadata service has been confirmed on a
  ;; live instance; until then, switching to it would replace a mechanism known
  ;; to work with one that is only reasoned to work.
  (call-with-values
      (lambda ()
        (oci/status
         (string-append
          "compute instance launch"
          " --compartment-id " (compartment)
          " --availability-domain " (sh-quote availability-domain)
          " --shape " %shape
          " --image-id " image-ocid
          " --subnet-id " subnet-ocid
          " --assign-public-ip true"
          " --display-name " %instance-name
          " --query data.id --raw-output 2>&1")))
    (lambda (output status)
      (values (and (zero? status) (first-ocid-line output))
              output))))

(define (ensure-instance image-ocid subnet-ocid)
  "Launch the instance, walking past `Out of host capacity'.

BOUNDED WALK, NOT A RETRY LOOP: each availability domain is tried at
most once, in list order, and no AD is ever tried twice.  Capacity does
not reappear in seconds, so a retry loop would buy nothing and risk
rate-limiting the tenancy.  When the list runs out the script prints
advice and stops."
  (or (existing-instance)
      (let ((domains (availability-domains)))
        (when (null? domains)
          (die "no availability domains returned for this tenancy; check "
               "that ~/.oci/config names a region you are subscribed to"))
        (say "Launching " %shape " (" (number->string (length domains))
             " availability domain(s) to try)...")
        (let loop ((remaining domains) (exhausted '()))
          (if (null? remaining)
              (begin
                (say "")
                (say "[ERROR] out of host capacity in all "
                     (number->string (length exhausted))
                     " availability domain(s): "
                     (string-join (reverse exhausted) ", "))
                (say "")
                (say (capacity-advice))
                (say "")
                (exit 1))
              (let ((domain (car remaining)))
                (say "  Trying availability domain " domain " ...")
                (call-with-values
                    (lambda () (attempt-launch domain image-ocid subnet-ocid))
                  (lambda (instance-ocid output)
                    (cond
                     (instance-ocid
                      (say "[OK] launch accepted in " domain)
                      instance-ocid)
                     ((eq? (launch-error-kind output) 'capacity)
                      (say "[WARN] " domain ": no free " %shape
                           " host -- trying the next availability domain")
                      (loop (cdr remaining) (cons domain exhausted)))
                     ((eq? (launch-error-kind output) 'limit)
                      (die "launch refused by a tenancy service limit, not "
                           "by capacity.  Every availability domain draws on "
                           "the same limit, so trying another cannot help.  "
                           "Check Governance -> Limits, Quotas and Usage in "
                           "the console, and whether an old instance is still "
                           "holding your Always Free allowance.\n" output))
                     (else
                      (die "launch failed in " domain ", and not because of "
                           "capacity -- the other availability domains would "
                           "fail the same way.  The CLI said:\n" output)))))))))))

(define (wait-until-running instance-ocid)
  (or (poll-until "instance to reach RUNNING"
                  (lambda ()
                    (let ((state (oci (string-append
                                       "compute instance get --instance-id " instance-ocid
                                       " --query 'data.\"lifecycle-state\"' --raw-output"))))
                      (cond ((string=? state "RUNNING") #t)
                            ((member state '("TERMINATED" "TERMINATING"))
                             (die "instance entered " state))
                            (else #f))))
                  20 900)
      (die "instance not RUNNING after 15 minutes")))

(define (public-ip-of instance-ocid)
  (oci (string-append "compute instance list-vnics --instance-id " instance-ocid
                      " --query 'data[0].\"public-ip\"' --raw-output")))

(define (wait-for-ssh-banner ip)
  "sshd answering proves boot completed.  `Permission denied (publickey)'
is the SUCCESS signature here -- see the header comment."
  (or (poll-until (string-append "sshd on " ip ":22")
                  (lambda ()
                    (let ((probe (run-command
                                  (string-append
                                   "ssh -o BatchMode=yes -o StrictHostKeyChecking=no"
                                   " -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
                                   " probe@" ip " true 2>&1"))))
                      (and (string-contains probe "denied") #t)))
                  20 600)
      (die "no SSH banner after 10 minutes; use the OCI serial console "
           "(Instance -> Console connection) -- the image mirrors GRUB "
           "and login onto ttyS0 for exactly this")))

;;; ---------------------------------------------------------------------

(define (main)
  (unless (oci-authenticated?)
    (die "oci CLI is not set up; run 01-setup-client.scm first"))
  (let ((image-path
         (if (> (length (command-line)) 1)
             (cadr (command-line))
             (die "usage: 04-deploy.scm /gnu/store/...-image.qcow2  "
                  "(the path printed by 02-build-image.scm; run "
                  "03-smoke-test.scm on it first)"))))
    (unless (file-exists? image-path)
      (die image-path " does not exist"))
    (ensure-bucket)
    (if (existing-available-image)
        (say "[OK] custom image already imported (delete it in the console "
             "to force a re-import of a rebuilt qcow2)")
        (upload-image image-path))
    (let* ((image-ocid (ensure-imported-image))
           (subnet-ocid (ensure-network))
           (instance-ocid (ensure-instance image-ocid subnet-ocid)))
      (wait-until-running instance-ocid)
      (let ((ip (public-ip-of instance-ocid)))
        (wait-for-ssh-banner ip)
        (say "")
        (say "[OK] Guix System is RUNNING on Oracle Cloud")
        (say "")
        (say "    ssh guix@" ip)
        (say "")
        (say "(uses the key baked at oracle/image/authorized-key.pub;")
        (say " you will be asked for that key's passphrase, if it has one)")
        (say "")
        (say "Before your first guix system reconfigure on the instance,")
        (say "confirm with lsblk that the boot volume is /dev/sda, matching")
        (say "(targets ...) in oracle/image/oracle-image.scm.  (Observed sda")
        (say "on VM.Standard.E2.1.Micro PARAVIRTUALIZED, 2026-08-08; only a")
        (say "different shape or launch mode should change it.)")))))

(main)
