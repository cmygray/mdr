import Foundation

/// 파일 하나의 변경을 감시합니다.
///
/// 편집기는 대개 임시 파일에 쓴 뒤 이름을 바꿔 저장하므로, 지워지거나 이름이 바뀌면
/// 같은 경로를 다시 열어 감시를 이어갑니다.
public final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retry: DispatchWorkItem?

    /// `onChange`는 메인 스레드에서 부릅니다.
    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        open()
    }

    deinit {
        source?.cancel()
        pending?.cancel()
        retry?.cancel()
    }

    private func open(notifyWhenOpened: Bool = false) {
        source?.cancel()
        source = nil
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // 저장 도중 잠깐 파일이 없을 수 있습니다. 조금 뒤에 다시 열고, 열리면 변경으로 알립니다.
            let work = DispatchWorkItem { [weak self] in self?.open(notifyWhenOpened: true) }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        if notifyWhenOpened { scheduleChange() }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                self.open()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
