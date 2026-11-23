package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"mdr/internal/daemon"
)

// 이 파일은 빌드한 바이너리를 실제로 실행해 서버의 수명을 확인합니다.
// Tailscale 없이도 돌 수 있게 테스트 모드(MDR_INSECURE_DEV_BIND=127.0.0.1)를 씁니다.
// tailnet 주소 bind와 whois는 internal/server, internal/daemon의 테스트와 scripts/verify-remote.sh가 봅니다.

var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "mdr-test-bin")
	if err != nil {
		panic(err)
	}
	binary = filepath.Join(dir, "mdr")
	if output, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "빌드 실패: %v\n%s", err, output)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type sandbox struct {
	t     *testing.T
	state string
	docs  string
	env   []string
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

func newSandbox(t *testing.T, ttl string) *sandbox {
	t.Helper()
	// Unix 소켓 경로는 길이 제한(약 100자)이 있어 짧은 폴더를 씁니다.
	state, err := os.MkdirTemp("/tmp", "mdr-st")
	if err != nil {
		t.Fatal(err)
	}
	docs := t.TempDir()
	if err := os.WriteFile(filepath.Join(docs, "note.md"), []byte("# note\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	box := &sandbox{t: t, state: state, docs: docs}
	box.env = append(os.Environ(),
		"MDR_STATE_DIR="+state,
		"MDR_INSECURE_DEV_BIND=127.0.0.1",
		"MDR_PORT="+strconv.Itoa(freePort(t)),
		"MDR_TTL="+ttl,
		"MDR_MODE=link",
	)
	t.Cleanup(func() {
		box.run("stop")
		os.RemoveAll(state)
	})
	return box
}

func (b *sandbox) run(args ...string) (stdout string, err error) {
	b.t.Helper()
	command := exec.Command(binary, args...)
	command.Env = b.env
	var out, errOut bytes.Buffer
	command.Stdout, command.Stderr = &out, &errOut
	err = command.Run()
	if err != nil {
		err = fmt.Errorf("%v: %s", err, errOut.String())
	}
	return strings.TrimSpace(out.String()), err
}

func (b *sandbox) link() string {
	b.t.Helper()
	out, err := b.run("--url", filepath.Join(b.docs, "note.md"))
	if err != nil {
		b.t.Fatalf("mdr 실행 실패: %v", err)
	}
	if !strings.HasPrefix(out, "mdr://127.0.0.1:") {
		b.t.Fatalf("링크가 아닙니다: %q", out)
	}
	return out
}

// status는 서버가 떠 있으면 그 상태를, 없으면 nil을 돌려줍니다.
func (b *sandbox) status() *daemon.Status {
	b.t.Helper()
	out, err := b.run("status")
	if err != nil {
		b.t.Fatalf("status 실패: %v", err)
	}
	var status daemon.Status
	if json.Unmarshal([]byte(out), &status) != nil {
		return nil
	}
	return &status
}

// fetch는 링크를 앱이 하듯 HTTP 주소로 바꿔 가져옵니다.
func fetch(link string) (int, string) {
	rest := strings.TrimPrefix(link, "mdr://")
	host, tail, _ := strings.Cut(rest, "/")
	token, path, _ := strings.Cut(tail, "/")
	response, err := http.Get("http://" + host + "/v1/" + token + "/files/" + path)
	if err != nil {
		return 0, err.Error()
	}
	defer response.Body.Close()
	var body bytes.Buffer
	body.ReadFrom(response.Body)
	return response.StatusCode, body.String()
}

func TestOneCommandStartsServerAndReusesIt(t *testing.T) {
	box := newSandbox(t, "1h")
	if box.status() != nil {
		t.Fatal("시작 전에 서버가 떠 있습니다")
	}
	first := box.link()
	started := box.status()
	if started == nil {
		t.Fatal("mdr FILE 뒤에 서버가 떠 있지 않습니다")
	}
	if code, body := fetch(first); code != http.StatusOK || body != "# note\n" {
		t.Fatalf("링크로 문서를 가져오지 못했습니다: %d %q", code, body)
	}
	// 두 번째 실행은 같은 서버를 쓰고, 같은 폴더이므로 같은 링크를 줍니다.
	second := box.link()
	again := box.status()
	if again == nil || again.PID != started.PID {
		t.Errorf("서버가 다시 떴습니다: pid %d → %v", started.PID, again)
	}
	if second != first {
		t.Errorf("같은 문서의 링크가 달라졌습니다:\n%s\n%s", first, second)
	}
	// 서버는 띄운 명령과 다른 세션에 있어, 터미널을 닫아도 따라 죽지 않습니다.
	sid, err := syscall.Getsid(started.PID)
	mine, _ := syscall.Getsid(os.Getpid())
	if err != nil || sid == mine || sid != started.PID {
		t.Errorf("서버가 새 세션의 주인이 아닙니다: sid %d, 테스트의 sid %d, pid %d (%v)", sid, mine, started.PID, err)
	}
	// 제어 소켓과 상태 폴더는 본인만 쓸 수 있습니다.
	for name, want := range map[string]os.FileMode{"": 0o700, "ctl.sock": 0o600, "serve.log": 0o600} {
		info, err := os.Stat(filepath.Join(box.state, name))
		if err != nil || info.Mode().Perm() != want {
			t.Errorf("%q 권한: %v (%v), want %o", name, info.Mode().Perm(), err, want)
		}
	}
}

func TestNextRunRecoversAfterServerIsKilled(t *testing.T) {
	box := newSandbox(t, "1h")
	old := box.link()
	before := box.status()
	// 호스트 재시작이나 강제 종료처럼, 정리할 틈 없이 죽입니다. 소켓 파일은 그대로 남습니다.
	if err := syscall.Kill(before.PID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(before.PID, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(box.state, "ctl.sock")); err != nil {
		t.Fatalf("죽은 서버의 소켓 파일이 남아 있어야 이 테스트가 의미가 있습니다: %v", err)
	}
	if box.status() != nil {
		t.Fatal("죽은 서버가 응답합니다")
	}
	fresh := box.link()
	after := box.status()
	if after == nil || after.PID == before.PID {
		t.Fatalf("새 서버가 뜨지 않았습니다: %v", after)
	}
	if code, _ := fetch(fresh); code != http.StatusOK {
		t.Errorf("새 링크: status %d", code)
	}
	// 이전 링크의 token은 죽은 서버와 함께 사라졌습니다.
	if fresh == old {
		t.Errorf("서버가 다시 떴는데 token이 같습니다")
	}
	if code, _ := fetch(old); code != http.StatusUnauthorized {
		t.Errorf("이전 링크: status %d, want 401", code)
	}
}

func TestConcurrentRunsShareOneServer(t *testing.T) {
	box := newSandbox(t, "1h")
	const runs = 12
	links := make([]string, runs)
	errs := make([]error, runs)
	var group sync.WaitGroup
	for index := range runs {
		group.Add(1)
		go func() {
			defer group.Done()
			links[index], errs[index] = box.run("--url", filepath.Join(box.docs, "note.md"))
		}()
	}
	group.Wait()
	for index := range runs {
		if errs[index] != nil {
			t.Fatalf("실행 %d 실패: %v", index, errs[index])
		}
		if links[index] != links[0] {
			t.Errorf("실행 %d의 링크가 다릅니다(서버가 둘 떴을 수 있습니다): %s vs %s", index, links[index], links[0])
		}
	}
	out, _ := exec.Command("pgrep", "-f", binary+" serve --daemon").Output()
	if pids := strings.Fields(string(out)); len(pids) != 1 {
		t.Errorf("서버 프로세스가 %d개입니다: %v", len(pids), pids)
	}
}

func TestServerExitsWhenIdleAndNextRunStartsANewOne(t *testing.T) {
	box := newSandbox(t, "1s")
	link := box.link()
	first := box.status()
	if first == nil {
		t.Fatal("서버가 뜨지 않았습니다")
	}
	// 쓰는 동안에는 살아 있습니다.
	for range 4 {
		time.Sleep(400 * time.Millisecond)
		if code, _ := fetch(link); code != http.StatusOK {
			t.Fatalf("쓰는 중에 링크가 죽었습니다: %d", code)
		}
	}
	if now := box.status(); now == nil || now.PID != first.PID {
		t.Fatalf("쓰는 중에 서버가 끝났습니다: %v", now)
	}
	// 아무도 쓰지 않으면 스스로 끝나고, 소켓 파일도 치웁니다.
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(first.PID, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatal("쓰이지 않는데도 서버가 끝나지 않았습니다")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(box.state, "ctl.sock")); !os.IsNotExist(err) {
		t.Errorf("끝난 서버의 소켓 파일이 남았습니다: %v", err)
	}
	// 다음 실행은 새 서버를 띄웁니다.
	if code, _ := fetch(box.link()); code != http.StatusOK {
		t.Errorf("다시 띄운 서버의 링크: status %d", code)
	}
	if second := box.status(); second == nil || second.PID == first.PID {
		t.Errorf("새 서버가 아닙니다: %v", second)
	}
}

func TestStopEndsServerAndInvalidatesLinks(t *testing.T) {
	box := newSandbox(t, "1h")
	link := box.link()
	pid := box.status().PID
	if out, err := box.run("stop"); err != nil || !strings.Contains(out, "끝냈습니다") {
		t.Fatalf("stop: %q %v", out, err)
	}
	if box.status() != nil || syscall.Kill(pid, 0) == nil {
		t.Errorf("stop 뒤에도 서버가 살아 있습니다")
	}
	if code, _ := fetch(link); code != 0 {
		t.Errorf("stop 뒤 링크: status %d, 연결이 거부되어야 합니다", code)
	}
}

func TestLinkCoversOnlyTheDocumentFolder(t *testing.T) {
	box := newSandbox(t, "1h")
	os.MkdirAll(filepath.Join(box.docs, "sub dir"), 0o755)
	os.WriteFile(filepath.Join(box.docs, "sub dir", "한글 문서.md"), []byte("# 한글\n"), 0o644)
	os.WriteFile(filepath.Join(box.docs, "sub dir", "pic.png"), []byte("PNG"), 0o644)

	out, err := box.run("--url", filepath.Join(box.docs, "sub dir", "한글 문서.md"))
	if err != nil {
		t.Fatal(err)
	}
	// 기본 문서 폴더는 문서가 있는 폴더입니다. 링크의 경로는 그 폴더 기준이고, 공백과 한글은 인코딩됩니다.
	if !strings.HasSuffix(out, "/%ED%95%9C%EA%B8%80%20%EB%AC%B8%EC%84%9C.md") || strings.Contains(out, "sub") {
		t.Errorf("링크: %s", out)
	}
	if code, body := fetch(out); code != http.StatusOK || body != "# 한글\n" {
		t.Errorf("문서: %d %q", code, body)
	}
	base := out[:strings.LastIndex(out, "/")]
	if code, _ := fetch(base + "/pic.png"); code != http.StatusOK {
		t.Errorf("문서 옆 이미지: %d", code)
	}
	// 윗 폴더의 문서는 이 링크의 token으로 읽을 수 없습니다.
	if code, _ := fetch(base + "/../note.md"); code == http.StatusOK {
		t.Errorf("윗 폴더의 문서가 읽혔습니다")
	}

	// --root로 넓히면 링크의 경로가 그 폴더 기준이 되고, 윗 폴더의 문서도 같은 token으로 읽힙니다.
	wide, err := box.run("--url", "--root", box.docs, filepath.Join(box.docs, "sub dir", "한글 문서.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(wide, "/sub%20dir/") {
		t.Errorf("--root 링크: %s", wide)
	}
	wideBase := wide[:strings.Index(wide, "/sub%20dir/")]
	if code, body := fetch(wideBase + "/note.md"); code != http.StatusOK || body != "# note\n" {
		t.Errorf("--root 뒤 윗 폴더 문서: %d %q", code, body)
	}
	// 문서가 --root 밖에 있으면 거절합니다.
	if _, err := box.run("--url", "--root", filepath.Join(box.docs, "sub dir"), filepath.Join(box.docs, "note.md")); err == nil {
		t.Errorf("문서 폴더 밖의 문서를 받았습니다")
	}
}

func TestOutputIsOSC8HyperlinkShowingOnlyTheFileName(t *testing.T) {
	box := newSandbox(t, "1h")
	plain := box.link()
	out, err := box.run("--osc8", filepath.Join(box.docs, "note.md"))
	if err != nil {
		t.Fatal(err)
	}
	want := "\x1b]8;;" + plain + "\x1b\\note.md\x1b]8;;\x1b\\"
	if out != want {
		t.Errorf("OSC 8 출력이 다릅니다:\n got %q\nwant %q", out, want)
	}
}

func TestMissingFileAndUnknownOptionFailClearly(t *testing.T) {
	box := newSandbox(t, "1h")
	if _, err := box.run(filepath.Join(box.docs, "nope.md")); err == nil || !strings.Contains(err.Error(), "찾을 수 없습니다") {
		t.Errorf("없는 파일: %v", err)
	}
	if _, err := box.run(box.docs); err == nil || !strings.Contains(err.Error(), "일반 파일이 아닙니다") {
		t.Errorf("폴더: %v", err)
	}
	if _, err := box.run("--nope", filepath.Join(box.docs, "note.md")); err == nil || !strings.Contains(err.Error(), "모르는 옵션") {
		t.Errorf("모르는 옵션: %v", err)
	}
	if box.status() != nil {
		t.Errorf("실패한 실행이 서버를 띄웠습니다")
	}
}
