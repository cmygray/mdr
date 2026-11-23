package server

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// grant는 token 하나가 열어 주는 범위입니다. 문서 폴더(root) 하나와 그 아래 파일만 읽을 수 있습니다.
type grant struct {
	token    string
	rootPath string
	// root는 폴더를 연 손잡이입니다. 이 손잡이로 여는 파일은 커널이 폴더 밖으로 나가지 못하게 막습니다.
	root    *os.Root
	expires time.Time
	streams int
	// explicit는 `mdr <file>`로 직접 연 문서입니다. 확장자 제한과 상관없이 내줍니다.
	explicit map[string]bool
}

// store는 살아 있는 token을 들고 있습니다. token은 메모리에만 있고, 서버가 끝나면 모두 사라집니다.
type store struct {
	mu     sync.Mutex
	byHash map[[sha256.Size]byte]*grant
	byRoot map[string]*grant
	ttl    time.Duration
	now    func() time.Time
	// lastActivity는 마지막으로 등록이나 승인된 요청이 있었던 시각입니다. 서버가 스스로 끝날 때를 정합니다.
	lastActivity time.Time
}

func newStore(ttl time.Duration, now func() time.Time) *store {
	return &store{
		byHash:       map[[sha256.Size]byte]*grant{},
		byRoot:       map[string]*grant{},
		ttl:          ttl,
		now:          now,
		lastActivity: now(),
	}
}

func newToken() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// register는 root 폴더의 token을 돌려줍니다. 같은 폴더에 살아 있는 token이 있으면 그것을 다시 쓰고 수명을 늘립니다.
// rel은 그 폴더 안에서 직접 연 문서의 경로입니다.
func (s *store) register(rootPath, rel string) (string, error) {
	real, err := filepath.EvalSymlinks(rootPath)
	if err != nil {
		return "", fmt.Errorf("문서 폴더를 열 수 없습니다: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.lastActivity = now
	if g, ok := s.byRoot[real]; ok && (g.streams > 0 || now.Before(g.expires)) {
		g.expires = now.Add(s.ttl)
		g.explicit[rel] = true
		return g.token, nil
	}
	root, err := os.OpenRoot(real)
	if err != nil {
		return "", fmt.Errorf("문서 폴더를 열 수 없습니다: %w", err)
	}
	token, err := newToken()
	if err != nil {
		root.Close()
		return "", err
	}
	if old, ok := s.byRoot[real]; ok {
		s.dropLocked(old)
	}
	g := &grant{token: token, rootPath: real, root: root, expires: now.Add(s.ttl), explicit: map[string]bool{rel: true}}
	s.byHash[sha256.Sum256([]byte(token))] = g
	s.byRoot[real] = g
	return token, nil
}

// lookup은 token이 살아 있으면 그 범위를 돌려주고 수명을 늘립니다. 모르는 token과 만료된 token은 구별하지 않습니다.
//
// token 문자열을 직접 비교하지 않고 해시로 찾습니다. 비교에 걸린 시간으로 token을 한 글자씩 맞혀 가는 공격을 막습니다.
func (s *store) lookup(token string) (*grant, bool) {
	if token == "" {
		return nil, false
	}
	key := sha256.Sum256([]byte(token))
	s.mu.Lock()
	defer s.mu.Unlock()
	g, ok := s.byHash[key]
	if !ok {
		return nil, false
	}
	now := s.now()
	if g.streams == 0 && !now.Before(g.expires) {
		s.dropLocked(g)
		return nil, false
	}
	g.expires = now.Add(s.ttl)
	s.lastActivity = now
	return g, true
}

func (s *store) isExplicit(g *grant, rel string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return g.explicit[rel]
}

var errTooManyStreams = errors.New("too many streams")

const maxStreams = 128

// acquireStream은 변경 알림 연결을 하나 셉니다. 연결이 열려 있는 동안 token은 만료되지 않습니다.
func (s *store) acquireStream(g *grant) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	total := 0
	for _, other := range s.byHash {
		total += other.streams
	}
	if total >= maxStreams {
		return errTooManyStreams
	}
	g.streams++
	return nil
}

func (s *store) releaseStream(g *grant) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g.streams--
	now := s.now()
	g.expires = now.Add(s.ttl)
	s.lastActivity = now
}

// touch는 열린 연결이 살아 있음을 기록합니다.
func (s *store) touch(g *grant) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	g.expires = now.Add(s.ttl)
	s.lastActivity = now
}

func (s *store) dropLocked(g *grant) {
	delete(s.byHash, sha256.Sum256([]byte(g.token)))
	if s.byRoot[g.rootPath] == g {
		delete(s.byRoot, g.rootPath)
	}
	g.root.Close()
}

// sweep은 만료된 token을 지웁니다. 서버가 더 살아 있어야 하면 true를 돌려줍니다.
// 열린 연결이 없고 마지막 활동에서 ttl이 지났으면 false입니다.
func (s *store) sweep() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	streams := 0
	for _, g := range s.byHash {
		if g.streams > 0 {
			streams += g.streams
			continue
		}
		if !now.Before(g.expires) {
			s.dropLocked(g)
		}
	}
	return streams > 0 || now.Sub(s.lastActivity) < s.ttl
}

func (s *store) counts() (tokens, streams int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, g := range s.byHash {
		tokens++
		streams += g.streams
	}
	return
}

func (s *store) closeAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, g := range s.byHash {
		g.root.Close()
	}
	s.byHash = map[[sha256.Size]byte]*grant{}
	s.byRoot = map[string]*grant{}
}
