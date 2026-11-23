package server

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"mdr/internal/tailnet"
)

const (
	ownerID    = 1001
	strangerID = 2002
	ownerPeer  = "100.101.102.103:40000"
	secretText = "TOP-SECRET-OUTSIDE-ROOT"
)

// fakeTailnet은 whois 대답을 정해 둔 가짜 Tailscale 데몬입니다.
type fakeTailnet struct {
	mu    sync.Mutex
	peers map[netip.Addr]tailnet.Peer
	err   error
	calls int
}

func (f *fakeTailnet) Self(context.Context) (tailnet.Self, error) {
	return tailnet.Self{UserID: ownerID, HostName: "testhost"}, nil
}

func (f *fakeTailnet) WhoIs(_ context.Context, remote netip.AddrPort) (tailnet.Peer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return tailnet.Peer{}, f.err
	}
	peer, ok := f.peers[remote.Addr()]
	if !ok {
		return tailnet.Peer{}, errors.New("peer not found")
	}
	return peer, nil
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

type fixture struct {
	t      *testing.T
	server *Server
	ts     *fakeTailnet
	clock  *clock
	// root는 문서 폴더, outside는 그 바깥(같은 임시 폴더 안)입니다.
	root, outside string
	token         string
}

// newFixture는 이런 폴더를 만듭니다.
//
//	<tmp>/secret.md, secret.png         문서 폴더 밖
//	<tmp>/docs/note.md                  직접 연 문서
//	<tmp>/docs/other.md, img/a.png, sub/deep.md, notes.txt, .env
func newFixture(t *testing.T) *fixture {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "docs")
	write := func(path, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(base, "secret.md"), secretText)
	write(filepath.Join(base, "secret.png"), secretText)
	write(filepath.Join(root, "note.md"), "# note")
	write(filepath.Join(root, "other.md"), "# other")
	write(filepath.Join(root, "img", "a.png"), "PNGDATA")
	write(filepath.Join(root, "sub", "deep.md"), "# deep")
	write(filepath.Join(root, "notes.txt"), "plain text")
	write(filepath.Join(root, ".env"), "PASSWORD=1")

	ts := &fakeTailnet{peers: map[netip.Addr]tailnet.Peer{
		netip.MustParseAddr("100.101.102.103"):      {UserID: ownerID, Login: "owner@example.com", Node: "mac"},
		netip.MustParseAddr("fd7a:115c:a1e0::1234"): {UserID: ownerID, Login: "owner@example.com", Node: "mac6"},
		netip.MustParseAddr("100.99.99.99"):         {UserID: strangerID, Login: "stranger@example.com", Node: "shared"},
		netip.MustParseAddr("100.88.88.88"):         {UserID: ownerID, Login: "owner@example.com", Node: "ci", Tagged: true},
		netip.MustParseAddr("100.77.77.77"):         {UserID: 0, Node: "nouser"},
	}}
	c := &clock{now: time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)}
	srv := New(Options{
		Tailnet: ts, SelfUserID: ownerID, HostName: "testhost", TTL: time.Hour, Now: c.Now,
		PollInterval: 10 * time.Millisecond, Heartbeat: 50 * time.Millisecond,
	})
	t.Cleanup(srv.Close)
	token, err := srv.Register(root, "note.md")
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{t: t, server: srv, ts: ts, clock: c, root: root, outside: base, token: token}
}

type reply struct {
	status int
	code   string
	body   string
	header http.Header
}

// get은 요청 줄에 target을 글자 그대로 넣어 보냅니다(`..`이나 `%2e`가 중간에 정리되지 않습니다).
func (f *fixture) get(remote, target string) reply {
	f.t.Helper()
	request := httptest.NewRequest(http.MethodGet, target, nil)
	request.RemoteAddr = remote
	recorder := httptest.NewRecorder()
	f.server.ServeHTTP(recorder, request)
	body := recorder.Body.String()
	var parsed struct {
		Error string `json:"error"`
	}
	json.Unmarshal([]byte(body), &parsed)
	return reply{status: recorder.Code, code: parsed.Error, body: body, header: recorder.Header()}
}

func (f *fixture) file(path string) string { return "/v1/" + f.token + "/files/" + path }

