#!/usr/bin/env python3
"""저장소에 개인 정보가 들어가지 않았는지 확인합니다. 커밋하기 전에 돌립니다.

  scripts/check-private.py              작업 폴더: 추적 중인 파일과, 아직 추적하지 않지만 ignore되지 않은 파일
  scripts/check-private.py --history    모든 ref의 모든 커밋: 메시지, 작성자, 파일 이름, 모든 파일 내용(바이너리 포함)
  scripts/check-private.py --redact DIR [DIR ...]
                                        DIR 아래 글자 파일에서 같은 값을 예시 값으로 바꿉니다(검증 스크립트가 결과를 저장한 뒤 씁니다)

찾는 값은 이 파일에 적지 않고, 실행할 때 이 기기에서 읽습니다.

  - Tailscale(`tailscale status --json`): tailnet 이름, 이 기기와 다른 기기의 tailnet 주소(IPv4·IPv6)와 이름, 계정
  - 이 기기: 홈 경로, 사용자별 임시 폴더(/var/folders/…), 컴퓨터 이름, LAN 주소
  - git 설정의 이메일(noreply 주소가 아닐 때), 코드 서명 인증서의 팀 식별자
  - 값과 상관없이: 예시가 아닌 이메일 주소, 다른 사람의 홈 경로(/Users/<이름>)

같은 값의 다른 표기도 찾습니다. JSON의 `\\/Users\\/...`, 퍼센트 인코딩, tailnet 주소의 뒤 세 옥텟
(`0x64.b.c.d`, `::ffff:a.b.c.d`), 앞에 0을 붙인 꼴, 10진수·16진수 꼴입니다.

흔한 낱말(소문자만으로 된 짧은 이름)인 기기 이름은 따옴표나 backtick으로 감싼 자리와 `이름.…ts.net` 꼴만 봅니다.
그 밖의 자리에서는 흔한 낱말과 구별할 수 없습니다.

Tailscale에서 값을 읽지 못하면 tailnet 값은 확인하지 못한 것이므로 실패(3)로 끝납니다.
그래도 나머지만 보려면 MDR_CHECK_ALLOW_NO_TAILSCALE=1을 줍니다.

끝나는 값: 0 찾지 못함, 1 찾음, 3 찾을 값을 읽지 못함.
"""
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse

ALLOWED_EMAIL = re.compile(
    r"@example\.(com|org|net)$|@users\.noreply\.github\.com$|^noreply@anthropic\.com$|^git@", re.I)
ALLOWED_HOME_NAMES = {"me", "you", "user", "username", "name", "shared", "example", "someone"}
GENERIC_WORD = re.compile(r"[a-z]{1,8}")  # 소문자만으로 된 짧은 이름(흔한 낱말일 수 있음)
SKIP_NAMES = {"localhost", ""}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
OTHER_HOME = re.compile(r"/(?:Users|home)/([A-Za-z0-9._-]+)(?=/)")


