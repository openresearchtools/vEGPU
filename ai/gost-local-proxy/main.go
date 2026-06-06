package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type stateFile struct {
	Forwards []forward `json:"forwards"`
}

type forward struct {
	MacHost   string `json:"macHost"`
	MacPort   int    `json:"macPort"`
	VMPort    int    `json:"vmPort"`
	Protocol  string `json:"protocol"`
	Direction string `json:"direction,omitempty"`
}

type managedForward struct {
	forward
	key        string
	bindHost   string
	bindPort   int
	targetHost string
	targetPort int
}

type stopper interface {
	stop()
}

type supervisor struct {
	portsFile string
	bindHost  string
	target    string
	gateway   string
	interval  time.Duration
	udpTTL    time.Duration

	mu     sync.Mutex
	active map[string]stopper
}

func main() {
	var portsFile string
	var bindHost string
	var targetHost string
	var gatewayHost string
	var reloadInterval time.Duration
	var udpTTL time.Duration

	flag.StringVar(&portsFile, "ports-file", "", "PEGPU ports.json path")
	flag.StringVar(&bindHost, "bind-host", "127.0.0.1", "local address to bind")
	flag.StringVar(&targetHost, "target-host", "172.29.253.100", "PEGPU VM address to forward to")
	flag.StringVar(&gatewayHost, "gateway-host", "172.29.253.1", "PEGPU vmnet gateway address for VM-to-Mac access")
	flag.DurationVar(&reloadInterval, "reload-interval", time.Second, "port state reload interval")
	flag.DurationVar(&udpTTL, "udp-ttl", 60*time.Second, "idle UDP client mapping lifetime")
	flag.Parse()

	if portsFile == "" {
		log.Fatal("missing --ports-file")
	}
	if bindHost != "127.0.0.1" {
		log.Fatalf("refusing non-local bind host %q", bindHost)
	}
	if targetHost == "" || strings.HasPrefix(targetHost, "127.") || targetHost == "0.0.0.0" {
		log.Fatalf("refusing target host %q", targetHost)
	}
	if gatewayHost == "" || strings.HasPrefix(gatewayHost, "127.") || gatewayHost == "0.0.0.0" {
		log.Fatalf("refusing gateway host %q", gatewayHost)
	}

	s := &supervisor{
		portsFile: portsFile,
		bindHost:  bindHost,
		target:    targetHost,
		gateway:   gatewayHost,
		interval:  reloadInterval,
		udpTTL:    udpTTL,
		active:    map[string]stopper{},
	}

	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)
	go s.run()
	<-done
	s.stopAll()
}

func (s *supervisor) run() {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		s.reload()
		<-ticker.C
	}
}

func (s *supervisor) reload() {
	desired, err := readForwards(s.portsFile, s.bindHost, s.target, s.gateway)
	if err != nil {
		log.Printf("local proxy state unavailable: %v", err)
		desired = nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	desiredKeys := map[string]managedForward{}
	for _, item := range desired {
		desiredKeys[item.key] = item
		if _, ok := s.active[item.key]; ok {
			continue
		}
		runner, err := startForward(item, s.udpTTL)
		if err != nil {
			log.Printf("localhost alias unavailable for %s: %v", displayForward(item), err)
			continue
		}
		s.active[item.key] = runner
		log.Printf("localhost alias active: %s", displayForward(item))
	}

	for key, runner := range s.active {
		if _, ok := desiredKeys[key]; ok {
			continue
		}
		runner.stop()
		delete(s.active, key)
		log.Printf("localhost alias removed: %s", key)
	}
}

func (s *supervisor) stopAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for key, runner := range s.active {
		runner.stop()
		delete(s.active, key)
	}
}

func readForwards(path string, bindHost string, targetHost string, gatewayHost string) ([]managedForward, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var state stateFile
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	byKey := map[string]managedForward{}
	for _, item := range state.Forwards {
		protocol := strings.ToLower(strings.TrimSpace(item.Protocol))
		if protocol == "" {
			protocol = "tcp"
		}
		if protocol != "tcp" && protocol != "udp" {
			continue
		}
		if !validPort(item.MacPort) || !validPort(item.VMPort) {
			continue
		}
		direction := strings.TrimSpace(item.Direction)
		if direction == "" {
			direction = "vmToMac"
		}
		item.Protocol = protocol
		item.Direction = direction
		var itemBindHost string
		var itemTargetHost string
		var itemBindPort int
		var itemTargetPort int
		switch direction {
		case "vmToMac":
			itemBindHost = bindHost
			itemBindPort = item.MacPort
			itemTargetHost = targetHost
			itemTargetPort = item.VMPort
		case "macToVM":
			itemBindHost = gatewayHost
			itemBindPort = item.VMPort
			itemTargetHost = bindHost
			itemTargetPort = item.MacPort
		default:
			continue
		}
		key := fmt.Sprintf("%s:%s:%s:%d", direction, protocol, itemBindHost, itemBindPort)
		byKey[key] = managedForward{
			forward:    item,
			key:        key,
			bindHost:   itemBindHost,
			bindPort:   itemBindPort,
			targetHost: itemTargetHost,
			targetPort: itemTargetPort,
		}
	}
	out := make([]managedForward, 0, len(byKey))
	for _, item := range byKey {
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Direction != out[j].Direction {
			return out[i].Direction < out[j].Direction
		}
		if out[i].bindPort != out[j].bindPort {
			return out[i].bindPort < out[j].bindPort
		}
		return out[i].Protocol < out[j].Protocol
	})
	return out, nil
}