func TestServesDocumentsAndImagesInsideRoot(t *testing.T) {
	f := newFixture(t)
	for path, want := range map[string]string{
		"note.md":     "# note",
		"other.md":    "# other",
		"sub/deep.md": "# deep",
		"img/a.png":   "PNGDATA",
	} {
		got := f.get(ownerPeer, f.file(path))
		if got.status != http.StatusOK || got.body != want {
			t.Errorf("%s: status %d body %q, want 200 %q", path, got.status, got.body, want)
		}
	}
	got := f.get(ownerPeer, f.file("note.md"))
	if got.header.Get("ETag") == "" || got.header.Get("X-Mdr-Doc-Id") == "" || got.header.Get("X-Mdr-Host") != "testhost" {
		t.Errorf("문서 응답 머리말이 빠졌습니다: %v", got.header)
	}
	if !strings.HasPrefix(got.header.Get("Content-Type"), "text/markdown") {
		t.Errorf("Content-Type = %q", got.header.Get("Content-Type"))
	}
	// 같은 문서는 token이 달라져도 같은 이름표를 갖습니다(읽던 자리의 키).
	if id := docID(f.root, "note.md"); id != got.header.Get("X-Mdr-Doc-Id") || id == docID(f.root, "other.md") {
		t.Errorf("문서 이름표가 경로에서 정해지지 않습니다")
	}
}

// 보안 경계 1: 문서 폴더 밖의 경로는 내주지 않습니다.
func TestPathEscapeIsRejected(t *testing.T) {
	f := newFixture(t)
	// 문서 폴더 안에서 밖을 가리키는 심볼릭 링크들
	link := func(target, name string) {
		t.Helper()
		if err := os.Symlink(target, filepath.Join(f.root, name)); err != nil {
			t.Fatal(err)
		}
	}
	link("../secret.md", "rel-link.md")
	link(filepath.Join(f.outside, "secret.md"), "abs-link.md")
	link("../secret.png", "rel-link.png")
	link("..", "updir")
	link(f.outside, "absdir")
	link("/etc", "etc")
	// 폴더 안을 가리키는 링크는 됩니다.
	link("other.md", "inside-link.md")

	cases := []string{
		"../secret.md",
		"../../secret.md",
		"sub/../../secret.md",
		"./../secret.md",
		"%2e%2e/secret.md",
		"%2E%2E/secret.md",
		".%2e/secret.md",
		"..%2fsecret.md",
		"..%2Fsecret.md",
		"%2e%2e%2fsecret.md",
		"sub%2f..%2f..%2fsecret.md",
		"..%5csecret.md",
		`..\secret.md`,
		"/etc/hosts",
		"%2fetc%2fhosts",
		"sub//../secret.md",
		"note.md%00.png",
		"note.md/../../secret.md",
		// 심볼릭 링크
		"rel-link.md",
		"abs-link.md",
		"rel-link.png",
		"updir/secret.md",
		"absdir/secret.md",
		"etc/hosts",
		"updir/docs/note.md",
		// 내주지 않는 종류
		"notes.txt",
		".env",
		"img",
		"sub",
		".",
		"",
	}
	for _, path := range cases {
		got := f.get(ownerPeer, f.file(path))
		if got.status != http.StatusForbidden && got.status != http.StatusNotFound {
			t.Errorf("%q: status %d, 403이나 404여야 합니다 (body %q)", path, got.status, got.body)
		}
		if strings.Contains(got.body, secretText) || strings.Contains(got.body, "PASSWORD") || strings.Contains(got.body, "localhost") {
			t.Errorf("%q: 폴더 밖 파일의 내용이 새어 나왔습니다: %q", path, got.body)
		}
	}
	// 변경 알림 주소로도 폴더 밖 파일의 존재를 알아낼 수 없어야 합니다.
	for _, path := range []string{"../secret.md", "%2e%2e/secret.md", "rel-link.md", "updir/secret.md"} {
		got := f.get(ownerPeer, "/v1/"+f.token+"/events/"+path)
		if got.status != http.StatusForbidden && got.status != http.StatusNotFound {
			t.Errorf("events %q: status %d", path, got.status)
		}
	}
	if got := f.get(ownerPeer, f.file("inside-link.md")); got.status != http.StatusOK || got.body != "# other" {
		t.Errorf("폴더 안을 가리키는 링크: status %d body %q", got.status, got.body)
	}
	// 두 번 인코딩한 경로는 그런 이름의 파일을 찾을 뿐, 폴더 밖으로 나가지 않습니다.
	if got := f.get(ownerPeer, f.file("%252e%252e/secret.md")); got.status != http.StatusNotFound {
		t.Errorf("두 번 인코딩: status %d", got.status)
	}
}

