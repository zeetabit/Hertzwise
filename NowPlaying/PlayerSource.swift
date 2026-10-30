import AppKit
import Foundation

/// A player Hertzwise can follow.
enum PlayerSource: CaseIterable {
    case tidal, appleMusic

    /// The app, as Launch Services and the now playing service name it.
    var appBundleID: String {
        switch self {
        case .tidal: return "com.tidal.desktop"
        case .appleMusic: return "com.apple.Music"
        }
    }

    /// The process that outputs the audio: Tidal plays from a helper.
    var audioBundleID: String {
        switch self {
        case .tidal: return "com.tidal.desktop.player"
        case .appleMusic: return "com.apple.Music"
        }
    }

    init?(bundleID: String) {
        guard let source = Self.allCases.first(where: { $0.appBundleID == bundleID || $0.audioBundleID == bundleID }) else {
            return nil
        }
        self = source
    }
}

/// Which players Hertzwise follows. Following one costs no permission: its
/// sample rate comes from logs, and track info and controls from the
/// MediaRemote adapter. A player that is not followed runs no reader.
enum PlayerSources {
    private static let tidalKey = "source.tidal"
    private static let appleMusicKey = "source.appleMusic"

    static var tidal: Bool {
        get { UserDefaults.standard.object(forKey: tidalKey) as? Bool ?? isInstalled(PlayerSource.tidal.appBundleID) }
        set { UserDefaults.standard.set(newValue, forKey: tidalKey) }
    }

    static var appleMusic: Bool {
        get { UserDefaults.standard.object(forKey: appleMusicKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: appleMusicKey) }
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

/// Decides which followed player drives the output rate: of those outputting
/// audio, the one that started last. While none outputs, any may prepare the
/// device, as Tidal does at setup before its output starts.
struct SourceArbiter: Equatable {
    private(set) var outputting: Set<PlayerSource> = []
    /// Most recent start last.
    private var startOrder: [PlayerSource] = []
    /// The player that drove the output last, kept while everything pauses.
    private(set) var lastActive: PlayerSource?
    /// Until Core Audio first reports, a paused player's restored state could
    /// override one that is already playing.
    private var hasReport = false

    var active: PlayerSource? {
        startOrder.last(where: outputting.contains)
    }

    /// The player whose rate and state the panel shows.
    var shown: PlayerSource? {
        active ?? lastActive
    }

    func mayDrive(_ source: PlayerSource) -> Bool {
        hasReport && (active == nil || active == source)
    }

    /// Returns true when `active` changed.
    @discardableResult
    mutating func update(outputting now: Set<PlayerSource>) -> Bool {
        let before = active
        hasReport = true
        for started in now.subtracting(outputting) {
            startOrder.removeAll { $0 == started }
            startOrder.append(started)
        }
        outputting = now
        if let active {
            lastActive = active
        }
        return active != before
    }
}
