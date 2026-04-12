// Package gobridge provides a gomobile-compatible bridge to Tailscale's tsnet,
// allowing an Android app to join a tailnet and proxy TCP connections through it
// without requiring the standalone Tailscale VPN app.
package gobridge

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	stdnet "net"
	"net/netip"

	_ "golang.org/x/mobile/bind" // Required by gomobile
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

var interfaceGetterRegistered bool

// findURL returns the index of prefix in s, or -1 if not found.
func findURL(s, prefix string) int {
	return strings.Index(s, prefix)
}

// extractURL extracts a URL starting at idx from s (up to the next whitespace).
func extractURL(s string, idx int) string {
	sub := s[idx:]
	if end := strings.IndexAny(sub, " \t\n\r"); end >= 0 {
		return sub[:end]
	}
	return sub
}

// StatusCallback receives lifecycle events from the Tailscale bridge.
// gomobile generates a Java/Kotlin interface from this.
type StatusCallback interface {
	OnAuthURL(url string)
	OnConnected()
	OnError(err string)
}

var (
	mu       sync.Mutex
	server   *tsnet.Server
	listener net.Listener
	cancel   context.CancelFunc
	running  bool
)

// Start initializes the tsnet server and begins connecting to the tailnet.
// stateDir is a writable directory for persisting Tailscale node state.
// hostname is the name this device will appear as on the tailnet.
// cb receives auth/connection/error events on a background goroutine.
func Start(stateDir string, hostname string, cb StatusCallback) {
	mu.Lock()

	if !interfaceGetterRegistered {
		// Android apps can't use netlink to list interfaces without elevated
		// permissions. Register a getter that returns a synthetic interface
		// with AltAddrs set, so tsnet knows the network is available without
		// calling the OS (which would fail with netlinkrib permission denied).
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			return []netmon.Interface{
				{
					Interface: &stdnet.Interface{
						Index: 1,
						MTU:   1500,
						Name:  "wlan0",
						Flags: stdnet.FlagUp | stdnet.FlagMulticast | stdnet.FlagBroadcast,
					},
					AltAddrs: []stdnet.Addr{
						&stdnet.IPNet{
							IP:   stdnet.IPv4(192, 168, 1, 100),
							Mask: stdnet.CIDRMask(24, 32),
						},
					},
				},
			}, nil
		})
		// Also set the default route interface so netmon doesn't try netlink.
		netmon.UpdateLastKnownDefaultRouteInterface("wlan0")
		_ = netip.Addr{} // ensure import is used
		// Set env vars so Tailscale's logpolicy can find writable locations.
		// logpolicy checks STATE_DIRECTORY (systemd), HOME (UserCacheDir),
		// and current dir. On Android none of these are set by default.
		os.Setenv("STATE_DIRECTORY", stateDir)
		os.Setenv("HOME", stateDir)
		os.Setenv("TMPDIR", stateDir)
		interfaceGetterRegistered = true
	}

	if server != nil {
		mu.Unlock()
		cb.OnError("already started")
		return
	}

	srv := &tsnet.Server{
		Hostname:  hostname,
		Dir:       stateDir,
		Ephemeral: false,
		Logf:      log.Printf,
	}
	server = srv
	mu.Unlock()

	go func() {
		ctx, c := context.WithCancel(context.Background())
		mu.Lock()
		cancel = c
		mu.Unlock()

		// Capture auth URLs from tsnet's log output.
		// tsnet logs "To authenticate, visit: <url>" when auth is needed.
		authURLSent := false
		srv.Logf = func(format string, a ...any) {
			msg := fmt.Sprintf(format, a...)
			log.Print(msg)
			if !authURLSent {
				// tsnet logs the auth URL in a message containing "https://login.tailscale.com/"
				if idx := findURL(msg, "https://login.tailscale.com/"); idx >= 0 {
					url := extractURL(msg, idx)
					if url != "" {
						authURLSent = true
						cb.OnAuthURL(url)
					}
				}
			}
		}

		_, err := srv.Up(ctx)
		if err != nil {
			cb.OnError(fmt.Sprintf("tsnet up: %v", err))
			cleanup()
			return
		}
		mu.Lock()
		running = true
		mu.Unlock()
		cb.OnConnected()
	}()
}

// StartProxy opens a TCP listener on localhost that proxies connections
// to targetIP:targetPort through the tsnet connection.
// Returns the local port number. Blocks until the listener is ready.
func StartProxy(targetIP string, targetPort int) (int, error) {
	mu.Lock()
	srv := server
	if srv == nil || !running {
		mu.Unlock()
		return 0, fmt.Errorf("tsnet not started or not connected")
	}
	// Close any existing proxy listener.
	if listener != nil {
		listener.Close()
		listener = nil
	}
	mu.Unlock()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("listen: %w", err)
	}

	mu.Lock()
	listener = ln
	mu.Unlock()

	port := ln.Addr().(*net.TCPAddr).Port
	target := fmt.Sprintf("%s:%d", targetIP, targetPort)

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // Listener closed.
			}
			go proxy(srv, conn, target)
		}
	}()

	return port, nil
}

func proxy(srv *tsnet.Server, local net.Conn, target string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	remote, err := srv.Dial(ctx, "tcp", target)
	if err != nil {
		local.Close()
		log.Printf("gobridge: dial %s: %v", target, err)
		return
	}

	go func() {
		io.Copy(remote, local)
		remote.Close()
	}()
	io.Copy(local, remote)
	local.Close()
}

// StopProxy closes the proxy listener. Existing proxied connections
// continue until they close naturally.
func StopProxy() {
	mu.Lock()
	defer mu.Unlock()
	if listener != nil {
		listener.Close()
		listener = nil
	}
}

// Stop shuts down the tsnet server entirely.
func Stop() {
	StopProxy()
	mu.Lock()
	defer mu.Unlock()
	if cancel != nil {
		cancel()
		cancel = nil
	}
	if server != nil {
		server.Close()
		server = nil
	}
	running = false
}

// IsRunning returns whether tsnet is connected to the tailnet.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}

func cleanup() {
	mu.Lock()
	defer mu.Unlock()
	if server != nil {
		server.Close()
		server = nil
	}
	running = false
}