// 직접 연 문서는 확장자와 상관없이 내주지만, 같은 폴더의 다른 파일까지 풀리지는 않습니다.
func TestExplicitDocumentIsAllowedRegardlessOfExtension(t *testing.T) {
	f := newFixture(t)
	if got := f.get(ownerPeer, f.file("notes.txt")); got.status != http.StatusForbidden {
		t.Fatalf("등록 전: status %d", got.status)
	}
	token, err := f.server.Register(f.root, "notes.txt")
	if err != nil {
		t.Fatal(err)
	}
	if token != f.token {
		t.Errorf("같은 폴더는 같은 token을 다시 써야 합니다")
	}
	if got := f.get(ownerPeer, f.file("notes.txt")); got.status != http.StatusOK || got.body != "plain text" {
		t.Errorf("등록 후: status %d body %q", got.status, got.body)
	}
	if got := f.get(ownerPeer, f.file(".env")); got.status != http.StatusForbidden {
		t.Errorf(".env: status %d", got.status)
	}
}

func TestRegisterRejectsPathsOutsideRoot(t *testing.T) {
	f := newFixture(t)
	for _, rel := range []string{"../secret.md", "/etc/hosts", "", "sub/../../secret.md", "missing.md", "sub"} {
		if _, err := f.server.Register(f.root, rel); err == nil {
			t.Errorf("Register(%q)가 성공했습니다", rel)
		}
	}
	if _, err := f.server.Register("relative/root", "note.md"); err == nil {
		t.Errorf("상대 경로 폴더를 받았습니다")
	}
}

// 보안 경계 2: token이 틀리면 아무것도 내주지 않습니다.
func TestInvalidTokenIsRejected(t *testing.T) {
	f := newFixture(t)
	otherRoot := filepath.Join(f.outside, "elsewhere")
	os.MkdirAll(otherRoot, 0o755)
	os.WriteFile(filepath.Join(otherRoot, "a.md"), []byte("# elsewhere"), 0o644)
	otherToken, err := f.server.Register(otherRoot, "a.md")
	if err != nil {
		t.Fatal(err)
	}
	if otherToken == f.token {
		t.Fatal("다른 폴더가 같은 token을 받았습니다")
	}

	for _, token := range []string{"wrong", f.token + "x", f.token[:len(f.token)-1], strings.ToUpper(f.token), "", "..", "%2e%2e"} {
		for _, kind := range []string{"files", "events"} {
			got := f.get(ownerPeer, "/v1/"+token+"/"+kind+"/note.md")
			if got.status != http.StatusUnauthorized || got.code != "invalid_token" {
				t.Errorf("token %q %s: status %d code %q, want 401 invalid_token", token, kind, got.status, got.code)
			}
		}
	}
	// 틀린 token으로는 경로가 잘못됐다는 사실도 알 수 없습니다.
	if got := f.get(ownerPeer, "/v1/wrong/files/../secret.md"); got.status != http.StatusUnauthorized {
		t.Errorf("틀린 token + 폴더 밖 경로: status %d, want 401", got.status)
	}
	// 다른 폴더의 token으로는 이 폴더의 문서를 읽을 수 없습니다.
	if got := f.get(ownerPeer, "/v1/"+otherToken+"/files/note.md"); got.status != http.StatusNotFound {
		t.Errorf("다른 폴더의 token: status %d, want 404", got.status)
	}
	if got := f.get(ownerPeer, "/v1/"+otherToken+"/files/a.md"); got.status != http.StatusOK {
		t.Errorf("자기 폴더의 token: status %d", got.status)
	}
}

func TestTokenExpiresAfterTTLWithoutUse(t *testing.T) {
	f := newFixture(t)
	f.clock.Advance(59 * time.Minute)
	if got := f.get(ownerPeer, f.file("note.md")); got.status != http.StatusOK {
		t.Fatalf("만료 전: status %d", got.status)
	}
	// 쓰면 수명이 늘어납니다.
	f.clock.Advance(59 * time.Minute)
	if got := f.get(ownerPeer, f.file("note.md")); got.status != http.StatusOK {
		t.Fatalf("수명 연장 뒤: status %d", got.status)
	}
	f.clock.Advance(61 * time.Minute)
	expired := f.get(ownerPeer, f.file("note.md"))
	unknown := f.get(ownerPeer, "/v1/never-issued/files/note.md")
	if expired.status != http.StatusUnauthorized || expired.body != unknown.body {
		t.Errorf("만료된 token: status %d body %q, 모르는 token과 같아야 합니다(%q)", expired.status, expired.body, unknown.body)
	}
	if f.server.Sweep() {
		t.Errorf("쓰이지 않은 채 TTL이 지났는데 서버가 계속 살아 있으려 합니다")
	}
	if tokens, _ := f.server.Counts(); tokens != 0 {
		t.Errorf("만료된 token이 %d개 남았습니다", tokens)
	}
	// 다시 등록하면 새 token이 나옵니다.
	token, err := f.server.Register(f.root, "note.md")
	if err != nil || token == f.token {
		t.Errorf("다시 등록: token 재사용 %v, err %v", token == f.token, err)
	}
}

