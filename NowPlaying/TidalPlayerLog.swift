import AppKit
import Combine
import Foundation

/// The format Tidal's native player plays at: the decoded track's own rate and
/// bit depth.
struct TidalStreamFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int?
}

enum TidalPlaybackStatus: String, Equatable {
    case active, paused, stopped, completed
}

/// What Tidal's native player (`TIDALPlayer`) does, from two logs.
///
/// Its own `~/Library/Logs/TIDAL/player.log`:
///
///     [pcm_sink_coreaudio.cpp:36] CoreaudioSink::open, rate: 96000, type: int24
///     [pcm_sink_coreaudio.cpp:207] CoreaudioSink::start
///     [media_player_tidal.cpp:97] Play()
///     [client.hpp:37] SIGNAL: {"signal": "media.state", "state": "active", "url": "…"}
///     [pcm_sink_coreaudio.cpp:322] selectDevice - id: AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1, mode: Shared
///
/// and the messages Core Audio logs from inside that process to the unified
/// log, which arrive in real time:
///
///     AudioConverter.cpp:1077  Created a new in process converter -> 0x…, from  2 ch,  96000 Hz, lpcm (0xC) 24-bit little-endian signed integer to  2 ch,  44100 Hz, Float32, interleaved
///     SessionCore_macOS_Legacy.mm:131   --> setPlayState Started  Output {AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1, 0x34}
enum TidalPlayerEvent: Equatable {
    /// The player set up output for a track; in the unified log, the
    /// converter's source format.
    case sinkOpened(TidalStreamFormat)
    case sinkStarted
    case sinkStopped
    case sinkClosed
    case playRequested
    case statusChanged(TidalPlaybackStatus)
    /// `uid` is the Core Audio device UID; nil means the system default output.
    case deviceSelected(uid: String?, exclusive: Bool)
    case outputStarted(deviceUID: String)
    case outputStopped(deviceUID: String)
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

    private static let converterPattern = try! NSRegularExpression(
        pattern: "Created a new in process converter -> 0x[0-9a-fA-F]+, from\\s+[0-9]+ ch,\\s+([0-9]+) Hz, (?:Int([0-9]+)|lpcm \\(0x[0-9a-fA-F]+\\) ([0-9]+)-bit|Float[0-9]+)",
        options: []
    )

    private static let playStatePattern = try! NSRegularExpression(
        pattern: "--> setPlayState (Started|Stopped)\\s+Output \\{([^,}]+)",
        options: []
    )

    private static let systemDeviceMarker = "attempting to select system controlled device"

    /// The `log stream` predicate for the messages `parseSystemLog` reads.
    static let systemLogPredicate = "process == \"TIDALPlayer\" AND (eventMessage CONTAINS \"Created a new in process converter\" OR eventMessage CONTAINS \"--> setPlayState\")"

    /// A `player.log` line. Only the shapes above are recognised, and only the
    /// fields they name are kept. Every other line, including the `COMMAND`
    /// lines that carry stream tokens and keys, gives nil.
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

    /// A unified-log `eventMessage` from the `TIDALPlayer` process.
    static func parseSystemLog(_ message: String) -> TidalPlayerEvent? {
        if message.contains("in process converter") {
            guard let groups = captures(converterPattern, in: message),
                  let rate = Double(groups[0]),
                  (8_000...768_000).contains(rate) else { return nil }
            let bitDepth = Int(groups[1]) ?? Int(groups[2])
            return .sinkOpened(TidalStreamFormat(sampleRate: rate, bitDepth: bitDepth))
        }

        if message.contains("setPlayState") {
            guard let groups = captures(playStatePattern, in: message) else { return nil }
            return groups[0] == "Started" ? .outputStarted(deviceUID: groups[1])
                                          : .outputStopped(deviceUID: groups[1])
        }

        return nil
    }

