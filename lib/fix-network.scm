#!/run/current-system/profile/bin/guile \
--no-auto-compile
!#
;;; Script to fix network configuration on fresh Guix install
;;; Run this on the installed Guix system

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1))

(define (run-command cmd)
  "Run a shell command and return the output as a string."
  (let* ((port (open-input-pipe cmd))
         (output (read-string port)))
    (close-pipe port)
    output))

(define (command-exists? cmd)
  "Check if a command exists in PATH."
  (zero? (system* "which" cmd)))

(define (display-section title)
  "Display a section header."
  (newline)
  (display title)
  (newline))

(define (check-network-interfaces)
  "Check and display network interfaces."
  (display-section "1. Checking network interfaces:")
  (cond
   ((command-exists? "ip")
    (display (run-command "ip addr show 2>/dev/null")))
   ((command-exists? "ifconfig")
    (display (run-command "ifconfig 2>/dev/null")))
   (else
    (display "  Network tools not available\n"))))

(define (check-network-services)
  "Check and display network services status."
  (display-section "2. Checking network services:")
  (let ((herd-output (run-command "herd status 2>/dev/null | grep -E '(network|dhcp|NetworkManager)'")))
    (if (string-null? herd-output)
        (let ((systemctl-output (run-command "systemctl list-units --type=service 2>/dev/null | grep -E '(network|dhcp|NetworkManager)'")))
          (if (string-null? systemctl-output)
              (display "  No network services found\n")
              (display systemctl-output)))
        (display herd-output))))

(define (start-network-manager)
  "Attempt to start NetworkManager service."
  (display-section "3. Checking if we can start NetworkManager:")
  (let ((herd-status (run-command "herd status network-manager 2>/dev/null")))
    (if (not (string-null? herd-status))
        (begin
          (display "  NetworkManager service exists\n")
          (display "  Attempting to start...\n")
          (system* "herd" "start" "network-manager")
          (system* "sleep" "3")
          (display (run-command "herd status network-manager")))
        (let ((systemctl-check (run-command "systemctl list-unit-files 2>/dev/null | grep -q network-manager; echo $?")))
          (if (string=? (string-trim-right systemctl-check) "0")
              (begin
                (display "  NetworkManager unit file exists\n")
                (system* "systemctl" "start" "NetworkManager")
                (system* "sleep" "3")
                (display (run-command "systemctl status NetworkManager")))
              (display "  NetworkManager not found\n"))))))

(define (try-dhcp)
  "Try to start DHCP client."
  (display-section "4. Checking if we can use dhcpcd:")
  (cond
   ((command-exists? "dhcpcd")
    (display "  dhcpcd is available\n")
    (display "  Attempting to start DHCP on all interfaces...\n")
    (display (run-command "dhcpcd -n 2>&1 | head -10")))
   ((command-exists? "dhclient")
    (display "  dhclient is available\n")
    (display "  Finding network interfaces...\n")
    (display (run-command "ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | sed 's/:$//' | head -3")))
   (else
    (display "  No DHCP client found\n"))))

(define (show-manual-instructions)
  "Display manual configuration instructions."
  (display-section "5. Manual network configuration (if needed):")
  (display "  If automatic configuration doesn't work, try:\n")
  (display "  - For VPS: Usually eth0 or ens3 or enp0s3\n")
  (display "  - Start DHCP manually: dhcpcd eth0\n")
  (display "  - Or configure static IP: ip addr add IP_ADDRESS dev eth0\n")

  (display-section "6. After network is up, test connectivity:")
  (display "  ping -c 2 1.1.1.1\n")
  (display "  ping -c 2 8.8.8.8\n"))

(define (main)
  "Main entry point for network fix script."
  (display "=== Network Configuration Fix ===\n")
  (check-network-interfaces)
  (check-network-services)
  (start-network-manager)
  (try-dhcp)
  (show-manual-instructions)
  (newline)
  (display "=== Network Fix Complete ===\n")
  (newline))

;; Run the main function
(main)
