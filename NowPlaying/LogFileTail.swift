import Foundation

/// Follows a log file another app appends to: hands over what the file holds
/// on `start()`, then each complete line appended later, across rotation and
/// truncation.
///
/// Not thread-safe on its own: call `start()` and `stop()` on `queue`, where
/// the callbacks also run.
final class LogFileTail {
    private let url: URL
    private let reopenInterval: TimeInterval
    private let queue: DispatchQueue
    private let onHistory: (Data) -> Void
    private let onLines: ([String]) -> Void
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var reopenWorkItem: DispatchWorkItem?
    private var isRunning = false

    /// A line longer than this without a newline is not a log line we want.
    private static let maxBufferedBytes = 1 << 20

    init(url: URL, reopenInterval: TimeInterval, queue: DispatchQueue,
         onHistory: @escaping (Data) -> Void, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.reopenInterval = reopenInterval
        self.queue = queue
        self.onHistory = onHistory
        self.onLines = onLines
    }

    func start() {
        isRunning = true
        reopenWorkItem?.cancel()
        teardown()
        open(catchingUp: true)
    }

    func stop() {
        isRunning = false
        reopenWorkItem?.cancel()
        reopenWorkItem = nil
        teardown()
    }

    static func lines(in data: Data) -> [String] {
        data.split(separator: 0x0A).compactMap { String(data: $0, encoding: .utf8) }
    }

    /// `catchingUp` is the first open of a file that already has history: it
    /// goes to `onHistory` instead of `onLines`.
    private func open(catchingUp: Bool) {
        guard isRunning else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            scheduleReopen()
            return
        }

        if catchingUp {
            let history = (try? handle.readToEnd()) ?? Data()
            offset = UInt64(history.count)
            onHistory(history)
        } else {
            offset = 0
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            self.readAvailable()
            if events.contains(.delete) || events.contains(.rename) {
                self.teardown()
                self.open(catchingUp: false)
            }
        }
        source.setCancelHandler {
            try? handle.close()
        }

        self.handle = handle
        self.source = source
        source.resume()

        // Lines written between the rotation and this open would otherwise
        // wait for the next write.
        if !catchingUp {
            readAvailable()
        }
    }

    private func scheduleReopen() {
        let item = DispatchWorkItem { [weak self] in
            self?.open(catchingUp: false)
        }
        reopenWorkItem?.cancel()
        reopenWorkItem = item
        queue.asyncAfter(deadline: .now() + reopenInterval, execute: item)
    }

    private func teardown() {
        source?.cancel()
        source = nil
        handle = nil
        offset = 0
        buffer.removeAll(keepingCapacity: false)
    }

    private func readAvailable() {
        guard let handle, let end = try? handle.seekToEnd() else { return }
        if end < offset {
            // Truncated in place: start over from the top.
            offset = 0
            buffer.removeAll(keepingCapacity: true)
        }
        guard end > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(end - offset)), !data.isEmpty else {
            return
        }
        offset += UInt64(data.count)
        buffer.append(data)

        let lines = drainLines()
        if !lines.isEmpty {
            onLines(lines)
        }

        if buffer.count > Self.maxBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func drainLines() -> [String] {
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        let complete = buffer[buffer.startIndex...lastNewline]
        buffer.removeSubrange(buffer.startIndex...lastNewline)
        return Self.lines(in: Data(complete))
    }
}
