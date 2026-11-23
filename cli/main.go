// mdr는 마크다운 문서를 mdr 앱에서 여는 명령입니다.
//
//	mdr FILE...      문서를 엽니다. 이 Mac 앞에 앉아 있으면 앱을 바로 열고,
//	                 그렇지 않으면 서버로 내주고 누를 수 있는 링크를 출력합니다.
//	mdr serve        문서를 내주는 서버를 직접 띄웁니다(보통은 필요 없습니다).
//	mdr status       떠 있는 서버의 상태를 보여 줍니다.
//	mdr stop         떠 있는 서버를 끝냅니다.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mdr/internal/daemon"
	"mdr/internal/tailnet"
)

// version이 다르면 `mdr`가 떠 있는 서버를 끝내고 새로 띄웁니다. 프로토콜이나 서버 동작을 바꾸면 올립니다.
const version = "0.2.2"

const usage = `사용법:
  mdr [옵션] FILE...   문서를 mdr 앱에서 엽니다
  mdr serve            문서를 내주는 서버를 직접 띄웁니다(보통은 mdr FILE이 알아서 띄웁니다)
  mdr status           떠 있는 서버의 상태
  mdr stop             떠 있는 서버를 끝냅니다
  mdr version

옵션:
  --link        항상 서버로 내주고 링크를 출력합니다
  --open        항상 이 Mac의 앱으로 바로 엽니다
  --url         링크를 OSC 8 하이퍼링크 대신 글자 그대로 출력합니다
  --osc8        터미널이 아니어도 OSC 8 하이퍼링크로 출력합니다
  --root DIR    문서 폴더를 넓힙니다. 기본값은 문서가 있는 폴더이고, 서버는 이 폴더 밖을 내주지 않습니다
  --why         바로 열지 링크를 출력할지 어떻게 정했는지 알려 줍니다

환경 변수:
  MDR_MODE=link|open   --link, --open과 같습니다
  MDR_TTL=12h          링크가 마지막으로 쓰인 뒤 살아 있는 시간이자, 서버가 쓰이지 않을 때 기다리는 시간
  MDR_PORT=6370        서버가 먼저 시도하는 포트
  MDR_APP=/경로/mdr.app   바로 열 때 쓸 앱
  MDR_STATE_DIR        서버의 제어 소켓과 기록을 두는 폴더
`

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch args[0] {
	case "serve":
		err = runServe(args[1:])
	case "status":
		err = runStatus()
	case "stop":
		err = runStop()
	case "version", "--version":
		fmt.Println("mdr", version)
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		err = runOpen(args)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mdr:", err)
		os.Exit(1)
	}
}

func envDuration(name string, fallback time.Duration) time.Duration {
	if value := os.Getenv(name); value != "" {
		if parsed, err := time.ParseDuration(value); err == nil && parsed > 0 {
			return parsed
		}
		fmt.Fprintf(os.Stderr, "mdr: %s=%q를 읽을 수 없어 %s를 씁니다\n", name, value, fallback)
	}
	return fallback
}

func envInt(name string, fallback int) int {
	if value := os.Getenv(name); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil && parsed > 0 && parsed < 65536 {
			return parsed
		}
		fmt.Fprintf(os.Stderr, "mdr: %s=%q를 읽을 수 없어 %d를 씁니다\n", name, value, fallback)
	}
	return fallback
}

// MARK: serve / status / stop

