// Package daemon은 `mdr serve`의 수명을 다룹니다.
//
// 서버는 원이 따로 켜고 끄지 않습니다. `mdr <file>`이 필요할 때 띄우고, 아무도 쓰지 않으면 스스로 끝납니다.
//
//   - CLI와 서버는 상태 폴더의 Unix 소켓(ctl.sock, 0600)으로만 이야기합니다. 같은 사용자만 닿을 수 있습니다.
//   - 서버는 살아 있는 동안 serve.lock을 잠급니다. 그래서 동시에 둘이 뜨지 않습니다.
//   - 서버가 죽거나 호스트가 재시작하면 잠금은 커널이 풀고, 남은 소켓 파일에는 연결이 거부됩니다.
//     다음 `mdr` 실행이 이것을 보고 새로 띄웁니다.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"

	"mdr/internal/server"
	"mdr/internal/tailnet"
)

// DefaultPort는 먼저 시도하는 포트입니다. 쓰이고 있으면 빈 포트를 고릅니다.
const DefaultPort = 6370

// Paths는 상태 폴더 안의 파일들입니다.
type Paths struct {
	Dir    string
	Socket string
	Lock   string
	Log    string
}

// DefaultPaths는 상태 폴더를 정합니다. MDR_STATE_DIR이 있으면 그것을 씁니다.
func DefaultPaths() (Paths, error) {
	dir := os.Getenv("MDR_STATE_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return Paths{}, err
		}
		switch {
		case runtime.GOOS == "darwin":
			dir = filepath.Join(home, "Library", "Application Support", "mdr", "cli")
		case os.Getenv("XDG_STATE_HOME") != "":
			dir = filepath.Join(os.Getenv("XDG_STATE_HOME"), "mdr")
		default:
			dir = filepath.Join(home, ".local", "state", "mdr")
		}
	}
	return Paths{
		Dir:    dir,
		Socket: filepath.Join(dir, "ctl.sock"),
		Lock:   filepath.Join(dir, "serve.lock"),
		Log:    filepath.Join(dir, "serve.log"),
	}, nil
}

// Config는 서버를 띄우는 값입니다.
type Config struct {
	Paths   Paths
	Version string
	Port    int
	TTL     time.Duration
	// InsecureBind가 있으면 tailnet 대신 이 주소에 bind하고 상대를 확인하지 않습니다. 테스트 전용입니다.
	InsecureBind string
	Tailnet      tailnet.Client
	Logger       *log.Logger
}

// Status는 서버가 자기 상태를 알리는 값입니다.
type Status struct {
	Version   string `json:"version"`
	PID       int    `json:"pid"`
	Addr      string `json:"addr"`
	Host      string `json:"host"`
	Login     string `json:"login,omitempty"`
	Insecure  bool   `json:"insecure,omitempty"`
	StartedAt string `json:"startedAt"`
	TTL       string `json:"ttl"`
	Tokens    int    `json:"tokens"`
	Streams   int    `json:"streams"`
}

// RegisterRequest는 문서 하나를 열어 달라는 요청입니다.
type RegisterRequest struct {
	Root string `json:"root"`
	Rel  string `json:"rel"`
}

// RegisterReply는 앱이 문서를 가져갈 주소입니다.
type RegisterReply struct {
	Host  string `json:"host"`
	Port  int    `json:"port"`
	Token string `json:"token"`
	Rel   string `json:"rel"`
}

// ErrAlreadyRunning은 다른 서버가 이미 잠금을 쥐고 있을 때 돌려줍니다.
var ErrAlreadyRunning = errors.New("mdr 서버가 이미 실행 중입니다")

