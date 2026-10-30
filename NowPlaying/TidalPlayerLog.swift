import AppKit
import Combine
import Foundation

/// The format Tidal's native player opens its Core Audio sink at: the decoded
/// track's own rate and bit depth.
struct TidalStreamFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int?
}

enum TidalPlaybackStatus: String, Equatable {
    case active, paused, stopped, completed
}

/// What Tidal's native player (`TIDALPlayer`) reports in
/// `~/Library/Logs/TIDAL/player.log`:
///
///     [pcm_sink_coreaudio.cpp:36] CoreaudioSink::open, rate: 96000, type: int24
///     [pcm_sink_coreaudio.cpp:207] CoreaudioSink::start
///     [media_player_tidal.cpp:97] Play()
///     [client.hpp:37] SIGNAL: {"signal": "media.state", "state": "active", "url": "…"}
///     [pcm_sink_coreaudio.cpp:322] selectDevice - id: AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1, mode: Shared
enum TidalPlayerEvent: Equatable {
    case sinkOpened(TidalStreamFormat)
    case sinkStarted
    case sinkStopped
    case sinkClosed
    case playRequested
    case statusChanged(TidalPlaybackStatus)
    /// `uid` is the Core Audio device UID; nil means the system default output.
    case deviceSelected(uid: String?, exclusive: Bool)
}

enum TidalPlayerLogParser {
    private static let sinkOpenPattern = try! NSRegularExpression(
        pattern: "CoreaudioSink::open, rate: ([0-9]+), type: ([a-z]+)([0-9]*)",
        options: []
    )

    private static let devicePattern = try! NSRegularExpression(
        pattern: "selectDevice - id: (.+), mode: (Shared|Exclusive)\\s*$",
        options: []
    )

    private static let statusPattern = try! NSRegularExpression(
        pattern: "\"signal\": \"media\\.state\", \"state\": \"([a-z]+)\"",
        options: []
    )

    private static let systemDeviceMarker = "attempting to select system controlled device"

    /// Only the shapes above are recognised, and only the fields they name are
    /// kept. Every other line, including the `COMMAND` lines that carry stream
    /// tokens and keys, gives nil.
    static func parse(_ line: String) -> TidalPlayerEvent? {
        if line.contains("CoreaudioSink::") {
            return sinkEvent(line)
        }

        if line.contains("\"media.state\"") {
            guard let groups = captures(statusPattern, in: line),
                  let status = TidalPlaybackStatus(rawValue: groups[0]) else { return nil }
            return .statusChanged(status)
        }

        if line.hasSuffix("] Play()") {
            return .playRequested
        }

        if line.contains("selectDevice - id:") {
            guard let groups = captures(devicePattern, in: line) else { return nil }
            let uid = groups[0] == "SystemControlled" ? nil : groups[0]
            return .deviceSelected(uid: uid, exclusive: groups[1] == "Exclusive")
        }

        if line.contains(systemDeviceMarker) {
            return .deviceSelected(uid: nil, exclusive: false)
        }

        return nil
    }

    private static func sinkEvent(_ line: String) -> TidalPlayerEvent? {
        if line.contains("CoreaudioSink::open") {
            guard let groups = captures(sinkOpenPattern, in: line),
                  let rate = Double(groups[0]),
                  (8_000...768_000).contains(rate) else { return nil }
            let bitDepth = groups[1] == "int" ? Int(groups[2]) : nil
            return .sinkOpened(TidalStreamFormat(sampleRate: rate, bitDepth: bitDepth))
        }
        if line.hasSuffix("CoreaudioSink::start") { return .sinkStarted }
        if line.hasSuffix("CoreaudioSink::stop") { return .sinkStopped }
        if line.hasSuffix("CoreaudioSink::close") { return .sinkClosed }
        return nil
    }

    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String]? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

/// Tidal's playback as reconstructed from its log.
///
/// Tidal opens the sink once the first bytes are downloaded and the FLAC header
/// is parsed, and only then sends play, so a slow download delays the `open`
/// itself and no audio can precede it. An `open` is not playback, though: Tidal
/// also opens the sink for the paused track it restores at launch. So `open`
/// only records the format, and the switch waits for the first sign of play
/// (`Play()`, `state: active` or `CoreaudioSink::start`, whichever comes
/// first). An `open` while already playing is a gapless boundary to a new rate
/// and starts its format at once; a same-rate gapless boundary has no `open`.
struct TidalPlaybackState: Equatable {
    var format: TidalStreamFormat?
    var isPlaying = false
    var deviceUID: String?
    var exclusive = false

    /// Returns the format that starts playing because of `event`, if any.
    mutating func apply(_ event: TidalPlayerEvent) -> TidalStreamFormat? {
        switch event {
        case let .sinkOpened(newFormat):
            format = newFormat
            return isPlaying ? newFormat : nil
        case .playRequested, .sinkStarted, .statusChanged(.active):
            let wasPlaying = isPlaying
            isPlaying = true
            return wasPlaying ? nil : format
        case .statusChanged(.paused), .statusChanged(.stopped), .sinkStopped:
            isPlaying = false
        case .statusChanged(.completed), .sinkClosed:
            // A track boundary or the close before the next open, not a stop.
            break
        case let .deviceSelected(uid, isExclusive):
            deviceUID = uid
            exclusive = isExclusive
        }
        return nil
    }
}

