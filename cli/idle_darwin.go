package main

import (
	"context"
	"os/exec"
	"regexp"
	"strconv"
	"time"
)

var idlePattern = regexp.MustCompile(`"HIDIdleTime" = (\d+)`)

// hidIdle은 이 Mac의 키보드·마우스가 마지막으로 쓰인 뒤 지난 시간입니다.
func hidIdle() (time.Duration, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "ioreg", "-c", "IOHIDSystem", "-r", "-d", "1").Output()
	if err != nil {
		return 0, false
	}
	match := idlePattern.FindSubmatch(output)
	if match == nil {
		return 0, false
	}
	nanoseconds, err := strconv.ParseInt(string(match[1]), 10, 64)
	if err != nil {
		return 0, false
	}
	return time.Duration(nanoseconds), true
}
