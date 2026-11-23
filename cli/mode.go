package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// localIdleLimit 안에 이 Mac의 키보드나 마우스를 썼으면 원이 이 Mac 앞에 있다고 봅니다.
const localIdleLimit = 5 * time.Minute

// detectMode는 앱을 바로 열지("open"), 링크를 출력할지("link") 정합니다.
//
// macOS라고 해서 "같은 Mac"인 것은 아닙니다. 원은 다른 Mac의 Rex 앱으로 이 Mac의 팬을 보기도 합니다.
// 그때 앱을 바로 열면 아무도 보지 않는 화면에 창이 뜹니다. 그래서 다음 순서로 가립니다.
//
//  1. macOS가 아니면 링크
//  2. SSH로 들어온 세션이면 링크
//  3. Rex 팬이면 그 세션을 보고 있는 Rex 앱을 봅니다. 이 Mac의 앱만 붙어 있으면 바로 열고,
//     다른 기기의 앱만 붙어 있으면 링크입니다.
//  4. 양쪽이 다 붙어 있거나 알 수 없으면, 이 Mac의 키보드·마우스를 최근에 썼는지로 가립니다.
//  5. Rex 밖의 로컬 터미널이면 바로 엽니다.
func detectMode() (mode, reason string) {
	if runtime.GOOS != "darwin" {
		return "link", "macOS가 아님"
	}
	if os.Getenv("SSH_CONNECTION") != "" || os.Getenv("SSH_TTY") != "" {
		return "link", "SSH 세션"
	}
	session := os.Getenv("REX_SESSION")
	if session == "" {
		return "open", "로컬 터미널"
	}
	local, remote, known := rexViewers(session)
	switch {
	case known && local && !remote:
		return "open", "이 Mac의 Rex 앱만 이 세션을 보고 있음"
	case known && remote && !local:
		return "link", "다른 기기의 Rex 앱이 이 세션을 보고 있음"
	}
	idle, ok := hidIdle()
	if ok && idle <= localIdleLimit {
		return "open", fmt.Sprintf("이 Mac을 %s 전에 사용함", idle.Round(time.Second))
	}
	if ok {
		return "link", fmt.Sprintf("이 Mac을 %s 동안 쓰지 않음", idle.Round(time.Minute))
	}
	return "link", "이 Mac 앞에 있는지 알 수 없음"
}

// rexViewers는 이 세션에 붙어 있는 Rex 앱이 이 Mac의 것인지, 다른 기기의 것인지 알려 줍니다.
// Rex 서버에 Unix 소켓으로 붙은 앱은 이 Mac의 앱이고, 그 밖(tailscale 등)은 다른 기기의 앱입니다.
func rexViewers(session string) (local, remote, known bool) {
	rex, err := exec.LookPath("rex")
	if err != nil {
		rex = filepath.Join(os.Getenv("REX_BIN_DIR"), "rex")
		if _, err := os.Stat(rex); err != nil {
			return false, false, false
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, rex, "client", "ls", "--json").Output()
	if err != nil {
		return false, false, false
	}
	var listing struct {
		Clients []struct {
			Info struct {
				Kind string `json:"kind"`
			} `json:"info"`
			Principal struct {
				Transport string `json:"transport"`
			} `json:"principal"`
			State      string   `json:"connection_state"`
			SessionIDs []string `json:"session_ids"`
		} `json:"clients"`
	}
	if json.Unmarshal(output, &listing) != nil {
		return false, false, false
	}
	for _, client := range listing.Clients {
		if client.Info.Kind != "app" || client.State != "connected" {
			continue
		}
		for _, id := range client.SessionIDs {
			if id != session {
				continue
			}
			if client.Principal.Transport == "unix" {
				local = true
			} else {
				remote = true
			}
		}
	}
	return local, remote, local || remote
}
