package daemon

import (
	"context"
	"errors"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"mdr/internal/tailnet"
)

type fakeTailnet struct {
	self tailnet.Self
	err  error
}

func (f fakeTailnet) Self(context.Context) (tailnet.Self, error) { return f.self, f.err }

func (f fakeTailnet) WhoIs(context.Context, netip.AddrPort) (tailnet.Peer, error) {
	return tailnet.Peer{}, errors.New("unused")
}

func testPaths(t *testing.T) Paths {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "mdr-dt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return Paths{Dir: dir, Socket: dir + "/ctl.sock", Lock: dir + "/serve.lock", Log: dir + "/serve.log"}
}

// start는 Run을 돌리고, 준비됐다는(또는 실패했다는) 알림을 기다립니다.
func startServer(t *testing.T, cfg Config) (Status, error) {
	t.Helper()
	cfg.Logger = log.New(io.Discard, "", 0)
	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		status Status
		err    error
	}
	ready := make(chan result, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		Run(ctx, cfg, func(status Status, err error) { ready <- result{status, err} })
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	select {
	case got := <-ready:
		return got.status, got.err
	case <-time.After(5 * time.Second):
		t.Fatal("서버가 준비되지 않았습니다")
		return Status{}, nil
	}
}

// 서버는 Tailscale이 알려 준 tailnet 주소가 아니면 듣지 않습니다.
func TestRefusesToStartWithoutTailnetAddress(t *testing.T) {
	cases := map[string]fakeTailnet{
		"Tailscale 데몬에 닿지 않음":  {err: errors.New("dial unix /var/run/tailscale/tailscaled.sock: connect: no such file or directory")},
		"Tailscale이 꺼져 있음":     {err: tailnet.ErrNotRunning},
		"tailnet 주소가 없음":       {self: tailnet.Self{UserID: 7}},
		"tailnet 범위 밖의 주소만 있음": {self: tailnet.Self{UserID: 7, IPs: []netip.Addr{netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("192.168.0.10"), netip.MustParseAddr("0.0.0.0")}}},
		"계정을 알 수 없음(태그 기기)":    {self: tailnet.Self{UserID: 0, IPs: []netip.Addr{netip.MustParseAddr("100.64.0.1")}}},
	}
	for name, fake := range cases {
		t.Run(name, func(t *testing.T) {
			paths := testPaths(t)
			port := freePort(t)
			_, err := startServer(t, Config{Paths: paths, Version: "test", Port: port, Tailnet: fake})
			if err == nil {
				t.Fatal("서버가 시작됐습니다")
			}
			// 어느 주소에서도 그 포트를 듣고 있지 않아야 합니다.
			if conn, dialErr := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", FormatPort(port)), 300*time.Millisecond); dialErr == nil {
				conn.Close()
				t.Errorf("시작에 실패했는데 포트 %d가 열려 있습니다", port)
			}
			if _, statErr := os.Stat(paths.Socket); statErr == nil {
				t.Errorf("시작에 실패했는데 제어 소켓이 남았습니다")
			}
		})
	}
}

func TestRefusesToStartWithoutTailnetClient(t *testing.T) {
	_, err := startServer(t, Config{Paths: testPaths(t), Version: "test", Port: freePort(t)})
	if err == nil {
		t.Fatal("Tailscale 클라이언트 없이 서버가 시작됐습니다")
	}
}

func TestSecondServerOnSameStateDirIsRefused(t *testing.T) {
	paths := testPaths(t)
	first, err := startServer(t, Config{Paths: paths, Version: "test", Port: freePort(t), InsecureBind: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(first.Addr, "127.0.0.1:") || !first.Insecure {
		t.Errorf("상태: %+v", first)
	}
	_, err = startServer(t, Config{Paths: paths, Version: "test", Port: freePort(t), InsecureBind: "127.0.0.1"})
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Errorf("두 번째 서버: %v, want ErrAlreadyRunning", err)
	}
	// 첫 서버는 그대로 응답합니다.
	if status, err := NewClient(paths).Status(context.Background()); err != nil || status.PID != first.PID {
		t.Errorf("첫 서버 상태: %+v %v", status, err)
	}
}

func TestFallsBackToAnotherPortWhenTaken(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	port := taken.Addr().(*net.TCPAddr).Port
	status, err := startServer(t, Config{Paths: testPaths(t), Version: "test", Port: port, InsecureBind: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if status.Addr == taken.Addr().String() || !strings.HasPrefix(status.Addr, "127.0.0.1:") {
		t.Errorf("주소 %s", status.Addr)
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// 이미 있는 상태 폴더의 권한은 바꾸지 않고, 그 안의 소켓은 본인만 쓸 수 있게 만듭니다.
func TestExistingStateDirPermissionsAreLeftAlone(t *testing.T) {
	paths := testPaths(t)
	if err := os.Chmod(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := startServer(t, Config{Paths: paths, Version: "test", Port: freePort(t), InsecureBind: "127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(paths.Dir); info.Mode().Perm() != 0o755 {
		t.Errorf("상태 폴더 권한이 %o로 바뀌었습니다", info.Mode().Perm())
	}
	for _, name := range []string{paths.Socket, paths.Lock} {
		if info, err := os.Stat(name); err != nil || info.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s 권한: %v (%v), 본인만 쓸 수 있어야 합니다", name, info.Mode().Perm(), err)
		}
	}
}

func TestCappedLogTruncatesInsteadOfGrowing(t *testing.T) {
	file, err := os.OpenFile(t.TempDir()+"/serve.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	capped := NewCappedLog(file, 1000)
	line := []byte(strings.Repeat("x", 99) + "\n")
	for range 500 {
		if _, err := capped.Write(line); err != nil {
			t.Fatal(err)
		}
	}
	info, _ := file.Stat()
	if info.Size() > 1000 || info.Size() == 0 {
		t.Errorf("기록 파일 크기 %d, 0보다 크고 1000 이하여야 합니다", info.Size())
	}
}
