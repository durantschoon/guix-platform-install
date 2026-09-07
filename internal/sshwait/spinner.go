package sshwait

import (
	"fmt"
	"os"
	"sync"
	"time"
)

// Spinner displays a live ASCII terminal spinner with elapsed time.
type Spinner struct {
	mu       sync.Mutex
	message  string
	stopChan chan struct{}
	doneChan chan struct{}
	active   bool
	isTTY    bool
	start    time.Time
}

// isTerminal checks whether stdout is a character device (interactive terminal).
func isTerminal() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

// NewSpinner creates a new ASCII spinner with an initial message.
func NewSpinner(message string) *Spinner {
	return &Spinner{
		message: message,
		isTTY:   isTerminal(),
	}
}

// Start begins the animated spinner in a background goroutine.
func (s *Spinner) Start() {
	s.mu.Lock()
	if s.active {
		s.mu.Unlock()
		return
	}
	s.active = true
	s.stopChan = make(chan struct{})
	s.doneChan = make(chan struct{})
	s.start = time.Now()
	s.mu.Unlock()

	frames := []rune{'|', '/', '-', '\\'}

	go func() {
		defer close(s.doneChan)
		ticker := time.NewTicker(120 * time.Millisecond)
		defer ticker.Stop()

		var lastNonTTY time.Time
		frameIdx := 0

		for {
			select {
			case <-s.stopChan:
				if s.isTTY {
					// Clear the spinner line completely
					fmt.Print("\r\033[K")
				}
				return
			case now := <-ticker.C:
				elapsed := int(now.Sub(s.start).Seconds())
				s.mu.Lock()
				msg := s.message
				s.mu.Unlock()

				if s.isTTY {
					f := frames[frameIdx%len(frames)]
					frameIdx++
					fmt.Printf("\r[ %c ] %s (%ds)   ", f, msg, elapsed)
				} else {
					if now.Sub(lastNonTTY) >= 10*time.Second {
						lastNonTTY = now
						fmt.Printf("[INFO]  ... %s (%ds)\n", msg, elapsed)
					}
				}
			}
		}
	}()
}

// UpdateMessage updates the displayed message without stopping the spinner.
func (s *Spinner) UpdateMessage(newMsg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.message = newMsg
}

// Stop stops the spinner and clears its terminal line if on a TTY.
func (s *Spinner) Stop() {
	s.mu.Lock()
	if !s.active {
		s.mu.Unlock()
		return
	}
	s.active = false
	close(s.stopChan)
	s.mu.Unlock()
	<-s.doneChan
}

// StopWithSuccess stops the spinner and prints an [OK] message.
func (s *Spinner) StopWithSuccess(format string, args ...interface{}) {
	s.Stop()
	fmt.Printf("[OK]    "+format+"\n", args...)
}

// StopWithWarning stops the spinner and prints a [WARN] message.
func (s *Spinner) StopWithWarning(format string, args ...interface{}) {
	s.Stop()
	fmt.Printf("[WARN]  "+format+"\n", args...)
}

// StopWithError stops the spinner and prints an [ERROR] message.
func (s *Spinner) StopWithError(format string, args ...interface{}) {
	s.Stop()
	fmt.Printf("[ERROR] "+format+"\n", args...)
}
