package sshwait

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

func TestSpinnerLifecycle(t *testing.T) {
	s := NewSpinner("Testing spinner")
	s.Start()
	time.Sleep(150 * time.Millisecond)
	s.UpdateMessage("Updated message")
	time.Sleep(150 * time.Millisecond)
	s.Stop()

	// Calling Stop again should be safe and idempotent
	s.Stop()
}

func TestCheckPortReachability(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to create listener: %v", err)
	}
	defer listener.Close()

	_, portStr, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatalf("Failed to split host port: %v", err)
	}

	// Port should be reachable
	if err := CheckPortReachability("127.0.0.1", portStr, 1*time.Second); err != nil {
		t.Errorf("Expected port to be reachable, got: %v", err)
	}

	// Unused port should fail
	if err := CheckPortReachability("127.0.0.1", "1", 100*time.Millisecond); err == nil {
		t.Errorf("Expected connection to port 1 to fail, got nil")
	}
}

func TestProbeSSHBanner(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to create listener: %v", err)
	}
	defer listener.Close()

	_, portStr, _ := net.SplitHostPort(listener.Addr().String())

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = fmt.Fprintf(conn, "SSH-2.0-OpenSSH_9.9p1 Debian\r\n")
			_ = conn.Close()
		}
	}()

	banner, err := ProbeSSHBanner("127.0.0.1", portStr, 1*time.Second)
	if err != nil {
		t.Fatalf("ProbeSSHBanner failed: %v", err)
	}
	if !strings.HasPrefix(banner, "SSH-2.0-OpenSSH") {
		t.Errorf("Unexpected banner content: %q", banner)
	}
}

func TestWaitForSSH_BannerOnly(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to create listener: %v", err)
	}
	defer listener.Close()

	_, portStr, _ := net.SplitHostPort(listener.Addr().String())

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = fmt.Fprintf(conn, "SSH-2.0-OpenSSH_9.9p1\r\n")
			_ = conn.Close()
		}
	}()

	cfg := WaitConfig{
		Host:        "127.0.0.1",
		Port:        portStr,
		Timeout:     5 * time.Second,
		SkipKeyAuth: true,
	}

	if err := WaitForSSH(cfg); err != nil {
		t.Errorf("WaitForSSH banner-only failed: %v", err)
	}
}
