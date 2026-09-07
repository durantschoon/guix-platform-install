package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/durantschoon/guix-platform-install/internal/sshwait"
)

func parseDotEnv(path string) map[string]string {
	result := make(map[string]string)
	file, err := os.Open(path)
	if err != nil {
		return result
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			k := strings.TrimSpace(parts[0])
			v := strings.Trim(strings.TrimSpace(parts[1]), "\"'")
			result[k] = v
		}
	}
	return result
}

func resolvePublicIPFromOCI(instanceID string) (string, error) {
	ociPath, err := exec.LookPath("oci")
	if err != nil {
		return "", fmt.Errorf("oci CLI not found in PATH: %w", err)
	}

	cmd := exec.Command(ociPath, "compute", "instance", "list-vnics",
		"--instance-id", instanceID,
		"--query", `data[0]."public-ip"`,
		"--raw-output")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("oci list-vnics failed: %w", err)
	}
	ip := strings.TrimSpace(string(out))
	if ip == "" || ip == "null" {
		return "", fmt.Errorf("no public IP found on instance %s", instanceID)
	}
	return ip, nil
}

func main() {
	ipFlag := flag.String("ip", "", "Target instance IP or hostname")
	userFlag := flag.String("user", "guix", "SSH username")
	portFlag := flag.String("port", "22", "SSH port")
	keyFlag := flag.String("key", "", "Path to SSH private key identity file")
	instanceIDFlag := flag.String("instance-id", "", "OCI Instance OCID (to resolve public IP via OCI CLI)")
	waitFlag := flag.Bool("wait", true, "Wait for instance SSH daemon and key authorization with animated progress")
	waitTimeoutSec := flag.Int("wait-timeout", 300, "Maximum seconds to wait for SSH readiness")
	bannerOnlyFlag := flag.Bool("banner-only", false, "Wait only for SSH banner, skip key authentication probe")
	skipCheck := flag.Bool("skip-check", false, "Skip SSH readiness check and connect immediately")
	timeoutSec := flag.Int("timeout", 4, "TCP port check timeout in seconds (when wait=false)")

	flag.Parse()

	targetHost := *ipFlag
	targetUser := *userFlag
	targetPort := *portFlag
	instanceID := *instanceIDFlag
	extraArgs := flag.Args()

	// If positional arg is present and targetHost is empty, first arg is the host
	if targetHost == "" && len(extraArgs) > 0 {
		targetHost = extraArgs[0]
		extraArgs = extraArgs[1:]
	}

	// Try reading .env file if available
	envMap := make(map[string]string)
	for _, envPath := range []string{".env", "../.env"} {
		if _, err := os.Stat(envPath); err == nil {
			envMap = parseDotEnv(envPath)
			break
		}
	}

	// Environment variable / .env fallbacks for target host
	if targetHost == "" {
		if envIP := os.Getenv("ORACLE_INSTANCE_IP"); envIP != "" {
			targetHost = envIP
		} else if envHost := os.Getenv("ORACLE_HOST"); envHost != "" {
			targetHost = envHost
		} else if val, ok := envMap["ORACLE_INSTANCE_IP"]; ok && val != "" {
			targetHost = val
		} else if val, ok := envMap["ORACLE_HOST"]; ok && val != "" {
			targetHost = val
		}
	}

	// Instance ID fallback
	if instanceID == "" {
		if envInst := os.Getenv("ORACLE_INSTANCE_ID"); envInst != "" {
			instanceID = envInst
		} else if envInst := os.Getenv("INSTANCE_ID"); envInst != "" {
			instanceID = envInst
		} else if val, ok := envMap["ORACLE_INSTANCE_ID"]; ok && val != "" {
			instanceID = val
		} else if val, ok := envMap["INSTANCE_ID"]; ok && val != "" {
			instanceID = val
		}
	}

	// If targetHost is still empty but instanceID is known, query OCI
	if targetHost == "" && instanceID != "" {
		fmt.Printf("[INFO]  Querying OCI CLI for public IP of instance: %s...\n", instanceID)
		resolvedIP, err := resolvePublicIPFromOCI(instanceID)
		if err != nil {
			fmt.Printf("[WARN]  Could not resolve IP from OCI: %v\n", err)
		} else {
			targetHost = resolvedIP
			fmt.Printf("[OK]    Resolved instance public IP: %s\n", targetHost)
		}
	}

	if targetHost == "" {
		fmt.Println("[ERROR] No target IP or hostname provided.")
		fmt.Println("        Specify via:")
		fmt.Println("          make ssh IP=<public-ip>")
		fmt.Println("          go run ./cmd/oracle-ssh <public-ip>")
		fmt.Println("        or set ORACLE_INSTANCE_IP in .env")
		os.Exit(1)
	}

	const dedicatedSSHKeyName = "id_ed25519_guix_oracle"

	resolvedKey := *keyFlag
	if resolvedKey == "" {
		if envKey := os.Getenv("ORACLE_SSH_KEY"); envKey != "" {
			resolvedKey = envKey
		} else if envKey := os.Getenv("KEY"); envKey != "" {
			resolvedKey = envKey
		} else if val, ok := envMap["ORACLE_SSH_KEY"]; ok && val != "" {
			resolvedKey = val
		} else if val, ok := envMap["KEY"]; ok && val != "" {
			resolvedKey = val
		} else if home, err := os.UserHomeDir(); err == nil {
			dedicatedPath := filepath.Join(home, ".ssh", dedicatedSSHKeyName)
			if _, err := os.Stat(dedicatedPath); err == nil {
				resolvedKey = dedicatedPath
			}
		}
	}

	if resolvedKey != "" && strings.HasPrefix(resolvedKey, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			resolvedKey = filepath.Join(home, resolvedKey[2:])
		}
	}

	// Pre-flight readiness check / waiting
	if !*skipCheck {
		if *waitFlag {
			cfg := sshwait.WaitConfig{
				User:        targetUser,
				Host:        targetHost,
				Port:        targetPort,
				KeyPath:     resolvedKey,
				Timeout:     time.Duration(*waitTimeoutSec) * time.Second,
				SkipKeyAuth: *bannerOnlyFlag,
			}
			if err := sshwait.WaitForSSH(cfg); err != nil {
				if errors.Is(err, sshwait.ErrInterrupted) {
					os.Exit(130)
				}
				if errors.Is(err, sshwait.ErrTimeout) {
					fmt.Print("\nAttempt interactive SSH connection anyway? [y/N]: ")
					scanner := bufio.NewScanner(os.Stdin)
					if scanner.Scan() {
						resp := strings.TrimSpace(scanner.Text())
						if strings.ToLower(resp) != "y" && strings.ToLower(resp) != "yes" {
							os.Exit(1)
						}
					} else {
						os.Exit(1)
					}
				}
			}
		} else {
			timeout := time.Duration(*timeoutSec) * time.Second
			fmt.Printf("[INFO]  Checking reachability of %s:%s...\n", targetHost, targetPort)
			if err := sshwait.CheckPortReachability(targetHost, targetPort, timeout); err != nil {
				fmt.Printf("[WARN]  Port %s on %s is unreachable: %v\n", targetPort, targetHost, err)
				fmt.Println("        Attempting SSH connection anyway...")
			} else {
				fmt.Printf("[OK]    %s:%s is reachable.\n", targetHost, targetPort)
			}
		}
	}

	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		fmt.Printf("[ERROR] ssh command not found in PATH: %v\n", err)
		os.Exit(1)
	}

	destination := fmt.Sprintf("%s@%s", targetUser, targetHost)
	sshArgs := []string{
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=15",
		"-o", "ServerAliveInterval=30",
		"-o", "ServerAliveCountMax=3",
	}

	if targetPort != "22" {
		sshArgs = append(sshArgs, "-p", targetPort)
	}

	if resolvedKey != "" {
		sshArgs = append(sshArgs, "-i", resolvedKey)
	}

	sshArgs = append(sshArgs, destination)
	if len(extraArgs) > 0 {
		sshArgs = append(sshArgs, extraArgs...)
	}

	fmt.Printf("[INFO]  Connecting: ssh %s\n", strings.Join(sshArgs, " "))

	cmd := exec.Command(sshPath, sshArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Printf("[ERROR] SSH failed: %v\n", err)
		os.Exit(1)
	}
}