def run(*command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def git(*arguments, binary=False):
    result = subprocess.run(["git", *arguments], capture_output=True)
    if result.returncode != 0:
        sys.exit(f"git {' '.join(arguments)} 실패: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout if binary else result.stdout.decode(errors="replace")


class Needles:
    """찾을 값. patterns는 (종류, 정규식, 바꿀 글자) 목록입니다."""

    def __init__(self):
        self.patterns = []
        self.missing = []
        self.user = ""
        self._seen = set()

    def add(self, kind, regex, replacement, flags=0):
        key = (regex, flags)
        if key in self._seen:
            return
        self._seen.add(key)
        self.patterns.append((kind, re.compile(regex, flags), replacement))

    def literal(self, kind, value, replacement, boundary=r"[A-Za-z0-9]", flags=0):
        if not value or len(value) < 4:
            return
        self.add(kind, rf"(?<!{boundary}){re.escape(value)}(?!{boundary})", replacement, flags)

    def substring(self, kind, value, replacement, flags=0):
        if value and len(value) >= 5:
            self.add(kind, re.escape(value), replacement, flags)

    def ipv4(self, kind, value, replacement):
        try:
            address = ipaddress.IPv4Address(value)
        except ValueError:
            return
        a, b, c, d = value.split(".")
        ra, rb, rc, rd = replacement.split(".")
        # 온전한 꼴(앞에 0을 붙인 꼴 포함)
        self.add(kind, rf"(?<![0-9.])(0*){a}\.(0*){b}\.(0*){c}\.(0*){d}(?![0-9])", rf"\g<1>{ra}.\g<2>{rb}.\g<3>{rc}.\g<4>{rd}")
        # 뒤 세 옥텟: 0x64.b.c.d처럼 첫 옥텟만 다르게 쓴 꼴
        self.add(kind + "(뒤 세 옥텟)", rf"(?<![0-9])(0*){b}\.(0*){c}\.(0*){d}(?![0-9])", rf"\g<1>{rb}.\g<2>{rc}.\g<3>{rd}")
        number, to = int(address), int(ipaddress.IPv4Address(replacement))
        self.add(kind + "(10진수)", rf"(?<![0-9]){number}(?![0-9])", str(to))
        self.add(kind + "(16진수)", rf"(?<![0-9A-Fa-f]){number:08x}(?![0-9A-Fa-f])", f"{to:08x}", re.I)

    def ipv6(self, kind, value, replacement):
        try:
            address = ipaddress.IPv6Address(value)
        except ValueError:
            return
        forms = {address.compressed, address.exploded}
        for form in forms:
            self.add(kind, rf"(?<![0-9A-Fa-f:]){re.escape(form)}(?![0-9A-Fa-f:])", replacement, re.I)
        # 주소마다 다른 뒤 두 묶음
        tail = ":".join(address.exploded.split(":")[-2:])
        short = ":".join(group.lstrip("0") or "0" for group in tail.split(":"))
        for form in {tail, short}:
            self.add(kind + "(뒤 두 묶음)", rf"(?<![0-9A-Fa-f]){re.escape(form)}(?![0-9A-Fa-f:])",
                     ":".join(replacement.split(":")[-2:]), re.I)

    def device(self, value, replacement):
        """기기 이름. 흔한 낱말이면 감싼 자리만, 아니면 어디서든 찾습니다."""
        if value.lower() in SKIP_NAMES or len(value) < 3:
            return
        if GENERIC_WORD.fullmatch(value):
            name = re.escape(value)
            self.add("기기 이름(감싼 자리)", rf"""(?<=["'`]){name}(?=["'`])""", replacement)
            self.add("기기 이름(도메인)", rf"(?<![A-Za-z0-9-]){name}(?=\.[A-Za-z0-9.-]*ts\.net)", replacement)
        else:
            self.literal("기기 이름", value, replacement, boundary=r"[A-Za-z0-9-]")


def tailscale_status():
    candidates = [shutil.which("tailscale"), "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            text = run(candidate, "status", "--json")
            if text:
                try:
                    return json.loads(text)
                except ValueError:
                    pass
    return None


def gather():
    needles = Needles()

    status = tailscale_status()
    if status is None:
        needles.missing.append("Tailscale(tailscale status --json을 읽지 못함)")
    else:
        suffix = (status.get("MagicDNSSuffix") or "").strip(".")
        if suffix:
            needles.substring("tailnet 이름", suffix, "example.ts.net", re.I)
            needles.substring("tailnet 이름", suffix.split(".")[0], "example", re.I)
        tailnet = (status.get("CurrentTailnet") or {}).get("Name") or ""
        needles.substring("tailnet 계정", tailnet, "user@example.com", re.I)
        nodes = [status.get("Self") or {}] + list((status.get("Peer") or {}).values())
        for index, node in enumerate(nodes):
            host = "host-" + (chr(ord("a") + index) if index < 26 else str(index))
            for address in node.get("TailscaleIPs") or []:
                if ":" in address:
                    needles.ipv6("tailnet 주소(IPv6)", address, f"fd7a:115c:a1e0::1234:{0x5678 + index:x}")
                else:
                    needles.ipv4("tailnet 주소", address, f"100.101.102.{103 + index}")
            dns = (node.get("DNSName") or "").strip(".")
            names = {node.get("HostName") or "", dns.split(".")[0] if dns else ""}
            for name in sorted(names):
                needles.device(name, host)
            for key in ("ID", "PublicKey"):
                needles.substring("tailnet 기기 식별자", str(node.get(key) or ""), "<기기 식별자>")
            user_id = str(node.get("UserID") or "")
            if len(user_id) >= 8:
                needles.literal("tailnet 계정 번호", user_id, "<계정 번호>", boundary=r"[0-9]")
        for user in (status.get("User") or {}).values():
            needles.substring("tailnet 계정", user.get("LoginName") or "", "user@example.com", re.I)

    # 이 기기
    home = os.path.expanduser("~").rstrip("/")
    if home and home != "/":
        needles.add("홈 경로", rf"{re.escape(home)}(?![A-Za-z0-9._-])", "~")
    user = os.environ.get("USER") or os.path.basename(home)
    if user:
        needles.add("홈 경로", rf"/(?:Users|home)/{re.escape(user)}(?![A-Za-z0-9._-])", "~")
        needles.user = user
    # macOS의 사용자별 임시 폴더: /var/folders/xx/<사용자마다 다른 글자>/
    for candidate in (run("getconf", "DARWIN_USER_TEMP_DIR"), os.environ.get("TMPDIR", "")):
        match = re.match(r"(?:/private)?(/var/folders/[^/]+/[^/]+)", candidate.strip())
        if match:
            needles.add("사용자별 임시 폴더", rf"(?:/private)?{re.escape(match.group(1))}(?![A-Za-z0-9._-])", "<tmp>")
    for command in (["scutil", "--get", "ComputerName"], ["scutil", "--get", "LocalHostName"], ["hostname", "-s"]):
        name = run(*command).strip()
        if name and not GENERIC_WORD.fullmatch(name):
            needles.literal("컴퓨터 이름", name, "host-a", boundary=r"[A-Za-z0-9-]")
    for line in run("ifconfig").splitlines():
        match = re.match(r"\s*inet (\d+\.\d+\.\d+\.\d+)", line)
        if not match:
            continue
        address = ipaddress.IPv4Address(match.group(1))
        if address.is_loopback or address.is_link_local or address in ipaddress.ip_network("100.64.0.0/10"):
            continue
        value = str(address)
        needles.add("LAN 주소", rf"(?<![0-9.]){re.escape(value)}(?![0-9])", "192.168.1.23")

    email = run("git", "config", "user.email").strip()
    if email and not ALLOWED_EMAIL.search(email):
        needles.substring("git 이메일", email, "user@example.com", re.I)
    for match in re.finditer(r"\(([A-Z0-9]{10})\)", run("security", "find-identity", "-v", "-p", "codesigning")):
        needles.literal("서명 팀 식별자", match.group(1), "TEAMID0000")
    return needles


def is_text(data):
    return b"\0" not in data[:8192]


def views(text):
    """같은 글자의 다른 표기를 펼칩니다: 원문, JSON의 \\/를 /로, 퍼센트 디코딩."""
    result = [text]
    unescaped = text.replace("\\/", "/")
    if unescaped != text:
        result.append(unescaped)
    decoded = urllib.parse.unquote(unescaped)
    if decoded != unescaped:
        result.append(decoded)
    return result


def scan(data, needles, generic=True):
    """(종류, 찾은 글자, 줄 번호) 목록. 줄 번호는 원문 기준이고 알 수 없으면 0입니다."""
    text = data.decode("utf-8", errors="replace")
    textual = is_text(data)
    found = {}
    for view_index, view in enumerate(views(text) if textual else [text]):
        def note(kind, match):
            line = view.count("\n", 0, match.start()) + 1
            found.setdefault((kind, match.group(0)), line)
        for kind, pattern, _ in needles.patterns:
            for match in pattern.finditer(view):
                note(kind, match)
        if textual and generic:
            for match in EMAIL.finditer(view):
                if not ALLOWED_EMAIL.search(match.group(0)):
                    note("이메일 주소", match)
            for match in OTHER_HOME.finditer(view):
                if match.group(1).lower() not in ALLOWED_HOME_NAMES and match.group(1) != needles.user:
                    note("홈 경로(다른 계정)", match)
    return [(kind, value, line) for (kind, value), line in found.items()]


def report(findings):
    for where, kind, value in findings:
        print(f"  {where}: {kind}: {value}")


def check_worktree(needles):
    findings = []
    names = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    for name in filter(None, names):
        for kind, value, _ in scan(name.encode(), needles, generic=False):
            findings.append((name, "파일 이름의 " + kind, value))
        try:
            with open(name, "rb") as handle:
                data = handle.read()
        except (IsADirectoryError, FileNotFoundError):
            continue
        for kind, value, line in scan(data, needles):
            findings.append((f"{name}:{line}", kind, value))
    return findings, len(names)


def check_history(needles):
    findings = []
    log = git("log", "--all", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x01")
    commits = [entry.strip("\n").split("\0") for entry in log.split("\x01") if entry.strip()]
    for sha, author, committer, message in commits:
        for label, text in (("작성자", author), ("커미터", committer), ("메시지", message)):
            for kind, value, _ in scan(text.encode(), needles):
                findings.append((f"커밋 {sha[:7]} {label}", kind, value))

    paths = {}
    for line in git("rev-list", "--all", "--objects").splitlines():
        sha, _, path = line.partition(" ")
        if path:
            paths.setdefault(sha, path)
    batch = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    blobs = 0
    for sha, path in paths.items():
        batch.stdin.write(sha.encode() + b"\n")
        batch.stdin.flush()
        header = batch.stdout.readline().split()
        size = int(header[2])
        data = batch.stdout.read(size)
        batch.stdout.read(1)
        for kind, value, _ in scan(path.encode(), needles, generic=False):
            findings.append((f"{path} ({header[1].decode()} {sha[:7]})", "파일 이름의 " + kind, value))
        if header[1] != b"blob":
            continue
        blobs += 1
        for kind, value, line in scan(data, needles):
            commit = git("log", "--all", "--format=%h", "-1", f"--find-object={sha}").strip()
            findings.append((f"{path}:{line} (blob {sha[:7]}, 커밋 {commit})", kind, value))
    batch.stdin.close()
    batch.wait()
    return findings, len(commits), blobs


def redact(directories, needles):
    changed = 0
    root = git("rev-parse", "--show-toplevel").strip()
    # 저장소 경로를 먼저 바꿉니다. JSON에서는 /가 \/로 적혀 있습니다.
    slash = r"\\?/"
    repo = re.compile(slash.join(re.escape(part) for part in root.split("/")) + r"(?![A-Za-z0-9._-])")
    home = os.path.expanduser("~").rstrip("/")
    home_escaped = re.compile(slash.join(re.escape(part) for part in home.split("/")) + r"(?![A-Za-z0-9._-])")
    for directory in directories:
        for folder, _, files in os.walk(directory):
            for name in files:
                path = os.path.join(folder, name)
                with open(path, "rb") as handle:
                    data = handle.read()
                if not is_text(data):
                    continue
                text = data.decode("utf-8", errors="surrogateescape")
                new = repo.sub("<repo>", text)
                new = home_escaped.sub("~", new)
                for _, pattern, replacement in needles.patterns:
                    new = pattern.sub(replacement, new)
                new = EMAIL.sub(lambda m: m.group(0) if ALLOWED_EMAIL.search(m.group(0)) else "user@example.com", new)
                if new != text:
                    with open(path, "wb") as handle:
                        handle.write(new.encode("utf-8", errors="surrogateescape"))
                    changed += 1
    return changed


def main():
    arguments = sys.argv[1:]
    if arguments and arguments[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    os.chdir(git("rev-parse", "--show-toplevel").strip() if not arguments or arguments[0] != "--redact"
             else os.getcwd())
    needles = gather()
    allow_missing = os.environ.get("MDR_CHECK_ALLOW_NO_TAILSCALE") == "1"

    if arguments and arguments[0] == "--redact":
        if len(arguments) < 2:
            sys.exit("사용법: scripts/check-private.py --redact DIR [DIR ...]")
        changed = redact(arguments[1:], needles)
        shown = ", ".join(os.path.relpath(directory) for directory in arguments[1:])
        print(f"개인 정보 가리기: {changed}개 파일을 고쳤습니다 ({shown})")
        for item in needles.missing:
            print(f"  주의: {item}. 그 값은 가리지 못했습니다.")
        return 3 if needles.missing and not allow_missing else 0

    if arguments and arguments[0] == "--history":
        findings, commits, blobs = check_history(needles)
        scope = f"모든 ref의 커밋 {commits}개(메시지·작성자·파일 이름)와 파일 내용 {blobs}개"
    elif not arguments:
        findings, count = check_worktree(needles)
        scope = f"작업 폴더의 파일 {count}개"
    else:
        sys.exit(__doc__)

    print(f"개인 정보 점검: {scope}, 찾는 값 {len(needles.patterns)}가지와 이메일 주소·홈 경로")
    report(findings)
    for item in needles.missing:
        print(f"  확인하지 못함: {item}")
    if findings:
        print(f"결과: {len(findings)}건 찾음")
        return 1
    if needles.missing and not allow_missing:
        print("결과: 찾을 값을 다 읽지 못했습니다")
        return 3
    print("결과: 찾지 못함")
    return 0


if __name__ == "__main__":
    sys.exit(main())
