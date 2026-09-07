package sshwait

import (
	"bufio"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"
)

// CheckPortReachability tests whether a TCP connection can be established to host:port.
func CheckPortReachability(host, port string, timeout time.Duration) error {
	address := net.JoinHostPort(host, port)
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return err
	}
	_ = conn.Close()
	return nil
}

// ProbeSSHBanner connects to host:port and attempts to read the initial SSH identification string.
// An OpenSSH server emits this string (e.g. "SSH-2.0-OpenSSH_9.0") immediately upon accept.
func ProbeSSHBanner(host, port string, timeout time.Duration) (string, error) {
	address := net.JoinHostPort(host, port)
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return "", err
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return "", err
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}

	line = strings.TrimSpace(line)
	if strings.HasPrefix(line, "SSH-") {
		return line, nil
	}
	return line, fmt.Errorf("unexpected banner signature: %q", line)
}

// ProbeSSHAuth performs a non-interactive SSH test using BatchMode.
// It returns (success, combinedOutput, error).
// Success (true) means publickey authentication was accepted and remote execution works.
func ProbeSSHAuth(user, host, port, keyPath string, timeoutSec int) (bool, string, error) {
	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		return false, "", fmt.Errorf("ssh binary not found in PATH: %w", err)
	}

	args := []string{
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", fmt.Sprintf("ConnectTimeout=%d", timeoutSec),
	}
	if port != "" && port != "22" {
		args = append(args, "-p", port)
	}
	if keyPath != "" {
		args = append(args, "-i", keyPath)
	}
	destination := fmt.Sprintf("%s@%s", user, host)
	args = append(args, destination, "true")

	cmd := exec.Command(sshPath, args...)
	out, err := cmd.CombinedOutput()
	outputStr := strings.TrimSpace(string(out))

	if err == nil {
		return true, outputStr, nil
	}
	return false, outputStr, err
}
