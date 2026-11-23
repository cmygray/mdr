package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// Client는 제어 소켓으로 서버와 이야기합니다.
type Client struct {
	paths Paths
	http  *http.Client
}

func NewClient(paths Paths) *Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "unix", paths.Socket)
		},
		DisableKeepAlives: true,
	}
	return &Client{paths: paths, http: &http.Client{Transport: transport, Timeout: 15 * time.Second}}
}

func (c *Client) call(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, "http://mdr"+path, reader)
	if err != nil {
		return err
	}
	response, err := c.http.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		var failure struct {
			Error string `json:"error"`
		}
		json.NewDecoder(response.Body).Decode(&failure)
		if failure.Error == "" {
			failure.Error = response.Status
		}
		return errors.New(failure.Error)
	}
	return json.NewDecoder(response.Body).Decode(out)
}

func (c *Client) Status(ctx context.Context) (Status, error) {
	var status Status
	err := c.call(ctx, http.MethodGet, "/status", nil, &status)
	return status, err
}

func (c *Client) Register(ctx context.Context, root, rel string) (RegisterReply, error) {
	var reply RegisterReply
	err := c.call(ctx, http.MethodPost, "/register", RegisterRequest{Root: root, Rel: rel}, &reply)
	return reply, err
}

// Stop은 서버를 끝내고, 제어 소켓이 사라질 때까지 기다립니다.
func (c *Client) Stop(ctx context.Context) error {
	var status Status
	if err := c.call(ctx, http.MethodPost, "/stop", nil, &status); err != nil {
		return err
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := c.Status(ctx); err != nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("서버가 끝나지 않았습니다")
}

// Spawn은 서버를 띄울 때 넘기는 값입니다.
type Spawn struct {
	Version string
	Port    int
	TTL     time.Duration
}

// Ensure는 살아 있는 서버를 찾거나, 없으면 띄웁니다. 새로 띄웠으면 started가 true입니다.
//
// 버전이 다른 서버가 떠 있으면(바이너리를 바꾼 뒤) 끝내고 새로 띄웁니다. 이때 이전 링크는 쓸 수 없게 됩니다.
func Ensure(ctx context.Context, paths Paths, spawn Spawn) (client *Client, status Status, started bool, err error) {
	client = NewClient(paths)
	if status, err = client.Status(ctx); err == nil {
		if status.Version == spawn.Version {
			return client, status, false, nil
		}
		if err = client.Stop(ctx); err != nil {
			return nil, Status{}, false, fmt.Errorf("이전 버전(%s) 서버를 끝내지 못했습니다: %w", status.Version, err)
		}
	}
	if err = start(paths, spawn); err != nil && !errors.Is(err, ErrAlreadyRunning) {
		return nil, Status{}, false, err
	}
	// 다른 `mdr`가 동시에 띄우고 있을 수 있습니다. 어느 쪽이 띄웠든 소켓이 열릴 때까지 기다립니다.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if status, err = client.Status(ctx); err == nil {
			return client, status, true, nil
		}
		if time.Now().After(deadline) {
			return nil, Status{}, false, fmt.Errorf("서버가 응답하지 않습니다(%s 참고): %w", paths.Log, err)
		}
		time.Sleep(30 * time.Millisecond)
	}
}

// start는 자기 자신을 `serve --daemon`으로 다시 실행합니다. 자식은 터미널에서 떨어져 나와 혼자 돕니다.
// 자식이 준비됐다는 한 줄(또는 실패한 이유)을 stdout으로 보낼 때까지 기다립니다.
func start(paths Paths, spawn Spawn) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(paths.Dir, 0o700); err != nil {
		return err
	}
	// 기록이 끝없이 자라지 않게, 1MB를 넘으면 비우고 시작합니다.
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(paths.Log); err == nil && info.Size() > 1<<20 {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	logFile, err := os.OpenFile(paths.Log, flags, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		return err
	}
	defer readEnd.Close()

	args := []string{"serve", "--daemon", "--ttl", spawn.TTL.String()}
	if spawn.Port != 0 {
		args = append(args, "--port", FormatPort(spawn.Port))
	}
	command := exec.Command(executable, args...)
	command.Dir = "/"
	command.Stdin = nil
	command.Stdout = writeEnd
	command.Stderr = logFile
	// 새 세션으로 띄워, 터미널을 닫아도 서버가 따라 죽지 않게 합니다.
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		writeEnd.Close()
		return fmt.Errorf("서버를 띄우지 못했습니다: %w", err)
	}
	writeEnd.Close()
	go command.Wait()

	line := make(chan string, 1)
	go func() {
		text, _ := bufio.NewReader(readEnd).ReadString('\n')
		line <- strings.TrimSpace(text)
	}()
	select {
	case text := <-line:
		switch {
		case text == "ready":
			return nil
		case text == "already-running":
			return ErrAlreadyRunning
		case strings.HasPrefix(text, "error: "):
			return errors.New(strings.TrimPrefix(text, "error: "))
		default:
			return fmt.Errorf("서버가 시작하다가 끝났습니다(%s 참고)", paths.Log)
		}
	case <-time.After(15 * time.Second):
		return fmt.Errorf("서버가 15초 안에 준비되지 않았습니다(%s 참고)", paths.Log)
	}
}