/// Follows Tidal's `player.log` and publishes what Tidal is doing.
///
/// Subscribe to `formatStarted` to act when a format starts playing, to `state`
/// for the current snapshot (replayed to new subscribers), or to `events` for
/// every recognised line. All three publish on a private queue.
///
/// The player rotates the file by renaming it to `player.1.log` and starting a
/// fresh `player.log`, so a rename or delete reopens the path from the top.
/// Raw lines are never stored or published: the same file holds stream URLs
/// with access tokens and decryption keys.
final class TidalPlayerLogController {
    static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TIDAL/player.log")

    static func isTidalRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tidal.desktop").isEmpty
    }

    var events: AnyPublisher<TidalPlayerEvent, Never> { eventSubject.eraseToAnyPublisher() }
    var state: AnyPublisher<TidalPlaybackState, Never> { stateSubject.eraseToAnyPublisher() }
    var formatStarted: AnyPublisher<TidalPlaybackState, Never> { formatSubject.eraseToAnyPublisher() }

    private let eventSubject = PassthroughSubject<TidalPlayerEvent, Never>()
    private let stateSubject = CurrentValueSubject<TidalPlaybackState, Never>(TidalPlaybackState())
    private let formatSubject = PassthroughSubject<TidalPlaybackState, Never>()

    private let url: URL
    private let reopenInterval: TimeInterval
    private let isPlayerRunning: () -> Bool
    private let queue = DispatchQueue(label: "tidal.playerlog.controller")
    private var playback = TidalPlaybackState()
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var reopenWorkItem: DispatchWorkItem?
    private var isRunning = false

    /// A line longer than this without a newline is not a log line we want.
    private static let maxBufferedBytes = 1 << 20

    init(url: URL = TidalPlayerLogController.defaultLogURL,
         reopenInterval: TimeInterval = 5,
         isPlayerRunning: @escaping () -> Bool = TidalPlayerLogController.isTidalRunning) {
        self.url = url
        self.reopenInterval = reopenInterval
        self.isPlayerRunning = isPlayerRunning
    }

    // MARK: - Lifecycle
    //
    // All file and playback state lives behind `queue`. `start()` and `stop()`
    // are safe to call from any thread.

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.reopenWorkItem?.cancel()
            self.teardown()
            self.open(catchingUp: true)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.reopenWorkItem?.cancel()
            self.reopenWorkItem = nil
            self.teardown()
        }
    }

    /// Must be called on `queue`. `catchingUp` is the first open of a file that
    /// already has history: it is replayed silently to rebuild the playback
    /// state, and a track that is still playing starts its format right away.
    private func open(catchingUp: Bool) {
        guard isRunning else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            scheduleReopen()
            return
        }

        if catchingUp {
            let history = (try? handle.readToEnd()) ?? Data()
            offset = UInt64(history.count)
            catchUp(on: history)
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

    /// Must be called on `queue`.
    private func catchUp(on history: Data) {
        var rebuilt = TidalPlaybackState()
        for event in lines(in: history).compactMap(TidalPlayerLogParser.parse) {
            _ = rebuilt.apply(event)
        }
        // A player that quit mid-track never logged its stop.
        if !isPlayerRunning() {
            rebuilt.isPlaying = false
        }
        playback = rebuilt
        stateSubject.send(rebuilt)
        if rebuilt.isPlaying, rebuilt.format != nil {
            formatSubject.send(rebuilt)
        }
    }

    /// Must be called on `queue`.
    private func scheduleReopen() {
        let item = DispatchWorkItem { [weak self] in
            self?.open(catchingUp: false)
        }
        reopenWorkItem?.cancel()
        reopenWorkItem = item
        queue.asyncAfter(deadline: .now() + reopenInterval, execute: item)
    }

    /// Must be called on `queue`.
    private func teardown() {
        source?.cancel()
        source = nil
        handle = nil
        offset = 0
        buffer.removeAll(keepingCapacity: false)
    }

    /// Must be called on `queue`.
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

        for event in drainLines().compactMap(TidalPlayerLogParser.parse) {
            publish(event)
        }

        if buffer.count > Self.maxBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
        }
    }

    /// Must be called on `queue`.
    private func publish(_ event: TidalPlayerEvent) {
        let started = playback.apply(event)
        eventSubject.send(event)
        if stateSubject.value != playback {
            stateSubject.send(playback)
        }
        if started != nil {
            formatSubject.send(playback)
        }
    }

    private func drainLines() -> [String] {
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        let complete = buffer[buffer.startIndex...lastNewline]
        buffer.removeSubrange(buffer.startIndex...lastNewline)
        return lines(in: Data(complete))
    }

    private func lines(in data: Data) -> [String] {
        data.split(separator: 0x0A).compactMap { String(data: $0, encoding: .utf8) }
    }
}
