import Combine
import Foundation

/// What any player shows in Control Center's Now Playing, through
/// mediaremote-adapter (Vendor/mediaremote-adapter).
///
/// Since macOS 15.4 MediaRemote only answers entitled processes, so
/// `MediaRemoteController` gets nothing back. The adapter loads a small
/// framework into `/usr/bin/perl`, which is entitled, and streams one JSON
/// line per change. Both are built from the pinned submodule into the app
/// bundle by scripts/build-mediaremote-adapter.sh.
final class NowPlayingAdapter {
    struct Track: Equatable {
        let bundleID: String
        let title: String
        let artist: String?
        let album: String?
        let artwork: Data?
        let isPlaying: Bool
        let elapsed: Double?
        let duration: Double?
        let timestamp: Date?
    }

    /// The MediaRemote command IDs the adapter's `send` takes.
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// The current track, replayed to new subscribers; nil when nothing
    /// plays or the adapter is missing. Publishes on a private queue.
    var track: AnyPublisher<Track?, Never> { trackSubject.removeDuplicates().eraseToAnyPublisher() }

    /// False when the build did not bundle the adapter.
    let isAvailable: Bool

    private let trackSubject = CurrentValueSubject<Track?, Never>(nil)
    private let launcher: [String]
    private let stream = LogStreamController()
    private let queue = DispatchQueue(label: "nowplaying.adapter")
    private var payload: [String: Any] = [:]

    init(bundle: Bundle = .main) {
        let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl")
        let framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
        if let script, let framework, FileManager.default.fileExists(atPath: framework.path) {
            launcher = ["/usr/bin/perl", script.path, framework.path]
            isAvailable = true
        } else {
            launcher = []
            isAvailable = false
        }

        // Tidal briefly publishes a mix of the old and the new track when it
        // changes tracks; the adapter recommends holding its updates 1 s.
        stream.command = launcher + ["stream", "--experimental-peculiar-debounce:com.tidal.desktop=1000"]
        stream.onLine = { [weak self] line in
            self?.ingest(line)
        }
    }

    func start() {
        guard isAvailable else { return }
        stream.start()
    }

    func stop() {
        stream.stop()
        queue.async { [weak self] in
            self?.payload = [:]
            self?.trackSubject.send(nil)
        }
    }

    /// Sends `command` to the app that is now playing.
    func send(_ command: Command) {
        guard isAvailable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher[0])
        process.arguments = Array(launcher.dropFirst()) + ["send", String(command.rawValue)]
        try? process.run()
    }

    private func ingest(_ line: String) {
        queue.async { [weak self] in
            guard let self, let merged = Self.merge(line: line, into: self.payload) else { return }
            self.payload = merged
            self.trackSubject.send(Self.track(from: merged))
        }
    }

    // MARK: - Parsing

    /// Applies one `stream` line. A diff carries only the changed keys of the
    /// same item, with `null` for a removed one; anything else replaces the
    /// payload. Returns nil for a line that is not a data update.
    static func merge(line: String, into payload: [String: Any]) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "data",
              let update = json["payload"] as? [String: Any] else { return nil }

        guard json["diff"] as? Bool == true else {
            return update.filter { !($0.value is NSNull) }
        }
        var merged = payload
        for (key, value) in update {
            merged[key] = value is NSNull ? nil : value
        }
        return merged
    }

    static func track(from payload: [String: Any]) -> Track? {
        guard let bundleID = payload["bundleIdentifier"] as? String,
              let title = payload["title"] as? String, !title.isEmpty else { return nil }
        return Track(
            bundleID: payload["parentApplicationBundleIdentifier"] as? String ?? bundleID,
            title: title,
            artist: payload["artist"] as? String,
            album: payload["album"] as? String,
            artwork: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) },
            isPlaying: payload["playing"] as? Bool ?? false,
            elapsed: payload["elapsedTime"] as? Double,
            duration: payload["duration"] as? Double,
            timestamp: (payload["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }
}