// 보안 경계 3: tailnet 주소가 아닌 상대는 받지 않습니다. bind와 별개로, 요청마다 상대 주소를 봅니다.
func TestNonTailnetPeerIsRejected(t *testing.T) {
	f := newFixture(t)
	for _, remote := range []string{
		"127.0.0.1:5000", "192.168.1.10:5000", "10.0.0.7:5000", "8.8.8.8:5000", "100.63.255.255:5000", "100.128.0.1:5000",
		"[::1]:5000", "[2001:db8::1]:5000", "[fd7a:115c:a1e1::1]:5000", "[::ffff:192.168.0.9]:5000", "not-an-address",
	} {
		got := f.get(remote, f.file("note.md"))
		if got.status != http.StatusForbidden || got.code != "forbidden_peer" {
			t.Errorf("%s: status %d code %q, want 403 forbidden_peer", remote, got.status, got.code)
		}
		if strings.Contains(got.body, "# note") {
			t.Errorf("%s: 문서 내용이 나갔습니다", remote)
		}
	}
	if f.ts.calls != 0 {
		t.Errorf("tailnet 주소가 아닌 상대에게 whois를 %d번 물었습니다", f.ts.calls)
	}
	// token이 틀렸는지도 알려 주지 않습니다.
	if got := f.get("192.168.1.10:5000", "/v1/wrong/files/note.md"); got.code != "forbidden_peer" {
		t.Errorf("tailnet 밖 + 틀린 token: code %q", got.code)
	}
	for _, remote := range []string{ownerPeer, "[fd7a:115c:a1e0::1234]:5000", "[::ffff:100.101.102.103]:5000"} {
		if got := f.get(remote, f.file("note.md")); got.status != http.StatusOK {
			t.Errorf("%s: status %d, want 200", remote, got.status)
		}
	}
}

// 보안 경계 4: whois로 서버 주인의 기기임을 확인하지 못하면 받지 않습니다.
func TestWhoisFailureIsRejected(t *testing.T) {
	f := newFixture(t)
	for name, remote := range map[string]string{
		"다른 계정의 기기(공유받은 기기)": "100.99.99.99:5000",
		"태그가 붙은 기기":          "100.88.88.88:5000",
		"계정이 없는 기기":          "100.77.77.77:5000",
		"whois가 모르는 주소":      "100.66.66.66:5000",
	} {
		got := f.get(remote, f.file("note.md"))
		if got.status != http.StatusForbidden || got.code != "forbidden_peer" {
			t.Errorf("%s: status %d code %q, want 403 forbidden_peer", name, got.status, got.code)
		}
	}

	// whois 자체가 실패하면(데몬이 죽었거나 응답이 없으면) 주인의 기기라도 받지 않습니다.
	f.ts.err = errors.New("tailscaled: connection refused")
	fresh := "100.101.102.103:41000"
	// 앞에서 통과한 적이 없으므로 기억해 둔 결과도 없습니다.
	if got := f.get(fresh, f.file("note.md")); got.status != http.StatusForbidden || got.code != "forbidden_peer" {
		t.Errorf("whois 실패: status %d code %q, want 403", got.status, got.code)
	}
	// 실패는 기억하지 않습니다. whois가 돌아오면 바로 받습니다.
	f.ts.err = nil
	if got := f.get(fresh, f.file("note.md")); got.status != http.StatusOK {
		t.Errorf("whois 복구 뒤: status %d", got.status)
	}
	// 통과한 결과는 30초만 기억합니다. 그 뒤에는 다시 묻고, 그때 실패하면 막습니다.
	calls := f.ts.calls
	if got := f.get(fresh, f.file("note.md")); got.status != http.StatusOK || f.ts.calls != calls {
		t.Errorf("30초 안: status %d, whois를 다시 물었습니다(%d → %d)", got.status, calls, f.ts.calls)
	}
	f.ts.err = errors.New("tailscaled: connection refused")
	f.clock.Advance(31 * time.Second)
	if got := f.get(fresh, f.file("note.md")); got.status != http.StatusForbidden {
		t.Errorf("기억이 끝난 뒤 whois 실패: status %d, want 403", got.status)
	}
}

