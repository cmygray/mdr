// Package server는 앱에게 마크다운 원문과 이미지를 내주는 HTTP 서버입니다.
//
// 프로토콜(v1). 앱은 `mdr://<host>:<port>/<token>/<path>` 링크를 아래 주소로 바꿔 요청합니다.
//
//	GET /v1/<token>/files/<path>    파일 내용. ETag와 If-None-Match를 지원합니다.
//	GET /v1/<token>/events/<path>   그 파일의 변경 알림(SSE). `hello`, `change` 이벤트와 주기적인 주석 줄.
//
// 오류는 `{"error": "<코드>", "message": "<설명>"}`으로 돌려줍니다.
//
//	403 forbidden_peer     tailnet 주소가 아니거나, whois로 확인한 계정이 서버 주인이 아님
//	401 invalid_token      모르는 token이거나 만료됨
//	403 path_not_allowed   문서 폴더 밖이거나 내주지 않는 종류의 파일
//	404 not_found          파일이 없음
//
// 요청마다 이 순서로 확인합니다: 상대 주소 → whois → token → 경로.
package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"mdr/internal/tailnet"
)

// Options는 서버를 만드는 값입니다.
type Options struct {
	// Tailnet은 접속한 상대가 누구인지 묻는 데 씁니다. Insecure일 때만 nil일 수 있습니다.
	Tailnet tailnet.Client
	// SelfUserID는 서버를 띄운 사람의 Tailscale 계정입니다. 이 계정의 기기만 받습니다.
	SelfUserID int64
	// Insecure이면 상대 주소와 whois를 확인하지 않습니다. 테스트 전용입니다.
	Insecure bool
	// HostName은 앱이 창 제목에 보여 줄 이 기기의 이름입니다.
	HostName string
	// TTL은 token이 마지막으로 쓰인 뒤 살아 있는 시간이자, 서버가 아무 일 없이 기다리는 시간입니다.
	TTL time.Duration

	Now          func() time.Time
	PollInterval time.Duration
	Heartbeat    time.Duration
	Logf         func(format string, args ...any)
}

// Server는 http.Handler입니다.
type Server struct {
	opts   Options
	store  *store
	ctx    context.Context
	cancel context.CancelFunc

	whoMu    sync.Mutex
	whoCache map[netip.Addr]time.Time
}

func New(opts Options) *Server {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.TTL <= 0 {
		opts.TTL = 12 * time.Hour
	}
	if opts.PollInterval <= 0 {
		opts.PollInterval = 400 * time.Millisecond
	}
	if opts.Heartbeat <= 0 {
		opts.Heartbeat = 15 * time.Second
	}
	if opts.Logf == nil {
		opts.Logf = func(string, ...any) {}
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		opts:     opts,
		store:    newStore(opts.TTL, opts.Now),
		ctx:      ctx,
		cancel:   cancel,
		whoCache: map[netip.Addr]time.Time{},
	}
}

