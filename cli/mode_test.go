package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDecideMode(t *testing.T) {
	cases := []struct {
		name    string
		signals modeSignals
		want    string
	}{
		{"Linux 호스트", modeSignals{}, "link"},
		{"Mac에 SSH로 들어옴", modeSignals{darwin: true, ssh: true}, "link"},
		{"Mac의 로컬 터미널(Rex 밖)", modeSignals{darwin: true}, "open"},
		{"Rex: 이 Mac의 앱만 붙음", modeSignals{darwin: true, inRex: true, rexKnown: true, rexLocal: true, idle: time.Hour, idleKnown: true}, "open"},
		{"Rex: 다른 기기의 앱만 붙음", modeSignals{darwin: true, inRex: true, rexKnown: true, rexRemote: true, idleKnown: true}, "link"},
		{"Rex: 양쪽 다 붙음, 방금 이 Mac을 씀", modeSignals{darwin: true, inRex: true, rexKnown: true, rexLocal: true, rexRemote: true, idle: 20 * time.Second, idleKnown: true}, "open"},
		{"Rex: 양쪽 다 붙음, 이 Mac을 오래 안 씀", modeSignals{darwin: true, inRex: true, rexKnown: true, rexLocal: true, rexRemote: true, idle: 3 * time.Hour, idleKnown: true}, "link"},
		{"Rex: 양쪽 다 붙음, 5분 경계", modeSignals{darwin: true, inRex: true, rexKnown: true, rexLocal: true, rexRemote: true, idle: 5 * time.Minute, idleKnown: true}, "open"},
		{"Rex: 붙은 앱을 알 수 없음, 방금 씀", modeSignals{darwin: true, inRex: true, idle: time.Second, idleKnown: true}, "open"},
		{"Rex: 아무것도 알 수 없음", modeSignals{darwin: true, inRex: true}, "link"},
	}
	for _, c := range cases {
		if got, reason := decideMode(c.signals); got != c.want || reason == "" {
			t.Errorf("%s: %s(%s), want %s", c.name, got, reason, c.want)
		}
	}
}

// --open은 `open -b <번들 식별자> -- <실제 경로>`를 실행합니다. 가짜 open으로 인자만 확인합니다.
func TestOpenModeRunsOpenWithBundleIDAndRealPath(t *testing.T) {
	box := newSandbox(t, "1h")
	stub := t.TempDir()
	record := filepath.Join(stub, "args.txt")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + record + "\n"
	if err := os.WriteFile(filepath.Join(stub, "open"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "link.md")
	if err := os.Symlink(filepath.Join(box.docs, "note.md"), link); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(binary, "--open", link)
	command.Env = append(box.env, "PATH="+stub+":"+os.Getenv("PATH"), "MDR_MODE=")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("mdr --open: %v: %s", err, output)
	}
	got, _ := os.ReadFile(record)
	real, _ := filepath.EvalSymlinks(filepath.Join(box.docs, "note.md"))
	want := "-b\nkim.two.mdr\n--\n" + real + "\n"
	if string(got) != want {
		t.Errorf("open 인자:\n%s\nwant:\n%s", got, want)
	}
	if !strings.Contains(string(output), "이 Mac의 mdr 앱으로 열었습니다") {
		t.Errorf("안내가 없습니다: %s", output)
	}
	if box.status() != nil {
		t.Errorf("바로 여는 데 서버를 띄웠습니다")
	}

	// 앱을 열지 못하면(자동 판단일 때) 링크로 넘어갑니다. --open을 직접 준 경우에는 실패로 끝냅니다.
	os.WriteFile(filepath.Join(stub, "open"), []byte("#!/bin/sh\necho 'Unable to find application' >&2\nexit 1\n"), 0o755)
	command = exec.Command(binary, "--open", link)
	command.Env = append(box.env, "PATH="+stub+":"+os.Getenv("PATH"), "MDR_MODE=")
	if output, err := command.CombinedOutput(); err == nil || !strings.Contains(string(output), "Unable to find application") {
		t.Errorf("앱이 없을 때: %v %s", err, output)
	}
}
