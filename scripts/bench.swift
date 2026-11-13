// 앱이 문서를 여는 속도를 앱 바깥에서 잽니다. 어떤 앱이든 같은 방법으로 잴 수 있습니다.
//
//   swiftc -O scripts/bench.swift -o tmp/bench
//   tmp/bench <앱 경로> <cold|warm> <반복 횟수> <문서> [문서...]
//
// 재는 값(모두 `open -a <앱> <문서>`를 실행한 순간부터의 시간, ms)
//   window : 그 앱의 새 창이 창 서버에 올라온 시각
//   settled: 창이 뜬 뒤 프로세스의 CPU 사용이 잠잠해진 시각(150ms 동안 CPU 시간 증가가 3ms 미만)
//   cpu    : settled까지 프로세스가 쓴 CPU 시간
//
// cold는 앱을 끝낸 상태에서, warm은 앱이 떠 있는 상태에서 다른 문서를 엽니다.
// 화면 내용은 보지 않으므로(화면 기록 권한 불필요) "창은 떴지만 내용은 아직"인 구간은 settled로 어림합니다.

import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let arguments = CommandLine.arguments
guard arguments.count >= 5, let iterations = Int(arguments[3]), ["cold", "warm"].contains(arguments[2]) else {
    print("usage: bench <app path> <cold|warm> <iterations> <document> [document...]")
    exit(2)
}
let appURL = URL(fileURLWithPath: arguments[1])
let mode = arguments[2]
let documents = arguments[4...].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
    print("앱을 읽을 수 없습니다: \(appURL.path)")
    exit(2)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

func sleepMs(_ ms: Double) {
    usleep(useconds_t(ms * 1000))
}

func runningApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

/// 프로세스가 지금까지 쓴 CPU 시간(ms)
func cpuTimeMs(_ pid: pid_t) -> Double? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    let ticks = Double(info.pti_total_user + info.pti_total_system)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

/// 그 프로세스의 일반 창(layer 0, 어느 정도 크기) 번호들
func windowIDs(of pid: pid_t) -> Set<Int> {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var ids: Set<Int> = []
    for window in list {
        guard (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
              width >= 300, height >= 200,
              let id = window[kCGWindowNumber as String] as? Int else { continue }
        ids.insert(id)
    }
    return ids
}

func terminateApp() {
    for app in runningApps() {
        app.terminate()
    }
    let deadline = now() + 5000
    while !runningApps().isEmpty, now() < deadline { sleepMs(50) }
    for app in runningApps() {
        app.forceTerminate()
    }
    while !runningApps().isEmpty { sleepMs(50) }
    sleepMs(700)
}

struct Sample {
    var window: Double
    var settled: Double
    var cpu: Double
}

func openDocument(_ path: String) -> Sample? {
    let existingPID = runningApps().first?.processIdentifier
    let before = existingPID.map(windowIDs(of:)) ?? []
    let cpuBefore = existingPID.flatMap(cpuTimeMs) ?? 0

    let start = now()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appURL.path, path]
    do { try process.run() } catch { return nil }

    // 1) 새 창이 뜰 때까지
    var pid = existingPID
    var windowTime: Double?
    while now() - start < 30_000 {
        if pid == nil { pid = runningApps().first?.processIdentifier }
        if let pid, !windowIDs(of: pid).subtracting(before).isEmpty {
            windowTime = now() - start
            break
        }
        usleep(2000)
    }
    guard let pid, let windowTime else { return nil }

    // 2) CPU 사용이 잠잠해질 때까지
    var history: [(time: Double, cpu: Double)] = []
    var settled = windowTime
    while now() - start < 60_000 {
        guard let cpu = cpuTimeMs(pid) else { break }
        let time = now() - start
        history.append((time, cpu))
        if let reference = history.last(where: { time - $0.time >= 150 }) {
            if cpu - reference.cpu < 3 {
                // 잠잠해지기 시작한 시각 = 창이 뜬 뒤 CPU 사용이 멈춘 첫 표본
                settled = history.first(where: { $0.time >= windowTime && cpu - $0.cpu < 3 })?.time ?? time
                break
            }
        }
        usleep(5000)
    }
    let cpuUsed = (history.last?.cpu ?? cpuBefore) - cpuBefore
    return Sample(window: windowTime, settled: max(settled, windowTime), cpu: cpuUsed)
}

func summarize(_ label: String, _ values: [Double]) -> String {
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    return "\(label) 중앙값 \(Int(median.rounded())) (최소 \(Int(sorted.first!.rounded())), 최대 \(Int(sorted.last!.rounded())))"
}

print("앱: \(appURL.lastPathComponent) (\(bundleID)), 방식: \(mode), 반복: \(iterations)")
var samples: [Sample] = []

if mode == "cold" {
    for iteration in 0..<iterations {
        terminateApp()
        let document = documents[iteration % documents.count]
        guard let sample = openDocument(document) else {
            print("  \(iteration + 1): 실패")
            continue
        }
        samples.append(sample)
        print(String(format: "  %d: window %.0f ms, settled %.0f ms, cpu %.0f ms", iteration + 1, sample.window, sample.settled, sample.cpu))
        sleepMs(800)
    }
} else {
    guard documents.count >= iterations + 1 else {
        print("warm 방식은 서로 다른 문서가 반복 횟수 + 1개 필요합니다(첫 문서는 앱을 띄우는 데 씁니다)")
        exit(2)
    }
    terminateApp()
    _ = openDocument(documents[0])
    sleepMs(1500)
    for iteration in 0..<iterations {
        guard let sample = openDocument(documents[iteration + 1]) else {
            print("  \(iteration + 1): 실패")
            continue
        }
        samples.append(sample)
        print(String(format: "  %d: window %.0f ms, settled %.0f ms, cpu %.0f ms", iteration + 1, sample.window, sample.settled, sample.cpu))
        sleepMs(1200)
    }
}
terminateApp()

guard !samples.isEmpty else {
    print("측정값이 없습니다")
    exit(1)
}
print("  " + summarize("window", samples.map(\.window)))
print("  " + summarize("settled", samples.map(\.settled)))
print("  " + summarize("cpu", samples.map(\.cpu)))