// Register는 root 폴더 아래 rel 문서를 열 수 있는 token을 돌려줍니다.
func (s *Server) Register(root, rel string) (string, error) {
	rel = filepath.ToSlash(rel)
	if !filepath.IsAbs(root) {
		return "", errors.New("문서 폴더는 절대 경로여야 합니다")
	}
	if !validRel(rel) {
		return "", fmt.Errorf("문서가 문서 폴더 안에 있지 않습니다: %s", rel)
	}
	token, err := s.store.register(root, rel)
	if err != nil {
		return "", err
	}
	// 등록하는 순간에도 서버가 실제로 내줄 수 있는 파일인지 같은 경로로 확인합니다.
	g, _ := s.store.lookup(token)
	if g == nil {
		return "", errors.New("token을 만들지 못했습니다")
	}
	info, err := g.root.Stat(rel)
	if err != nil {
		return "", fmt.Errorf("문서를 열 수 없습니다: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("일반 파일이 아닙니다: %s", rel)
	}
	return token, nil
}

// Sweep은 만료된 token을 지우고, 서버가 더 살아 있어야 하는지 알려 줍니다.
func (s *Server) Sweep() bool { return s.store.sweep() }

// Counts는 살아 있는 token 수와 열려 있는 변경 알림 연결 수입니다.
func (s *Server) Counts() (tokens, streams int) { return s.store.counts() }

// Close는 열려 있는 변경 알림 연결을 끝내고 모든 token을 버립니다.
func (s *Server) Close() {
	s.cancel()
	s.store.closeAll()
}

// MarkdownExtensions는 문서로 내주는 확장자입니다.
var MarkdownExtensions = map[string]bool{".md": true, ".markdown": true, ".mdown": true, ".mkd": true}

// imageExtensions는 문서가 참조할 수 있는 이미지 확장자입니다. SVG는 앱이 그리지 않으므로 내주지 않습니다.
var imageExtensions = map[string]string{
	".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
	".webp": "image/webp", ".heic": "image/heic", ".heif": "image/heif", ".avif": "image/avif",
	".tif": "image/tiff", ".tiff": "image/tiff", ".bmp": "image/bmp",
}

// recorder는 응답 상태를 기억해 두었다가 요청 기록에 씁니다.
type recorder struct {
	http.ResponseWriter
	status int
}

func (r *recorder) WriteHeader(status int) {
	if r.status == 0 {
		r.status = status
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *recorder) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(data)
}

// Unwrap은 http.ResponseController가 원래 writer의 Flush와 쓰기 기한 설정을 찾게 해 줍니다.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// ServeHTTP는 요청마다 한 줄을 기록합니다. token은 기록하지 않습니다.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	record := &recorder{ResponseWriter: w}
	_, kind, rel, err := parseTarget(r.URL.EscapedPath())
	if err != nil {
		kind, rel = "-", "-"
	}
	if kind == "events" {
		s.opts.Logf("요청 %s %s %q 시작 (%s)", r.Method, kind, rel, r.RemoteAddr)
	}
	s.serve(record, r)
	s.opts.Logf("요청 %s %s %q → %d (%s)", r.Method, kind, rel, record.status, r.RemoteAddr)
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-cache")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		s.fail(w, r, http.StatusMethodNotAllowed, "method_not_allowed", "GET만 받습니다")
		return
	}
	// 1·2) 상대가 tailnet의 내 기기인지 먼저 봅니다. 통과하지 못하면 token이 맞는지조차 알려 주지 않습니다.
	if err := s.checkPeer(r.Context(), r.RemoteAddr); err != nil {
		s.opts.Logf("거절 %s: %v", r.RemoteAddr, err)
		s.fail(w, r, http.StatusForbidden, "forbidden_peer", err.Error())
		return
	}
	token, kind, rel, err := parseTarget(r.URL.EscapedPath())
	if err != nil {
		if errors.Is(err, errNoRoute) {
			s.fail(w, r, http.StatusNotFound, "not_found", "없는 주소입니다")
			return
		}
		// 경로가 잘못됐더라도 token이 맞는 상대에게만 그 사실을 알려 줍니다.
		if _, ok := s.store.lookup(token); !ok {
			s.fail(w, r, http.StatusUnauthorized, "invalid_token", "token이 만료되었거나 올바르지 않습니다")
			return
		}
		s.opts.Logf("경로 거절 %s: %v", r.RemoteAddr, err)
		s.fail(w, r, http.StatusForbidden, "path_not_allowed", "문서 폴더 밖의 경로입니다")
		return
	}
	// 3) token
	g, ok := s.store.lookup(token)
	if !ok {
		s.fail(w, r, http.StatusUnauthorized, "invalid_token", "token이 만료되었거나 올바르지 않습니다")
		return
	}
	// 4) 경로와 파일 종류
	ext := strings.ToLower(path.Ext(rel))
	contentType := ""
	switch {
	case MarkdownExtensions[ext]:
		contentType = "text/markdown; charset=utf-8"
	case imageExtensions[ext] != "":
		contentType = imageExtensions[ext]
	case s.store.isExplicit(g, rel):
		contentType = "text/markdown; charset=utf-8"
	default:
		s.fail(w, r, http.StatusForbidden, "path_not_allowed", "마크다운과 이미지 파일만 내줍니다")
		return
	}
	switch kind {
	case "files":
		s.serveFile(w, r, g, rel, contentType)
	case "events":
		s.serveEvents(w, r, g, rel)
	}
}

var errNoRoute = errors.New("no route")

