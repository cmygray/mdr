// Package tailnet은 이 기기의 Tailscale 데몬에게 "나는 누구인가"와 "이 주소는 누구인가"를 묻습니다.
//
// 서버의 보안 경계 가운데 둘(tailnet 주소에만 bind, 원의 계정만 허용)이 여기에 기댑니다.
// 테스트에서는 Client를 가짜로 바꿔 끼웁니다.
package tailnet

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"

	"tailscale.com/client/local"
)

var (
	cgnat = netip.MustParsePrefix("100.64.0.0/10")
	ula   = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// IsTailnetIP는 주소가 Tailscale이 기기에 주는 범위 안에 있는지 알려 줍니다.
func IsTailnetIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	return cgnat.Contains(ip) || ula.Contains(ip)
}

// Self는 이 기기의 tailnet 정보입니다.
type Self struct {
	IPs      []netip.Addr
	HostName string
	UserID   int64
	Login    string
}

// Peer는 접속해 온 상대의 신원입니다.
type Peer struct {
	UserID int64
	Login  string
	Node   string
	// Tagged이면 사람 계정이 아니라 태그가 소유한 기기입니다.
	Tagged bool
}

// Client는 Tailscale 데몬에 묻는 두 가지 질문입니다.
type Client interface {
	Self(ctx context.Context) (Self, error)
	WhoIs(ctx context.Context, remote netip.AddrPort) (Peer, error)
}

// ErrNotRunning은 Tailscale 데몬에 닿았지만 tailnet에 연결돼 있지 않을 때 돌려줍니다.
var ErrNotRunning = errors.New("Tailscale이 연결돼 있지 않습니다")

// Local은 이 기기에서 도는 tailscaled의 LocalAPI를 씁니다.
type Local struct {
	lc local.Client
}

func NewLocal() *Local { return &Local{} }

func (l *Local) Self(ctx context.Context) (Self, error) {
	st, err := l.lc.StatusWithoutPeers(ctx)
	if err != nil {
		return Self{}, fmt.Errorf("Tailscale 데몬에 연결하지 못했습니다: %w", err)
	}
	if st.BackendState != "Running" || st.Self == nil {
		return Self{}, fmt.Errorf("%w (상태: %s)", ErrNotRunning, st.BackendState)
	}
	self := Self{HostName: st.Self.HostName, UserID: int64(st.Self.UserID)}
	if name, _, ok := strings.Cut(st.Self.DNSName, "."); ok && name != "" {
		self.HostName = name
	}
	if profile, ok := st.User[st.Self.UserID]; ok {
		self.Login = profile.LoginName
	}
	for _, ip := range st.TailscaleIPs {
		if IsTailnetIP(ip) {
			self.IPs = append(self.IPs, ip)
		}
	}
	if len(self.IPs) == 0 {
		return Self{}, fmt.Errorf("%w (tailnet 주소가 없습니다)", ErrNotRunning)
	}
	return self, nil
}

func (l *Local) WhoIs(ctx context.Context, remote netip.AddrPort) (Peer, error) {
	who, err := l.lc.WhoIs(ctx, remote.String())
	if err != nil {
		return Peer{}, err
	}
	if who.Node == nil || who.UserProfile == nil {
		return Peer{}, errors.New("whois 응답에 기기나 계정 정보가 없습니다")
	}
	return Peer{
		UserID: int64(who.UserProfile.ID),
		Login:  who.UserProfile.LoginName,
		Node:   who.Node.ComputedName,
		Tagged: who.Node.IsTagged(),
	}, nil
}

// PickBindIP는 링크에 넣을 주소를 고릅니다. IPv4를 먼저 씁니다.
func PickBindIP(ips []netip.Addr) (netip.Addr, bool) {
	for _, ip := range ips {
		if ip.Is4() && IsTailnetIP(ip) {
			return ip, true
		}
	}
	for _, ip := range ips {
		if IsTailnetIP(ip) {
			return ip, true
		}
	}
	return netip.Addr{}, false
}