    /// One `log stream --style ndjson` line.
    static func parseSystemLogLine(_ line: String) -> TidalPlayerEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["eventMessage"] as? String else { return nil }
        return parseSystemLog(message)
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

/// Tidal's playback as reconstructed from its events.
///
/// Tidal sets up output once the first bytes are downloaded and the FLAC header
/// is parsed, and starts it once enough is buffered, often most of a second
/// later. So a slow download delays the setup itself and no audio can precede
/// it. Setup is not playback, though: Tidal also sets up the paused track it
/// restores at launch. Until something has played, a new format therefore waits
/// for the first sign of play. Once Tidal has played, a setup is a skip or the
/// next track, and its format starts at once, which leaves the buffering time
/// for the device to change rate before audio arrives. A same-rate gapless
/// boundary sets up nothing new.
struct TidalPlaybackState: Equatable {
    var format: TidalStreamFormat?
    var isPlaying = false
    var hasPlayed = false
    var deviceUID: String?

    /// Returns the format that starts playing because of `event`, if any.
    mutating func apply(_ event: TidalPlayerEvent) -> TidalStreamFormat? {
        switch event {
        case let .sinkOpened(newFormat):
            // One setup logs a converter per device it passes through; only a
            // change of format matters.
            let changed = newFormat != format
            format = newFormat
            return (isPlaying || hasPlayed) && changed ? newFormat : nil
        case .playRequested, .sinkStarted, .statusChanged(.active):
            return startPlaying()
        case let .outputStarted(uid):
            // Output restarting on another device needs that device switched.
            let moved = uid != deviceUID
            deviceUID = uid
            let started = startPlaying()
            return started ?? (moved ? format : nil)
        case let .outputStopped(uid):
            // Tidal's setup briefly passes through the default device; only
            // the device it plays to counts.
            if deviceUID == nil || uid == deviceUID {
                isPlaying = false
            }
        case .statusChanged(.paused), .statusChanged(.stopped), .sinkStopped:
            isPlaying = false
        case .statusChanged(.completed), .sinkClosed:
            // A track boundary or the close before the next open, not a stop.
            break
        case let .deviceSelected(uid, _):
            deviceUID = uid
        }
        return nil
    }

    private mutating func startPlaying() -> TidalStreamFormat? {
        let wasPlaying = isPlaying
        isPlaying = true
        hasPlayed = true
        return wasPlaying ? nil : format
    }
}

/// Follows Tidal's playback and publishes it.
///
/// The unified log is the live source: Core Audio's messages from inside the
/// player arrive in real time. Tidal's own `player.log` is written in batches,
/// often seconds late, so it only rebuilds the state at start-up, and stands in
/// live until the unified log has delivered its first event.
///
/// Subscribe to `formatStarted` to act when a format starts playing, to `state`
/// for the current snapshot (replayed to new subscribers), or to `events` for
/// every applied event. All three publish on a private queue.
///
/// Raw `player.log` lines are never stored or published: the file holds stream
/// URLs with access tokens and decryption keys.
final class TidalPlayerLogController {
    static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TIDAL/player.log")

    static func isTidalRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tidal.desktop").isEmpty
    }

    /// Called on the main queue when the unified log reader gives up.
    var onSystemLogLost: (() -> Void)? {
        get { systemLog?.onGaveUp }
        set { systemLog?.onGaveUp = newValue }
    }

    var events: AnyPublisher<TidalPlayerEvent, Never> { eventSubject.eraseToAnyPublisher() }
    var state: AnyPublisher<TidalPlaybackState, Never> { stateSubject.eraseToAnyPublisher() }
    var formatStarted: AnyPublisher<TidalPlaybackState, Never> { formatSubject.eraseToAnyPublisher() }

    private let eventSubject = PassthroughSubject<TidalPlayerEvent, Never>()
    private let stateSubject = CurrentValueSubject<TidalPlaybackState, Never>(TidalPlaybackState())
    private let formatSubject = PassthroughSubject<TidalPlaybackState, Never>()

    private var tail: LogFileTail!
    private let isPlayerRunning: () -> Bool
    private let systemLog: LogStreamController?
    private let systemLogHistory: () -> [String]
    private let queue = DispatchQueue(label: "tidal.playerlog.controller")
    private var playback = TidalPlaybackState()
    private var systemLogIsLive = false
    private var isRunning = false