func runServe(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	port := flags.Int("port", envInt("MDR_PORT", daemon.DefaultPort), "먼저 시도할 포트")
	ttl := flags.Duration("ttl", envDuration("MDR_TTL", 12*time.Hour), "쓰이지 않을 때 기다리는 시간")
	asDaemon := flags.Bool("daemon", false, "mdr FILE이 띄울 때 씁니다")
	if err := flags.Parse(args); err != nil {
		return err
	}
	paths, err := daemon.DefaultPaths()
	if err != nil {
		return err
	}
	config := daemon.Config{
		Paths:        paths,
		Version:      version,
		Port:         *port,
		TTL:          *ttl,
		InsecureBind: os.Getenv("MDR_INSECURE_DEV_BIND"),
		Logger:       log.New(os.Stderr, "", log.LstdFlags),
	}
	if config.InsecureBind == "" {
		config.Tailnet = tailnet.NewLocal()
	}
	if *asDaemon {
		// 띄운 쪽이 stderr를 기록 파일에 이어 두었습니다. 1MB를 넘으면 비우고 이어 씁니다.
		config.Logger = log.New(daemon.NewCappedLog(os.Stderr, 1<<20), "", log.LstdFlags)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	signal.Ignore(syscall.SIGHUP)

	ready := func(status daemon.Status, err error) {
		if !*asDaemon {
			if err == nil {
				fmt.Fprintf(os.Stderr, "mdr serve: http://%s 에서 듣습니다. 다른 터미널에서 `mdr FILE`로 문서를 여십시오\n", status.Addr)
			}
			return
		}
		// 띄운 쪽(`mdr FILE`)에 한 줄로 알리고 stdout을 닫습니다. 그 뒤로는 기록 파일에만 씁니다.
		switch {
		case err == nil:
			fmt.Println("ready")
		case errors.Is(err, daemon.ErrAlreadyRunning):
			fmt.Println("already-running")
		default:
			fmt.Println("error: " + strings.ReplaceAll(err.Error(), "\n", " "))
		}
		os.Stdout.Close()
	}
	err = daemon.Run(ctx, config, ready)
	if *asDaemon && err != nil {
		// 이유는 이미 띄운 쪽에 알렸습니다.
		log.Printf("serve: %v", err)
		os.Exit(1)
	}
	return err
}

func runStatus() error {
	paths, err := daemon.DefaultPaths()
	if err != nil {
		return err
	}
	status, err := daemon.NewClient(paths).Status(context.Background())
	if err != nil {
		fmt.Println("떠 있는 서버가 없습니다")
		return nil
	}
	encoded, _ := json.MarshalIndent(status, "", "  ")
	fmt.Println(string(encoded))
	return nil
}

func runStop() error {
	paths, err := daemon.DefaultPaths()
	if err != nil {
		return err
	}
	client := daemon.NewClient(paths)
	if _, err := client.Status(context.Background()); err != nil {
		fmt.Println("떠 있는 서버가 없습니다")
		return nil
	}
	if err := client.Stop(context.Background()); err != nil {
		return err
	}
	fmt.Println("서버를 끝냈습니다. 이전에 출력한 링크는 더 열리지 않습니다")
	return nil
}

// MARK: open

type openOptions struct {
	mode  string // "", "link", "open"
	why   bool
	plain bool
	osc8  bool
	root  string
	files []string
}

func parseOpenArgs(args []string) (openOptions, error) {
	options := openOptions{mode: os.Getenv("MDR_MODE")}
	for index := 0; index < len(args); index++ {
		argument := args[index]
		switch {
		case argument == "--link":
			options.mode = "link"
		case argument == "--open":
			options.mode = "open"
		case argument == "--why":
			options.why = true
		case argument == "--url":
			options.plain = true
		case argument == "--osc8":
			options.osc8 = true
		case argument == "--root":
			index++
			if index >= len(args) {
				return options, errors.New("--root 뒤에 폴더가 필요합니다")
			}
			options.root = args[index]
		case strings.HasPrefix(argument, "--root="):
			options.root = strings.TrimPrefix(argument, "--root=")
		case argument == "--":
			options.files = append(options.files, args[index+1:]...)
			index = len(args)
		case strings.HasPrefix(argument, "-") && argument != "-":
			return options, fmt.Errorf("모르는 옵션입니다: %s (mdr help 참고)", argument)
		default:
			options.files = append(options.files, argument)
		}
	}
	if len(options.files) == 0 {
		return options, errors.New("열 문서를 지정해 주십시오")
	}
	if options.mode != "" && options.mode != "link" && options.mode != "open" {
		return options, fmt.Errorf("MDR_MODE는 link 또는 open이어야 합니다: %q", options.mode)
	}
	return options, nil
}

func runOpen(args []string) error {
	options, err := parseOpenArgs(args)
	if err != nil {
		return err
	}
	// 실제 경로로 바꿉니다. 문서 옆의 이미지와 다른 문서를 그 폴더 기준으로 찾기 때문입니다.
	var files []string
	for _, name := range options.files {
		absolute, err := filepath.Abs(name)
		if err != nil {
			return err
		}
		real, err := filepath.EvalSymlinks(absolute)
		if err != nil {
			return fmt.Errorf("문서를 찾을 수 없습니다: %s", name)
		}
		info, err := os.Stat(real)
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("일반 파일이 아닙니다: %s", name)
		}
		files = append(files, real)
	}

	mode, reason := options.mode, "지정한 방식"
	if mode == "" {
		mode, reason = detectMode()
	}
	if options.why {
		fmt.Fprintf(os.Stderr, "mdr: %s → %s\n", reason, map[string]string{"open": "이 Mac의 앱으로 엽니다", "link": "링크를 출력합니다"}[mode])
	}
	if mode == "open" {
		err := openLocally(files)
		if err == nil {
			fmt.Fprintf(os.Stderr, "이 Mac의 mdr 앱으로 열었습니다(%s). 다른 기기에서 보려면 mdr --link를 쓰십시오\n", reason)
			return nil
		}
		if options.mode == "open" {
			return err
		}
		fmt.Fprintf(os.Stderr, "mdr: 이 Mac의 앱으로 열지 못해 링크를 출력합니다: %v\n", err)
	}
	return printLinks(options, files)
}