func TestWhoisIsRequiredWhenTailnetClientIsMissing(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "a.md"), []byte("# a"), 0o644)
	srv := New(Options{SelfUserID: ownerID})
	defer srv.Close()
	token, err := srv.Register(root, "a.md")
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/"+token+"/files/a.md", nil)
	request.RemoteAddr = ownerPeer
	recorder := httptest.NewRecorder()
	srv.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusForbidden {
		t.Errorf("whois 없이 status %d, want 403", recorder.Code)
	}
}

func TestOnlyGetIsAllowed(t *testing.T) {
	f := newFixture(t)
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		request := httptest.NewRequest(method, f.file("note.md"), strings.NewReader("x"))
		request.RemoteAddr = ownerPeer
		recorder := httptest.NewRecorder()
		f.server.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s: status %d", method, recorder.Code)
		}
	}
	if got, _ := os.ReadFile(filepath.Join(f.root, "note.md")); string(got) != "# note" {
		t.Errorf("문서가 바뀌었습니다")
	}
}

func TestConditionalRequestReturnsNotModified(t *testing.T) {
	f := newFixture(t)
	first := f.get(ownerPeer, f.file("note.md"))
	request := httptest.NewRequest(http.MethodGet, f.file("note.md"), nil)
	request.RemoteAddr = ownerPeer
	request.Header.Set("If-None-Match", first.header.Get("ETag"))
	recorder := httptest.NewRecorder()
	f.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNotModified {
		t.Errorf("status %d, want 304", recorder.Code)
	}
}

// readEvent는 SSE 연결에서 다음 이벤트의 이름을 읽습니다. 주석 줄(ping)은 "ping"으로 돌려줍니다.
func readEvent(t *testing.T, reader *bufio.Reader) string {
	t.Helper()
	name := ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				return "eof"
			}
			t.Fatalf("이벤트를 읽지 못했습니다: %v", err)
		}
		line = strings.TrimRight(line, "\n")
		switch {
		case strings.HasPrefix(line, ": ping"):
			name = "ping"
		case strings.HasPrefix(line, "event: "):
			name = strings.TrimPrefix(line, "event: ")
		case line == "" && name != "":
			return name
		}
	}
}

func TestEventsReportChangesAndKeepTokenAlive(t *testing.T) {
	f := newFixture(t)
	// 실제 연결이 필요하므로 상대 확인을 끈 서버를 따로 씁니다(상대 확인은 위 테스트들이 봅니다).
	srv := New(Options{Insecure: true, TTL: time.Hour, Now: f.clock.Now, PollInterval: 10 * time.Millisecond, Heartbeat: 30 * time.Millisecond})
	defer srv.Close()
	token, err := srv.Register(f.root, "note.md")
	if err != nil {
		t.Fatal(err)
	}
	web := httptest.NewServer(srv)
	defer web.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, web.URL+"/v1/"+token+"/events/note.md", nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("status %d content-type %q", response.StatusCode, response.Header.Get("Content-Type"))
	}
	reader := bufio.NewReader(response.Body)
	if got := readEvent(t, reader); got != "hello" {
		t.Fatalf("첫 이벤트 %q, want hello", got)
	}
	if _, streams := srv.Counts(); streams != 1 {
		t.Errorf("열린 연결 수 %d, want 1", streams)
	}

	// 편집기처럼 임시 파일에 쓰고 이름을 바꿔 저장합니다.
	temp := filepath.Join(f.root, "note.md.tmp")
	os.WriteFile(temp, []byte("# note changed"), 0o644)
	if err := os.Rename(temp, filepath.Join(f.root, "note.md")); err != nil {
		t.Fatal(err)
	}
	sawChange, sawPing := false, false
	for !(sawChange && sawPing) {
		switch readEvent(t, reader) {
		case "change":
			sawChange = true
		case "ping":
			sawPing = true
		case "eof":
			t.Fatalf("연결이 끊겼습니다(change %v, ping %v)", sawChange, sawPing)
		}
	}

	// 연결이 열려 있는 동안에는 TTL이 지나도 token이 살아 있고, 서버도 끝나지 않습니다.
	f.clock.Advance(3 * time.Hour)
	if !srv.Sweep() {
		t.Errorf("연결이 열려 있는데 서버가 끝나려 합니다")
	}
	check, _ := http.Get(web.URL + "/v1/" + token + "/files/note.md")
	if check.StatusCode != http.StatusOK {
		t.Errorf("연결이 열려 있는 동안 token이 만료됐습니다: %d", check.StatusCode)
	}
	check.Body.Close()

	// 서버를 닫으면 연결이 끝납니다.
	srv.Close()
	for {
		if got := readEvent(t, reader); got == "eof" {
			break
		}
	}
}