func startForward(item managedForward, udpTTL time.Duration) (stopper, error) {
	switch item.Protocol {
	case "tcp":
		return startTCPForward(item)
	case "udp":
		return startUDPForward(item, udpTTL)
	default:
		return nil, fmt.Errorf("unsupported protocol %q", item.Protocol)
	}
}

func validPort(port int) bool {
	return port > 0 && port < 65536
}

func displayForward(item managedForward) string {
	suffix := ""
	if item.Protocol == "udp" {
		suffix = "/udp"
	}
	switch item.Direction {
	case "macToVM":
		return fmt.Sprintf("127.0.0.1:%d%s -> %s:%d%s", item.MacPort, suffix, item.bindHost, item.bindPort, suffix)
	default:
		return fmt.Sprintf("%s:%d%s -> 127.0.0.1:%d%s", item.targetHost, item.targetPort, suffix, item.MacPort, suffix)
	}
}

type tcpForward struct {
	ln net.Listener
}

func startTCPForward(item managedForward) (*tcpForward, error) {
	ln, err := net.Listen("tcp4", net.JoinHostPort(item.bindHost, fmt.Sprint(item.bindPort)))
	if err != nil {
		return nil, err
	}
	t := &tcpForward{ln: ln}
	target := net.JoinHostPort(item.targetHost, fmt.Sprint(item.targetPort))
	go t.acceptLoop(target)
	return t, nil
}

func (t *tcpForward) acceptLoop(target string) {
	for {
		client, err := t.ln.Accept()
		if err != nil {
			return
		}
		go handleTCP(client, target)
	}
}

func (t *tcpForward) stop() {
	_ = t.ln.Close()
}

func handleTCP(client net.Conn, target string) {
	defer client.Close()
	remote, err := net.DialTimeout("tcp4", target, 5*time.Second)
	if err != nil {
		return
	}
	defer remote.Close()
	tuneTCP(client)
	tuneTCP(remote)

	done := make(chan struct{}, 2)
	go copyTCP(remote, client, done)
	go copyTCP(client, remote, done)
	<-done
	_ = client.Close()
	_ = remote.Close()
	<-done
}

func copyTCP(dst net.Conn, src net.Conn, done chan<- struct{}) {
	buf := make([]byte, 64*1024)
	_, _ = io.CopyBuffer(dst, src, buf)
	if tcp, ok := dst.(*net.TCPConn); ok {
		_ = tcp.CloseWrite()
	}
	done <- struct{}{}
}

func tuneTCP(conn net.Conn) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcp.SetNoDelay(true)
	_ = tcp.SetKeepAlive(true)
	_ = tcp.SetKeepAlivePeriod(30 * time.Second)
}

type udpForward struct {
	conn     *net.UDPConn
	target   *net.UDPAddr
	ttl      time.Duration
	done     chan struct{}
	sessions map[string]*udpSession
	mu       sync.Mutex
}

type udpSession struct {
	client   *net.UDPAddr
	upstream *net.UDPConn
	lastSeen time.Time
}

func startUDPForward(item managedForward, ttl time.Duration) (*udpForward, error) {
	local, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(item.bindHost, fmt.Sprint(item.bindPort)))
	if err != nil {
		return nil, err
	}
	target, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(item.targetHost, fmt.Sprint(item.targetPort)))
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp4", local)
	if err != nil {
		return nil, err
	}
	u := &udpForward{
		conn:     conn,
		target:   target,
		ttl:      ttl,
		done:     make(chan struct{}),
		sessions: map[string]*udpSession{},
	}
	go u.readLoop()
	go u.expireLoop()
	return u, nil
}

func (u *udpForward) readLoop() {
	buf := make([]byte, 64*1024)
	for {
		n, client, err := u.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		payload := make([]byte, n)
		copy(payload, buf[:n])
		session := u.sessionFor(client)
		if session == nil {
			continue
		}
		_, _ = session.upstream.Write(payload)
	}
}

func (u *udpForward) sessionFor(client *net.UDPAddr) *udpSession {
	key := client.String()
	now := time.Now()
	u.mu.Lock()
	defer u.mu.Unlock()
	if session := u.sessions[key]; session != nil {
		session.lastSeen = now
		return session
	}
	upstream, err := net.DialUDP("udp4", nil, u.target)
	if err != nil {
		log.Printf("udp target unavailable for %s: %v", u.target.String(), err)
		return nil
	}
	session := &udpSession{client: client, upstream: upstream, lastSeen: now}
	u.sessions[key] = session
	go u.replyLoop(key, session)
	return session
}

func (u *udpForward) replyLoop(key string, session *udpSession) {
	buf := make([]byte, 64*1024)
	for {
		n, err := session.upstream.Read(buf)
		if err != nil {
			u.mu.Lock()
			if u.sessions[key] == session {
				delete(u.sessions, key)
			}
			u.mu.Unlock()
			return
		}
		_, _ = u.conn.WriteToUDP(buf[:n], session.client)
	}
}

func (u *udpForward) expireLoop() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-u.done:
			return
		case <-ticker.C:
			u.expireSessions()
		}
	}
}

func (u *udpForward) expireSessions() {
	cutoff := time.Now().Add(-u.ttl)
	u.mu.Lock()
	defer u.mu.Unlock()
	for key, session := range u.sessions {
		if session.lastSeen.After(cutoff) {
			continue
		}
		_ = session.upstream.Close()
		delete(u.sessions, key)
	}
}

func (u *udpForward) stop() {
	close(u.done)
	_ = u.conn.Close()
	u.mu.Lock()
	defer u.mu.Unlock()
	for key, session := range u.sessions {
		_ = session.upstream.Close()
		delete(u.sessions, key)
	}
}