// parseTarget은 `/v1/<token>/<files|events>/<path...>`를 나눕니다.
//
// 경로는 `/`로 나눈 뒤 조각마다 한 번만 퍼센트 디코딩합니다. 디코딩한 조각에 `/`가 들어 있거나
// (`%2F`), 조각이 `.`·`..`이거나, 역슬래시·제어 문자가 있으면 거절합니다. 그래서 `..%2F`나 `%2e%2e` 같은
// 인코딩으로 폴더 밖을 가리킬 수 없습니다. token이 형식에 맞으면 오류와 함께 돌려줍니다.
func parseTarget(escaped string) (token, kind, rel string, err error) {
	parts := strings.Split(escaped, "/")
	if len(parts) < 5 || parts[0] != "" || parts[1] != "v1" {
		return "", "", "", errNoRoute
	}
	token, kind = parts[2], parts[3]
	if kind != "files" && kind != "events" {
		return "", "", "", errNoRoute
	}
	segments := make([]string, 0, len(parts)-4)
	for _, raw := range parts[4:] {
		segment, uerr := url.PathUnescape(raw)
		if uerr != nil || !validSegment(segment) {
			return token, kind, "", fmt.Errorf("잘못된 경로 조각 %q", raw)
		}
		segments = append(segments, segment)
	}
	rel = strings.Join(segments, "/")
	if !validRel(rel) {
		return token, kind, "", fmt.Errorf("잘못된 경로 %q", rel)
	}
	return token, kind, rel, nil
}

func validSegment(segment string) bool {
	if segment == "" || segment == "." || segment == ".." {
		return false
	}
	for _, r := range segment {
		if r == '/' || r == '\\' || r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func validRel(rel string) bool {
	if rel == "" || strings.HasPrefix(rel, "/") || !filepath.IsLocal(filepath.FromSlash(rel)) {
		return false
	}
	for _, segment := range strings.Split(rel, "/") {
		if !validSegment(segment) {
			return false
		}
	}
	return true
}

func etagFor(info fs.FileInfo) string {
	return fmt.Sprintf(`"%x-%x"`, info.ModTime().UnixNano(), info.Size())
}

// docID는 문서의 변하지 않는 이름표입니다. 앱이 읽던 자리를 기억하는 키로 씁니다.
// token은 서버가 다시 뜨면 바뀌므로 키로 쓸 수 없고, 절대 경로를 그대로 내보내지 않으려고 해시합니다.
func docID(rootPath, rel string) string {
	sum := sha256.Sum256([]byte("mdr-doc\x00" + rootPath + "\x00" + rel))
	return hex.EncodeToString(sum[:16])
}

// open은 문서 폴더 안의 일반 파일만 엽니다. 심볼릭 링크가 폴더 밖을 가리키면 os.Root가 거절합니다.
func (s *Server) open(g *grant, rel string) (*os.File, fs.FileInfo, int, string) {
	// 먼저 종류를 봅니다. 이름 있는 파이프를 열면 쓰는 쪽이 올 때까지 멈춰 버립니다.
	info, err := g.root.Stat(rel)
	if err == nil && !info.Mode().IsRegular() {
		return nil, nil, http.StatusNotFound, "not_found"
	}
	var file *os.File
	if err == nil {
		file, err = g.root.Open(rel)
	}
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, http.StatusNotFound, "not_found"
		}
		s.opts.Logf("열기 거절 %s: %v", rel, err)
		return nil, nil, http.StatusForbidden, "path_not_allowed"
	}
	info, err = file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, http.StatusNotFound, "not_found"
	}
	return file, info, 0, ""
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, g *grant, rel, contentType string) {
	file, info, status, code := s.open(g, rel)
	if file == nil {
		message := "파일을 찾을 수 없습니다"
		if code == "path_not_allowed" {
			message = "문서 폴더 밖의 경로입니다"
		}
		s.fail(w, r, status, code, message)
		return
	}
	defer file.Close()
	header := w.Header()
	header.Set("Content-Type", contentType)
	header.Set("ETag", etagFor(info))
	header.Set("X-Mdr-Doc-Id", docID(g.rootPath, rel))
	if s.opts.HostName != "" {
		header.Set("X-Mdr-Host", url.PathEscape(s.opts.HostName))
	}
	http.ServeContent(w, r, "", info.ModTime(), file)
}