    /// `systemLog` nil leaves only `player.log`, as in tests that feed the
    /// unified log through `ingestSystemLogLine`. `systemLogHistory` returns
    /// the unified log's recent ndjson lines, replayed at start-up.
    init(url: URL = TidalPlayerLogController.defaultLogURL,
         reopenInterval: TimeInterval = 5,
         isPlayerRunning: @escaping () -> Bool = TidalPlayerLogController.isTidalRunning,
         systemLog: LogStreamController? = TidalPlayerLogController.makeSystemLog(),
         systemLogHistory: @escaping () -> [String] = TidalPlayerLogController.recentSystemLog) {
        self.isPlayerRunning = isPlayerRunning
        self.systemLog = systemLog
        self.systemLogHistory = systemLogHistory
        systemLog?.onLine = { [weak self] line in
            self?.ingestSystemLogLine(line)
        }
        tail = LogFileTail(url: url, reopenInterval: reopenInterval, queue: queue,
                           onHistory: { [weak self] in self?.catchUp(on: $0) },
                           onLines: { [weak self] in self?.ingestFileLines($0) })
    }

    static func recentSystemLog() -> [String] {
        LogStreamController.history(predicate: TidalPlayerLogParser.systemLogPredicate, last: "30m")
    }

    static func makeSystemLog() -> LogStreamController {
        let stream = LogStreamController()
        stream.predicate = TidalPlayerLogParser.systemLogPredicate
        // `recentSystemLog` replays its history at start-up instead.
        stream.catchUpPredicate = nil
        return stream
    }

    // MARK: - Lifecycle
    //
    // All file and playback state lives behind `queue`. `start()` and `stop()`
    // are safe to call from any thread.

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.systemLogIsLive = false
            self.playback = TidalPlaybackState()
            self.tail.start()
            // Live lines queue behind this, so they apply after the history.
            self.finishCatchUp()
        }
        systemLog?.start()
    }

    func stop() {
        systemLog?.stop()
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.tail.stop()
        }
    }

    /// One `log stream --style ndjson` line from the `TIDALPlayer` process.
    func ingestSystemLogLine(_ line: String) {
        guard let event = TidalPlayerLogParser.parseSystemLogLine(line) else { return }
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.systemLogIsLive = true
            self.publish(event)
        }
    }

    /// Must be called on `queue`.
    private func catchUp(on history: Data) {
        for event in LogFileTail.lines(in: history).compactMap(TidalPlayerLogParser.parse) {
            _ = playback.apply(event)
        }
    }

    /// Must be called on `queue`. `player.log` trails the player by up to
    /// ~18 s, so the unified log's recent history, which is exact, has the
    /// last word before the rebuilt state is published.
    private func finishCatchUp() {
        guard isRunning else { return }
        var rebuilt = playback
        let events = systemLogHistory().compactMap(TidalPlayerLogParser.parseSystemLogLine)
        for event in events {
            _ = rebuilt.apply(event)
        }
        if !events.isEmpty {
            // The file's lines arrive late and repeat what the live stream delivers.
            systemLogIsLive = true
        }
        // A player that quit mid-track never logged its stop.
        if !isPlayerRunning() {
            rebuilt.isPlaying = false
        }
        // Plays from earlier sessions say nothing about the next setup, which
        // may be the paused track a relaunched Tidal restores.
        rebuilt.hasPlayed = rebuilt.isPlaying
        playback = rebuilt
        stateSubject.send(rebuilt)
        if rebuilt.isPlaying, rebuilt.format != nil {
            formatSubject.send(rebuilt)
        }
    }

    /// Must be called on `queue`.
    private func ingestFileLines(_ lines: [String]) {
        // Once the unified log is live, the file's late lines only repeat it.
        guard !systemLogIsLive else { return }
        lines.compactMap(TidalPlayerLogParser.parse).forEach(publish)
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
}
