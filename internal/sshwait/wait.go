package sshwait

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

var (
	// ErrInterrupted indicates the user cancelled waiting with SIGINT (Ctrl+C).
	ErrInterrupted = errors.New("operation cancelled by user")
	// ErrTimeout indicates the deadline expired before SSH was ready.
	ErrTimeout = errors.New("timed out waiting for SSH")
)

// WaitConfig configures the multi-stage SSH readiness waiter.
type WaitConfig struct {
	User        string
	Host        string
	Port        string
	KeyPath     string
	Timeout     time.Duration
	SkipKeyAuth bool
}

// WaitForSSH coordinates the multi-stage waiting process with animated ASCII feedback.
// Stages:
//  1. TCP port reachability (proves VM network and OCI security list ingress).
//  2. SSH protocol banner (proves VM kernel booted and sshd process started).
//  3. Public key authentication (proves OCI metadata service injected authorized_keys).
func WaitForSSH(cfg WaitConfig) error {
	if cfg.Port == "" {
		cfg.Port = "22"
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Minute
	}

	deadline := time.Now().Add(cfg.Timeout)

	// Intercept Ctrl+C so we can restore the terminal cleanly
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigChan)

	isInterrupted := func() bool {
		select {
		case <-sigChan:
			return true
		default:
			return false
		}
	}

	// -------------------------------------------------------------
	// Stage 1: TCP Port Reachability
	// -------------------------------------------------------------
	spinner := NewSpinner(fmt.Sprintf("Checking port %s reachability on %s...", cfg.Port, cfg.Host))
	spinner.Start()

	stage1Start := time.Now()
	var portConnected bool

	for {
		if isInterrupted() {
			spinner.Stop()
			fmt.Println("\n[WARN]  Cancelled by user.")
			return ErrInterrupted
		}
		if time.Now().After(deadline) {
			spinner.Stop()
			fmt.Printf("[ERROR] Timed out waiting for port %s on %s after %v.\n", cfg.Port, cfg.Host, cfg.Timeout)
			return ErrTimeout
		}

		err := CheckPortReachability(cfg.Host, cfg.Port, 2*time.Second)
		if err == nil {
			portConnected = true
			break
		}

		if time.Since(stage1Start) > 8*time.Second {
			spinner.UpdateMessage(fmt.Sprintf("Waiting for port %s on %s to open (OCI Security List / provisioning)...", cfg.Port, cfg.Host))
		}

		time.Sleep(1 * time.Second)
	}

	if portConnected {
		spinner.StopWithSuccess("Port %s is open on %s.", cfg.Port, cfg.Host)
	}

	// -------------------------------------------------------------
	// Stage 2: SSH Daemon Banner
	// -------------------------------------------------------------
	fmt.Println("[INFO]  Waiting for SSH daemon to respond...")
	fmt.Println("        (Note: First boot creates a 2GB swapfile and initializes services, ~2-3 mins)")

	spinner = NewSpinner("Waiting for SSH daemon banner...")
	spinner.Start()

	var banner string
	for {
		if isInterrupted() {
			spinner.Stop()
			fmt.Println("\n[WARN]  Cancelled by user.")
			return ErrInterrupted
		}
		if time.Now().After(deadline) {
			spinner.Stop()
			fmt.Printf("[ERROR] Timed out waiting for SSH banner on %s:%s.\n", cfg.Host, cfg.Port)
			fmt.Println("        The VM may be experiencing slow I/O or a boot halt.")
			fmt.Println("        Inspect OCI Console:")
			fmt.Println("          - More actions -> Boot diagnostics -> Capture screenshot")
			fmt.Println("          - More actions -> Create console connection -> Launch Cloud Shell")
			return ErrTimeout
		}

		b, err := ProbeSSHBanner(cfg.Host, cfg.Port, 3*time.Second)
		if err == nil {
			banner = b
			break
		}

		time.Sleep(1 * time.Second)
	}

	spinner.StopWithSuccess("SSH daemon is responding (%s).", banner)

	if cfg.SkipKeyAuth {
		return nil
	}

	// -------------------------------------------------------------
	// Stage 3: SSH Key Authentication Probe
	// -------------------------------------------------------------
	fmt.Println("[INFO]  Verifying SSH public key authentication...")

	spinner = NewSpinner("Verifying SSH key authentication...")
	spinner.Start()

	for {
		if isInterrupted() {
			spinner.Stop()
			fmt.Println("\n[WARN]  Cancelled by user.")
			return ErrInterrupted
		}
		if time.Now().After(deadline) {
			spinner.Stop()
			fmt.Printf("[WARN]  SSH key was not accepted within %v.\n", cfg.Timeout)
			fmt.Println("        Check whether the public key matches the key pasted in OCI Console.")
			return ErrTimeout
		}

		ok, out, _ := ProbeSSHAuth(cfg.User, cfg.Host, cfg.Port, cfg.KeyPath, 4)
		if ok {
			spinner.StopWithSuccess("SSH key authentication verified!")
			return nil
		}

		if strings.Contains(out, "Permission denied") {
			spinner.UpdateMessage("Waiting for OCI metadata service to install SSH key...")
		}

		time.Sleep(2 * time.Second)
	}
}
