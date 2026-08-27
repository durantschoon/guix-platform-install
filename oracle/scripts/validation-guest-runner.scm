#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; validation-guest-runner.scm --- durable sequenced telemetry on the guest.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1))

(define (die text)
  (display "[ERROR] ") (display text) (newline) (exit 2))

(define (json-escape text)
  (list->string
   (append-map
    (lambda (c)
      (cond ((char=? c #\\) (string->list "\\\\"))
            ((char=? c #\") (string->list "\\\""))
            ((char=? c #\newline) (string->list "\\n"))
            ((char=? c #\return) (string->list "\\r"))
            ((char=? c #\tab) (string->list "\\t"))
            ((< (char->integer c) 32)
             (string->list (format #f "\\u~4,'0x" (char->integer c))))
            (else (list c))))
    (string->list text))))

(define (utc-now)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (sh-quote text)
  (string-append "'" (string-join (string-split text #\') "'\\''") "'"))

(define (main args)
  (unless (= (length args) 5)
    (die "usage: validation-guest-runner.scm JOURNAL RESULT COMMAND-FILE TIMEOUT MAX-OUTPUT-BYTES"))
  (let* ((journal-path (list-ref args 0))
         (result-path (list-ref args 1))
         (command-path (list-ref args 2))
         (timeout-text (list-ref args 3))
         (timeout (string->number timeout-text))
         (output-limit-text (list-ref args 4))
         (output-limit (string->number output-limit-text))
         (child-result-path (string-append result-path ".child"))
         (shell (or (getenv "VALIDATION_GUEST_SHELL")
                    "/run/current-system/profile/bin/sh"))
         (heartbeat-seconds
          (let ((value (and (getenv "VALIDATION_HEARTBEAT_SECONDS")
                            (string->number (getenv "VALIDATION_HEARTBEAT_SECONDS")))))
            (if (and value (integer? value) (> value 0)) value 10)))
         (journal (open-file journal-path "a"))
         (sequence 0)
         (retained-bytes 0)
         (truncation-recorded? #f)
         (last-heartbeat (current-time)))
    (define (event kind payload)
      (set! sequence (+ sequence 1))
      (format journal
              "{\"seq\":~a,\"kind\":\"~a\",\"timestamp\":\"~a\",\"payload\":\"~a\"}~%"
              sequence (json-escape kind) (utc-now) (json-escape payload))
      (force-output journal))
    (define (heartbeat-if-due)
      (when (>= (- (current-time) last-heartbeat) heartbeat-seconds)
        (event "heartbeat" "command running")
        (set! last-heartbeat (current-time))))
    (define (output-event text)
      "Retain at most OUTPUT-LIMIT bytes and explicitly mark incomplete output."
      (let* ((remaining (- output-limit retained-bytes))
             (length (string-length text)))
        (when (> remaining 0)
          (let ((kept (if (> length remaining) (substring text 0 remaining) text)))
            (event "output" kept)
            (set! retained-bytes (+ retained-bytes (string-length kept)))))
        (when (and (> length remaining) (not truncation-recorded?))
          (event "output-truncated"
                 (string-append "byte_limit=" output-limit-text
                                ";full_output_path=none"))
          (set! truncation-recorded? #t))))
    (unless (and timeout (integer? timeout) (> timeout 0))
      (die "TIMEOUT must be a positive integer"))
    (unless (and output-limit (integer? output-limit) (> output-limit 0))
      (die "MAX-OUTPUT-BYTES must be a positive integer"))
    (event "started" command-path)
    (when (file-exists? child-result-path) (delete-file child-result-path))
    (let* ((command (string-append
                     "timeout " timeout-text " " shell " " (sh-quote command-path) " 2>&1"
                     "; child_status=$?; printf '%s\\n' \"$child_status\" > "
                     (sh-quote child-result-path)))
           (input (open-input-pipe command)))
      (define (finish buffer)
        (let* ((text (list->string (reverse buffer)))
               (status-text (call-with-input-file child-result-path read-line))
               (status (or (string->number status-text) 255)))
          (unless (string-null? text) (output-event text))
          (close-pipe input)
          (event "result" (number->string status))
          (call-with-output-file result-path
            (lambda (port) (display status port) (newline port)))
          (delete-file child-result-path)
          (close-port journal)
          (exit status)))
      (let loop ((buffer '()))
        (cond
         ((char-ready? input)
          (let ((c (read-char input)))
            (if (eof-object? c)
                (finish buffer)
                (if (or (char=? c #\newline) (>= (length buffer) 4095))
                    (begin
                      (output-event (list->string (reverse (cons c buffer))))
                      (loop '()))
                    (loop (cons c buffer))))))
         (else
          (if (file-exists? child-result-path)
              (finish buffer)
              (begin
                (heartbeat-if-due)
                (usleep 250000)
                (loop buffer)))))))))

(main (cdr (command-line)))