// Run은 서버를 띄우고, 아무도 쓰지 않거나 멈추라는 요청이 올 때까지 돕니다.
// 듣기 시작하면(또는 시작하지 못하면) ready를 한 번 부릅니다.
func Run(ctx context.Context, cfg Config, ready func(Status, error)) error {
	notify := func(status Status, err error) {
		if ready != nil {
			ready(status, err)
			ready = nil
		}
	}
	fail := func(err error) error {
		notify(Status{}, err)
		return err
	}
	logger := cfg.Logger
	if logger == nil {
		logger = log.New(os.Stderr, "", log.LstdFlags)
	}
	if cfg.TTL <= 0 {
		cfg.TTL = 12 * time.Hour
	}

	// 상태 폴더가 없으면 본인만 쓸 수 있게 만듭니다. 이미 있는 폴더의 권한은 바꾸지 않습니다
	// (MDR_STATE_DIR로 남과 같이 쓰는 폴더를 가리켰을 수도 있습니다). 그 안에 만드는 소켓과 기록은
	// 폴더의 권한과 상관없이 본인만 쓸 수 있게 만듭니다.
	syscall.Umask(0o077)
	if err := os.MkdirAll(cfg.Paths.Dir, 0o700); err != nil {
		return fail(err)
	}
	lock, err := os.OpenFile(cfg.Paths.Lock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fail(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fail(ErrAlreadyRunning)
	}

	// bind할 주소: tailnet 주소 하나뿐입니다.
	var (
		bindIP netip.Addr
		self   tailnet.Self
	)
	insecure := cfg.InsecureBind != ""
	if insecure {
		bindIP, err = netip.ParseAddr(cfg.InsecureBind)
		if err != nil {
			return fail(fmt.Errorf("MDR_INSECURE_DEV_BIND를 읽을 수 없습니다: %w", err))
		}
		self.HostName, _ = os.Hostname()
		logger.Printf("경고: 테스트 모드입니다. %s에 bind하고 상대를 확인하지 않습니다", bindIP)
	} else {
		if cfg.Tailnet == nil {
			return fail(errors.New("Tailscale 클라이언트가 없습니다"))
		}
		probe, cancel := context.WithTimeout(ctx, 5*time.Second)
		self, err = cfg.Tailnet.Self(probe)
		cancel()
		if err != nil {
			return fail(err)
		}
		if self.UserID == 0 {
			return fail(errors.New("이 기기의 Tailscale 계정을 알 수 없습니다(태그가 붙은 기기일 수 있습니다)"))
		}
		var ok bool
		if bindIP, ok = tailnet.PickBindIP(self.IPs); !ok {
			return fail(tailnet.ErrNotRunning)
		}
	}

	port := cfg.Port
	if port == 0 {
		port = DefaultPort
	}
	listener, err := net.Listen("tcp", netip.AddrPortFrom(bindIP, uint16(port)).String())
	if err != nil {
		logger.Printf("포트 %d를 쓸 수 없어 빈 포트를 고릅니다: %v", port, err)
		listener, err = net.Listen("tcp", netip.AddrPortFrom(bindIP, 0).String())
	}
	if err != nil {
		return fail(fmt.Errorf("%s에 bind하지 못했습니다: %w", bindIP, err))
	}
	defer listener.Close()
	addr := listener.Addr().(*net.TCPAddr).AddrPort()

	srv := server.New(server.Options{
		Tailnet:    cfg.Tailnet,
		SelfUserID: self.UserID,
		Insecure:   insecure,
		HostName:   self.HostName,
		TTL:        cfg.TTL,
		Logf:       logger.Printf,
	})
	defer srv.Close()
	data := &http.Server{
		Handler: srv, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second, ErrorLog: logger,
		// 요청 줄과 머리말의 크기를 줄입니다. 문서 경로는 길어야 몇백 바이트입니다.
		MaxHeaderBytes: 16 << 10,
	}

	// 제어 소켓. 잠금을 쥐고 있으므로 남아 있는 소켓 파일은 죽은 서버의 것입니다.
	os.Remove(cfg.Paths.Socket)
	control, err := net.Listen("unix", cfg.Paths.Socket)
	if err != nil {
		return fail(fmt.Errorf("제어 소켓을 열지 못했습니다: %w", err))
	}
	defer os.Remove(cfg.Paths.Socket)
	defer control.Close()
	if err := os.Chmod(cfg.Paths.Socket, 0o600); err != nil {
		return fail(err)
	}

	started := time.Now()
	status := func() Status {
		tokens, streams := srv.Counts()
		return Status{
			Version: cfg.Version, PID: os.Getpid(), Addr: addr.String(), Host: self.HostName, Login: self.Login,
			Insecure: insecure, StartedAt: started.Format(time.RFC3339), TTL: cfg.TTL.String(),
			Tokens: tokens, Streams: streams,
		}
	}
	stop := make(chan struct{})
	var stopOnce sync.Once

	mux := http.NewServeMux()
	writeJSON := func(w http.ResponseWriter, code int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(value)
	}
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, status())
	})
	mux.HandleFunc("POST /stop", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, status())
		stopOnce.Do(func() { close(stop) })
	})
	mux.HandleFunc("POST /register", func(w http.ResponseWriter, r *http.Request) {
		var request RegisterRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "요청을 읽을 수 없습니다"})
			return
		}
		if !insecure {
			// 링크를 내주기 전에 그 주소가 아직 이 기기의 tailnet 주소인지 봅니다.
			probe, cancel := context.WithTimeout(r.Context(), 5*time.Second)
			now, err := cfg.Tailnet.Self(probe)
			cancel()
			if err != nil {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
				return
			}
			still := false
			for _, ip := range now.IPs {
				still = still || ip == bindIP
			}
			if !still {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{
					"error": fmt.Sprintf("이 기기의 tailnet 주소가 %s에서 바뀌었습니다. `mdr stop` 뒤에 다시 실행해 주십시오", bindIP),
				})
				return
			}
		}
		token, err := srv.Register(request.Root, request.Rel)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, RegisterReply{Host: addr.Addr().String(), Port: int(addr.Port()), Token: token, Rel: request.Rel})
	})
	controlServer := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ErrorLog: logger}

	errs := make(chan error, 2)
	go func() { errs <- data.Serve(listener) }()
	go func() { errs <- controlServer.Serve(control) }()
	logger.Printf("mdr serve %s: http://%s (pid %d, ttl %s, whois %v)", cfg.Version, addr, os.Getpid(), cfg.TTL, !insecure)
	notify(status(), nil)

	tick := cfg.TTL / 4
	if tick > 30*time.Second {
		tick = 30 * time.Second
	}
	if tick < 100*time.Millisecond {
		tick = 100 * time.Millisecond
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()
	var result error
loop:
	for {
		select {
		case <-ctx.Done():
			logger.Printf("끝냅니다: 신호를 받았습니다")
			break loop
		case <-stop:
			logger.Printf("끝냅니다: mdr stop")
			break loop
		case err := <-errs:
			if !errors.Is(err, http.ErrServerClosed) {
				result = err
				logger.Printf("끝냅니다: %v", err)
			}
			break loop
		case <-ticker.C:
			if !srv.Sweep() {
				logger.Printf("끝냅니다: %s 동안 쓰이지 않았습니다", cfg.TTL)
				break loop
			}
		}
	}
	// 새 요청을 그만 받고, 열려 있는 변경 알림 연결을 끝냅니다.
	control.Close()
	os.Remove(cfg.Paths.Socket)
	srv.Close()
	shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	controlServer.Shutdown(shutdown)
	data.Shutdown(shutdown)
	return result
}

// CappedLog는 기록 파일이 정해 둔 크기를 넘으면 비우고 이어 씁니다. 서버는 오래 떠 있고 요청마다 한 줄을 남기므로,
// 실행 중에도 기록이 끝없이 자라지 않게 합니다. 파일은 덧붙이기 모드로 열려 있어야 합니다.
type CappedLog struct {
	mu    sync.Mutex
	file  *os.File
	limit int64
	size  int64
}

func NewCappedLog(file *os.File, limit int64) *CappedLog {
	capped := &CappedLog{file: file, limit: limit}
	if info, err := file.Stat(); err == nil {
		capped.size = info.Size()
	}
	return capped
}

func (c *CappedLog) Write(data []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.size+int64(len(data)) > c.limit {
		if err := c.file.Truncate(0); err == nil {
			c.size = 0
		}
	}
	written, err := c.file.Write(data)
	c.size += int64(written)
	return written, err
}

// FormatPort는 포트를 문자열로 바꿉니다(자식 프로세스 인자용).
func FormatPort(port int) string { return strconv.Itoa(port) }