// serveEvents는 파일이 바뀔 때마다 `change` 이벤트를 보냅니다.
//
// 파일을 주기적으로 stat해서 바뀐 것을 알아냅니다. 연결이 열려 있는 동안에만 돌고, 편집기가 임시 파일을
// 만든 뒤 이름을 바꿔 저장하는 경우나 네트워크 파일 시스템에서도 같은 방식으로 동작합니다.
func (s *Server) serveEvents(w http.ResponseWriter, r *http.Request, g *grant, rel string) {
	if r.Method != http.MethodGet {
		s.fail(w, r, http.StatusMethodNotAllowed, "method_not_allowed", "GET만 받습니다")
		return
	}
	signature := func() string {
		info, err := g.root.Stat(rel)
		if err != nil || !info.Mode().IsRegular() {
			return ""
		}
		return etagFor(info)
	}
	current := signature()
	if current == "" {
		s.fail(w, r, http.StatusNotFound, "not_found", "파일을 찾을 수 없습니다")
		return
	}
	if err := s.store.acquireStream(g); err != nil {
		s.fail(w, r, http.StatusServiceUnavailable, "busy", "열려 있는 연결이 너무 많습니다")
		return
	}
	defer s.store.releaseStream(g)

	controller := http.NewResponseController(w)
	header := w.Header()
	header.Set("Content-Type", "text/event-stream")
	header.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	send := func(text string) bool {
		// 상대가 사라졌는데 쓰기가 끝없이 기다리지 않게 합니다.
		controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if _, err := fmt.Fprint(w, text); err != nil {
			return false
		}
		return controller.Flush() == nil
	}
	event := func(name, etag string) bool {
		data, _ := json.Marshal(map[string]string{"etag": etag})
		return send(fmt.Sprintf("event: %s\ndata: %s\n\n", name, data))
	}
	// 앱이 문서를 받은 뒤 이 연결을 열기까지 사이에 바뀐 것을 놓치지 않도록, 지금 상태를 먼저 알려 줍니다.
	if !event("hello", current) {
		return
	}

	poll := time.NewTicker(s.opts.PollInterval)
	defer poll.Stop()
	heartbeat := time.NewTicker(s.opts.Heartbeat)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-s.ctx.Done():
			return
		case <-heartbeat.C:
			s.store.touch(g)
			if !send(": ping\n\n") {
				return
			}
		case <-poll.C:
			next := signature()
			// 저장 도중 잠깐 파일이 없을 수 있습니다. 다시 나타났을 때 알립니다.
			if next == "" || next == current {
				continue
			}
			current = next
			if !event("change", current) {
				return
			}
		}
	}
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"error": code, "message": message})
}

// 상대 확인 결과를 잠깐 기억합니다. 문서 하나가 이미지 여러 장을 한꺼번에 요청하기 때문입니다.
const whoCacheTTL = 30 * time.Second

// checkPeer는 접속한 상대가 tailnet 주소이고, whois로 확인한 계정이 서버 주인인지 봅니다.
// whois가 실패하면 받지 않습니다.
func (s *Server) checkPeer(ctx context.Context, remoteAddr string) error {
	if s.opts.Insecure {
		return nil
	}
	remote, err := netip.ParseAddrPort(remoteAddr)
	if err != nil {
		return errors.New("상대 주소를 읽을 수 없습니다")
	}
	ip := remote.Addr().Unmap()
	if !tailnet.IsTailnetIP(ip) {
		return errors.New("tailnet 주소가 아닙니다")
	}
	now := s.opts.Now()
	s.whoMu.Lock()
	until, cached := s.whoCache[ip]
	s.whoMu.Unlock()
	if cached && now.Before(until) {
		return nil
	}
	if s.opts.Tailnet == nil {
		return errors.New("whois를 쓸 수 없습니다")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	peer, err := s.opts.Tailnet.WhoIs(ctx, netip.AddrPortFrom(ip, remote.Port()))
	if err != nil {
		return fmt.Errorf("whois로 상대를 확인하지 못했습니다: %v", err)
	}
	if peer.Tagged || peer.UserID == 0 || peer.UserID != s.opts.SelfUserID {
		return errors.New("이 서버 주인의 Tailscale 계정이 아닙니다")
	}
	s.whoMu.Lock()
	for addr, expiry := range s.whoCache {
		if !now.Before(expiry) {
			delete(s.whoCache, addr)
		}
	}
	s.whoCache[ip] = now.Add(whoCacheTTL)
	s.whoMu.Unlock()
	return nil
}