func printLinks(options openOptions, files []string) error {
	paths, err := daemon.DefaultPaths()
	if err != nil {
		return err
	}
	ctx := context.Background()
	client, status, _, err := daemon.Ensure(ctx, paths, daemon.Spawn{
		Version: version,
		Port:    envInt("MDR_PORT", daemon.DefaultPort),
		TTL:     envDuration("MDR_TTL", 12*time.Hour),
	})
	if err != nil {
		return err
	}
	if status.Insecure {
		fmt.Fprintln(os.Stderr, "mdr: 경고: 서버가 테스트 모드입니다(상대를 확인하지 않습니다)")
	}
	hyperlink := !options.plain && (options.osc8 || isTerminal(os.Stdout))
	for _, file := range files {
		root := filepath.Dir(file)
		if options.root != "" {
			if root, err = filepath.Abs(options.root); err != nil {
				return err
			}
			if root, err = filepath.EvalSymlinks(root); err != nil {
				return fmt.Errorf("문서 폴더를 찾을 수 없습니다: %s", options.root)
			}
		}
		rel, err := filepath.Rel(root, file)
		if err != nil || !filepath.IsLocal(rel) {
			return fmt.Errorf("%s 가 문서 폴더 %s 안에 있지 않습니다", file, root)
		}
		reply, err := client.Register(ctx, root, filepath.ToSlash(rel))
		if err != nil {
			return err
		}
		link := documentLink(reply)
		if hyperlink {
			// OSC 8: 화면에는 파일 이름만 보이고, 누르면 링크가 열립니다.
			fmt.Printf("\x1b]8;;%s\x1b\\%s\x1b]8;;\x1b\\\n", link, filepath.Base(file))
		} else {
			fmt.Println(link)
		}
	}
	return nil
}

// documentLink는 `mdr://<host>:<port>/<token>/<path>`를 만듭니다.
func documentLink(reply daemon.RegisterReply) string {
	segments := strings.Split(reply.Rel, "/")
	for index, segment := range segments {
		segments[index] = url.PathEscape(segment)
	}
	return "mdr://" + net.JoinHostPort(reply.Host, strconv.Itoa(reply.Port)) + "/" + reply.Token + "/" + strings.Join(segments, "/")
}

func isTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// appBundleID는 mdr 앱의 번들 식별자입니다(project.yml과 같아야 합니다).
const appBundleID = "dev.mdr.app"

func openLocally(files []string) error {
	arguments := []string{"-b", appBundleID}
	if app := os.Getenv("MDR_APP"); app != "" {
		arguments = []string{"-a", app}
	}
	arguments = append(arguments, "--")
	arguments = append(arguments, files...)
	output, err := exec.Command("open", arguments...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(string(output)))
	}
	return nil
}
