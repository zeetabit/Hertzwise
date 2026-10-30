import Foundation
import AppKit
import Combine
import CoreAudio
import Observation

/// `@Observable`, so each panel card re-renders only for the properties it
/// reads. The 1 Hz poll writes through `assign`, which skips unchanged values —
/// every write to an observed property would otherwise invalidate its readers.
@Observable
final class SampleRateModel {
    var currentTrackTitle: String = "Not playing"
    var artistName: String = ""
    var albumName: String = ""
    var artwork: NSImage?
    var isPlaying: Bool = false
    var elapsedSeconds: Double?
    var durationSeconds: Double?
    var trackSampleRateDisplay: String = "Unknown"
    var outputDeviceName: String = "Unknown"
    var outputDeviceIcon: String = "speaker.wave.2.fill"
    var outputSampleRateDisplay: String = "Unknown"
    var outputSampleRate: Double?
    var outputDevices: [AudioOutputDevice] = []
    var currentOutputDeviceID: AudioDeviceID?
    var availableSampleRates: [Double] = []
    var outputVolume: Double = 0.5
    /// The output devices whose volume Hertzwise applies to the samples, by UID.
    var volumeControlledUIDs: Set<String> = []
    var volumeAvailable: Bool = false
    var sampleRateSourceDisplay: String = "Unknown"
    /// Codec, bit depth and tier from Music's `activeFormat` log line, when seen.
    var trackFormat: TrackFormat?
    var logStatusMessage: String = ""
    /// Set while a followed player's rate cannot be seen; the panel turns yellow.
    var signalWarning: String?
    var statusMessage: String = ""
    /// Set while a followed player plays to a device it chose itself, other
    /// than the Mac's output: "Use as output" cannot move it.
    var outputNotice: String?
    /// The device can't play the track's rate, so it plays resampled.
    var rateLimitNotice: String?
    var autoSwitchEnabled: Bool = true
    var tidalEnabled = PlayerSources.tidal {
        didSet {
            PlayerSources.tidal = tidalEnabled
            if logParserEnabled { startLogParser() }
            rearbitrate()
        }
    }
    var appleMusicEnabled = PlayerSources.appleMusic {
        didSet {
            PlayerSources.appleMusic = appleMusicEnabled
            if appleMusicEnabled, !nowPlayingAdapter.isAvailable { requestMediaAccess() }
            if logParserEnabled { startLogParser() }
            rearbitrate()
            updateState()
        }
    }
    var logParserEnabled: Bool = true {
        didSet {
            if logParserEnabled {
                startLogParser()
            } else {
                logController.stop()
                tidalLogController.stop()
                logStatusMessage = L10n.string("Log parser disabled")
            }
        }
    }

    private let mediaRemoteController = MediaRemoteController()
    private let nowPlayingAdapter = NowPlayingAdapter()
    @ObservationIgnored private var adapterSubscription: AnyCancellable?
    @ObservationIgnored private var adapterTrack: NowPlayingAdapter.Track?
    private let musicController = MusicController()
    private let logController = LogStreamController()
    private let tidalLogController = TidalPlayerLogController()
    private let audioController = AudioDeviceController()
    @ObservationIgnored private var tidalSubscription: AnyCancellable?
    @ObservationIgnored private var tidalStateSubscription: AnyCancellable?
    @ObservationIgnored private var tidalPlayback = TidalPlaybackState()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deviceObservation: AudioDeviceObservation?
    @ObservationIgnored private var musicObserver: NSObjectProtocol?
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var processMonitor: AudioProcessMonitor?
    @ObservationIgnored private var outputtingBundleIDs: Set<String> = []
    @ObservationIgnored private var playbackDevices: [String: Set<AudioObjectID>] = [:]
    @ObservationIgnored private var arbiter = SourceArbiter()
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pauseObserver: NSObjectProtocol?
    /// Tidal's rate, kept apart from Music's `stableLogSampleRate` so that one
    /// player's track change never clears the other's lock.
    @ObservationIgnored private var tidalLockedRate: Double?
    @ObservationIgnored private var tidalDeviceUID: String?
    @ObservationIgnored private var latestLogCandidateRate: Double?
    @ObservationIgnored private var stableLogSampleRate: Double?
    /// Set when Music's rate came from its decoder line, which every stream
    /// logs: a title change then needs no reset to the vote window.
    @ObservationIgnored private var musicRateIsExact = false
    @ObservationIgnored private var signalCheck: DispatchWorkItem?
    @ObservationIgnored private var signalLostSource: PlayerSource?
    /// How long a playing player may go without a known rate before the panel says so.
    private static let signalGracePeriod: TimeInterval = 5
    @ObservationIgnored private var latestTrackInfo: TrackInfo?
    @ObservationIgnored private var latestTrackInfoError: String?
    @ObservationIgnored private var trackInfoFetchInFlight = false
    @ObservationIgnored private var artworkFetchInFlight = false
    /// The track whose cover the AppleScript fallback still owes us, if any.
    @ObservationIgnored private var pendingArtworkTitle: String?

    /// A log-derived vote, buffered off the main thread before being folded
    /// into `logRateWindow`. See `enqueueLogVote`.
    private struct LogVote {
        let rate: Double
        let weight: Int
    }

    private let logVoteQueue = DispatchQueue(label: "io.github.zeetabit.hertzwise.logvotes")
    @ObservationIgnored private var pendingLogVotes: [LogVote] = []
    @ObservationIgnored private var logFlushScheduled = false
    private static let logFlushInterval: TimeInterval = 0.05
    @ObservationIgnored private var stableLogSampleRateAt: Date?
    @ObservationIgnored private var logRateWindow: [(rate: Double, date: Date, weight: Int)] = []
    @ObservationIgnored private var lastTrackTitle: String?
    @ObservationIgnored private var lastAppliedSampleRate: Double?
    @ObservationIgnored private var lastAppliedAt: Date?
    @ObservationIgnored private var lastArtworkData: Data?
    @ObservationIgnored private var artworkTrackTitle: String?
    @ObservationIgnored private var isAdjustingVolume = false
    @ObservationIgnored private var trackFormatAt: Date?

    init() {
        // With the adapter, Apple Music's track info needs no permission.
        if appleMusicEnabled, !nowPlayingAdapter.isAvailable {
            requestMediaAccess()
        }
        startLogParser()
        startPolling()
    }

    private func requestMediaAccess() {
        MediaAuthorizationController.requestIfNeeded { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.statusMessage = L10n.string("Media & Apple Music access denied in Privacy & Security.")
                }
            }
        }
    }

    /// Nil until a rate is locked, so the menu bar shows only the icon.
    var menuBarTitle: String? {
        trackSampleRateDisplay.contains("kHz") ? trackSampleRateDisplay : nil
    }

    func refreshNow() {
        updateState()
    }

    /// The panel's transport drives the player shown, through the adapter;
    /// without it, only Apple Music through AppleScript.
    var canControlPlayback: Bool {
        nowPlayingAdapter.isAvailable ? followedTrack != nil : appleMusicEnabled
    }

    func togglePlayPause() {
        guard canControlPlayback else { return }
        isPlaying.toggle()
        sendTransport(.togglePlayPause, fallback: .playPause)
    }

    func nextTrack() {
        guard canControlPlayback else { return }
        sendTransport(.nextTrack, fallback: .nextTrack)
    }

    func previousTrack() {
        guard canControlPlayback else { return }
        sendTransport(.previousTrack, fallback: .previousTrack)
    }

    var canSeek: Bool {
        nowPlayingAdapter.isAvailable && followedTrack != nil && (durationSeconds ?? 0) > 0
    }

    func seek(toFraction fraction: Double) {
        guard canSeek, let durationSeconds else { return }
        let seconds = min(max(fraction, 0), 1) * durationSeconds
        nowPlayingAdapter.seek(to: seconds)
        // Shown at once; the adapter's update confirms it.
        elapsedSeconds = seconds
    }

    /// Posted to pause whatever plays, before quitting.
    static let pauseRequest = Notification.Name("io.github.zeetabit.hertzwise.pauseRequest")

    func pausePlayback() {
        sendTransport(.pause, fallback: .pause)
    }

    private func sendTransport(_ command: NowPlayingAdapter.Command, fallback: MusicCommand) {
        if nowPlayingAdapter.isAvailable {
            nowPlayingAdapter.send(command)
        } else {
            musicController.send(fallback)
        }
        scheduleQuickRefresh()
    }

    func beginVolumeAdjustment() {
        isAdjustingVolume = true
    }

    func endVolumeAdjustment() {
        isAdjustingVolume = false
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        outputVolume = clamped
        _ = audioController.setOutputVolume(Float(clamped))
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != currentOutputDeviceID else { return }

        if audioController.setDefaultOutputDevice(deviceID) {
            currentOutputDeviceID = deviceID
            statusMessage = L10n.string("Switched output device")
        } else {
            statusMessage = L10n.string("Failed to switch output device")
        }
        scheduleQuickRefresh()
    }

    func selectSampleRate(_ rate: Double) {
        guard OutputRateLock.shared.heldRate == nil else {
            statusMessage = L10n.string("Turn the EQ off to change the sample rate.")
            return
        }
        // Manual choice would be reverted by auto switch within a second,
        // so disengage it when they conflict.
        if autoSwitchEnabled,
           let stableLogSampleRate,
           abs(stableLogSampleRate - rate) >= 1.0 {
            autoSwitchEnabled = false
        }

        if audioController.setDefaultOutputSampleRate(rate) != nil {
            outputSampleRate = rate
            outputSampleRateDisplay = formatSampleRate(rate)
            statusMessage = L10n.format("Output set to %@", formatSampleRate(rate))
        } else {
            statusMessage = L10n.string("Failed to set output sample rate")
        }
        scheduleQuickRefresh()
    }

    private func scheduleQuickRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateState()
        }
    }

    func dumpNowPlaying() {
        mediaRemoteController.dumpNowPlayingInfo()
    }

    func restartLogParser() {
        startLogParser()
    }

    func dumpRecentLogs() {
        logController.dumpRecentLines()
    }

    /// Music posts this on every play, pause and track change.
    private static let musicPlayerInfo = Notification.Name("com.apple.Music.playerInfo")

    /// Refreshes only while the panel shows the per-second progress. Hidden,
    /// changes arrive as Core Audio and Music notifications instead, with a
    /// slow refresh as a safety net for anything that notifies nothing.
    private static let visibleRefreshInterval: TimeInterval = 1
    private static let hiddenRefreshInterval: TimeInterval = 15

    private func startPolling() {
        updateVolumeStage()
        processMonitor = AudioProcessMonitor { [weak self] bundleIDs in
            self?.outputtingBundleIDs = Set(bundleIDs.keys)
            self?.playbackDevices = bundleIDs
            self?.updateOutputNotice()
            self?.rearbitrate()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, app?.bundleIdentifier == PlayerSource.appleMusic.appBundleID,
                      self.logParserEnabled else { return }
                self.startLogParser()
            })
        }
        pauseObserver = NotificationCenter.default.addObserver(forName: Self.pauseRequest, object: nil, queue: .main) { [weak self] _ in
            self?.pausePlayback()
        }
        updateState()
        deviceObservation = audioController.observeChanges { [weak self] in
            self?.updateVolumeStage()
            self?.updateState()
            self?.updateOutputNotice()
        }
        musicObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.musicPlayerInfo, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.appleMusicEnabled else { return }
            self.updateState()
        }
        scheduleRefresh()
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            updateState()
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        let interval = panelVisible ? Self.visibleRefreshInterval : Self.hiddenRefreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        // Lets macOS batch this wake-up with others.
        timer.tolerance = interval / 10
        self.timer = timer
    }

    private func updateState() {
        let outputDevice = audioController.defaultOutputDeviceInfo()

        // Kick off an off-main refresh for the next pass. The AppleScript
        // round trip used to run inline here and block the main thread (and
        // therefore this timer) for tens of seconds; now it only ever updates
        // the cached value that `applyNowPlaying` reads.
        refreshTrackInfoIfNeeded()

        assign(\.outputDeviceName, outputDevice.name)
        assign(\.outputDeviceIcon, outputDevice.iconName)
        assign(\.outputSampleRate, outputDevice.sampleRate)
        assign(\.outputSampleRateDisplay, formatSampleRate(outputDevice.sampleRate))
        assign(\.currentOutputDeviceID, outputDevice.id)
        assign(\.outputDevices, audioController.outputDevices())
        if let deviceID = outputDevice.id {
            assign(\.availableSampleRates, audioController.availableSampleRates(deviceID: deviceID))
        } else {
            assign(\.availableSampleRates, [])
        }

        if !isAdjustingVolume {
            if let volumeInfo = audioController.outputVolumeInfo() {
                assign(\.volumeAvailable, volumeInfo.settable)
                assign(\.outputVolume, Double(volumeInfo.volume))
            } else {
                assign(\.volumeAvailable, false)
            }
        }

        guard !nowPlayingAdapter.isAvailable else {
            applyNowPlaying(NowPlayingResult(info: followedTrack.map(Self.nowPlayingInfo), errorMessage: nil),
                            outputDevice: outputDevice)
            return
        }
        mediaRemoteController.nowPlayingInfo { [weak self] result in
            DispatchQueue.main.async {
                self?.applyNowPlaying(result, outputDevice: outputDevice)
            }
        }
    }

    /// Whether the panel shows an Apple Music track: from the adapter, or from
    /// AppleScript in a build without it.
    private var isMusicTrack: Bool {
        nowPlayingAdapter.isAvailable ? followedTrack?.bundleID == PlayerSource.appleMusic.appBundleID
                                      : appleMusicEnabled
    }

    /// The adapter's track when it comes from a player Hertzwise follows.
    private var followedTrack: NowPlayingAdapter.Track? {
        guard let adapterTrack, let source = PlayerSource(bundleID: adapterTrack.bundleID),
              isFollowed(source) else { return nil }
        return adapterTrack
    }

    private static func nowPlayingInfo(_ track: NowPlayingAdapter.Track) -> NowPlayingInfo {
        NowPlayingInfo(title: track.title, artist: track.artist, album: track.album,
                       artworkData: track.artwork, sampleRate: nil, isPlaying: track.isPlaying,
                       elapsed: track.elapsed, duration: track.duration, timestamp: track.timestamp)
    }

    /// Refreshes the Music.app fallback metadata without blocking. At most one
    /// fetch is ever in flight; the result lands on the main queue.
    private func refreshTrackInfoIfNeeded() {
        guard appleMusicEnabled, !nowPlayingAdapter.isAvailable else {
            latestTrackInfo = nil
            latestTrackInfoError = nil
            return
        }
        guard !trackInfoFetchInFlight else { return }
        trackInfoFetchInFlight = true

        musicController.fetchTrackInfo { [weak self] result in
            guard let self else { return }
            self.trackInfoFetchInFlight = false
            self.latestTrackInfo = result.track
            self.latestTrackInfoError = result.errorMessage
        }
    }

    private func applyNowPlaying(_ result: NowPlayingResult,
                                 outputDevice: OutputDeviceInfo) {
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            assign(\.currentTrackTitle, "Unavailable")
            assign(\.trackSampleRateDisplay, "Unknown")
            assign(\.statusMessage, errorMessage)
            return
        }

        let info = result.info
        let fallbackTrack = latestTrackInfo

        var resolvedTitle = info?.title ?? ""
        if resolvedTitle.isEmpty || resolvedTitle == "Unknown", let fallbackTrack {
            resolvedTitle = fallbackTrack.title
        }

        if resolvedTitle.isEmpty, tidalEnabled, tidalPlayback.isPlaying {
            assign(\.currentTrackTitle, "Tidal")
            assign(\.artistName, "")
            assign(\.albumName, "")
            assign(\.isPlaying, true)
            assign(\.elapsedSeconds, nil)
            assign(\.durationSeconds, nil)
            updateArtwork(nil)
            updateCurrentSampleRateDisplay()
            assign(\.statusMessage, "")
            return
        }

        guard !resolvedTitle.isEmpty else {
            assign(\.currentTrackTitle, "Not playing")
            assign(\.artistName, "")
            assign(\.albumName, "")
            assign(\.isPlaying, false)
            assign(\.elapsedSeconds, nil)
            assign(\.durationSeconds, nil)
            assign(\.trackFormat, nil)
            updateArtwork(nil)
            updateCurrentSampleRateDisplay()
            assign(\.statusMessage, latestTrackInfoError ?? "")
            return
        }

        if isMusicTrack {
            updateTrackTitle(resolvedTitle)
        }
        assign(\.currentTrackTitle, resolvedTitle)
        assign(\.artistName, info?.artist ?? fallbackTrack?.artist ?? "")
        assign(\.albumName, info?.album ?? fallbackTrack?.album ?? "")
        assign(\.isPlaying, info?.isPlaying ?? fallbackTrack?.isPlaying ?? false)
        assign(\.durationSeconds, info?.duration ?? fallbackTrack?.duration)
        updateElapsed(info: info, fallback: fallbackTrack)
        updateArtwork(info?.artworkData)

        updateCurrentSampleRateDisplay()

        guard isPlaying else {
            assign(\.statusMessage, L10n.string("Paused"))
            return
        }

        // What follows re-applies Music's rate, as SyncHz did every refresh.
        guard isMusicTrack, shownSource == .appleMusic else {
            assign(\.statusMessage, "")
            return
        }

        if let held = OutputRateLock.shared.heldRate {
            assign(\.statusMessage, L10n.format("EQ on — output held at %@", formatSampleRate(held)))
            return
        }

        guard autoSwitchEnabled else {
            assign(\.statusMessage, L10n.string("Auto switch disabled"))
            return
        }

        guard let trackSampleRate = stableLogSampleRate else {
            assign(\.statusMessage, L10n.string("Waiting for log sample rate"))
            return
        }
        let targetSampleRate = playableSampleRate(trackSampleRate, deviceUID: nil)

        if let currentOutputRate = outputDevice.sampleRate,
           abs(currentOutputRate - targetSampleRate) < 1.0 {
            assign(\.statusMessage, L10n.format("Output already at %@", formatSampleRate(targetSampleRate)))
            return
        }

        if audioController.setDefaultOutputSampleRate(targetSampleRate) != nil {
            assign(\.statusMessage, L10n.format("Switched output to %@", formatSampleRate(targetSampleRate)))
        } else {
            assign(\.statusMessage, L10n.string("Failed to switch output sample rate"))
        }
    }

    /// Writes an observed property only when the value actually changes.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SampleRateModel, Value>,
                                          _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func updateElapsed(info: NowPlayingInfo?, fallback: TrackInfo?) {
        if let elapsed = info?.elapsed {
            if isPlaying, let timestamp = info?.timestamp {
                let projected = elapsed + Date().timeIntervalSince(timestamp)
                assign(\.elapsedSeconds, min(projected, durationSeconds ?? projected))
            } else {
                assign(\.elapsedSeconds, elapsed)
            }
        } else {
            assign(\.elapsedSeconds, fallback?.position)
        }
    }

    private func updateArtwork(_ data: Data?) {
        let trackChanged = artworkTrackTitle != currentTrackTitle
        artworkTrackTitle = currentTrackTitle

        if let data {
            pendingArtworkTitle = nil
            applyArtwork(data)
            return
        }

        // MediaRemote artwork is unavailable; ask Music directly, but only
        // once per track. The fetch runs off the main thread.
        guard trackChanged else { return }

        guard currentTrackTitle != "Not playing" else {
            pendingArtworkTitle = nil
            applyArtwork(nil)
            return
        }

        pendingArtworkTitle = currentTrackTitle
        fetchPendingArtwork()
    }

    /// At most one fetch is in flight. A track change mid-flight does not
    /// start a second one; the running fetch re-issues itself for the new
    /// track when it lands, so the new track is never left without a cover.
    private func fetchPendingArtwork() {
        guard appleMusicEnabled, !nowPlayingAdapter.isAvailable else { return }
        guard !artworkFetchInFlight, let title = pendingArtworkTitle else { return }
        artworkFetchInFlight = true

        musicController.fetchArtwork { [weak self] data in
            guard let self else { return }
            self.artworkFetchInFlight = false

            // Drop the result if the track changed while we were fetching;
            // otherwise a slow reply would show the previous cover.
            guard self.pendingArtworkTitle == title else {
                self.fetchPendingArtwork()
                return
            }
            self.pendingArtworkTitle = nil
            self.applyArtwork(data)
        }
    }

    private func applyArtwork(_ data: Data?) {
        guard data != lastArtworkData else { return }
        lastArtworkData = data
        artwork = data.flatMap { NSImage(data: $0) }
    }

    func formatSampleRate(_ sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else {
            return "Unknown"
        }

        let khz = sampleRate / 1000.0
        let rounded = (khz * 10).rounded() / 10

        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f kHz", rounded)
        }

        return String(format: "%.1f kHz", rounded)
    }

    private func startLogParser() {
        clearSignalWarning()
        logController.onSampleRate = { [weak self] rate, message in
            if let message, LogStreamController.isSourceRateLine(message) {
                DispatchQueue.main.async { self?.lockExactMusicRate(rate) }
                return
            }
            let weight = (message?.contains("Derived from frames/duration") ?? false) ? 3 : 1
            self?.enqueueLogVote(rate: rate, weight: weight)
        }

        logController.onGaveUp = { [weak self] in
            self?.reportSignalLost(.appleMusic, L10n.format("%@: log lost; not switching", PlayerSource.appleMusic.name))
        }
        tidalLogController.onSystemLogLost = { [weak self] in
            self?.reportSignalLost(.tidal, L10n.format("%@: log lost; not switching", PlayerSource.tidal.name))
        }

        logController.onEarlierSampleRate = { [weak self] rate in
            DispatchQueue.main.async { self?.restoreMusicRate(rate) }
        }

        logController.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                // Known statuses ("Log stream started") are table keys; anything
                // else, such as raw `log` stderr, falls through unchanged.
                self?.logStatusMessage = L10n.string(status)
            }
        }

        logController.onTrackFormat = { [weak self] format in
            DispatchQueue.main.async {
                guard let self, self.arbiter.mayDrive(.appleMusic) else { return }
                self.trackFormatAt = Date()
                self.assign(\.trackFormat, format)
            }
        }

        // Music's reader runs only while Music does.
        if appleMusicEnabled, isMusicRunning {
            logController.start()
        } else {
            logController.stop()
        }

        tidalSubscription = tidalLogController.formatStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playback in
                self?.handleTidalFormatStarted(playback)
            }
        tidalStateSubscription = tidalLogController.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playback in
                guard let self else { return }
                let changed = playback.isPlaying != self.tidalPlayback.isPlaying
                self.tidalPlayback = playback
                if changed { self.updateState() }
            }
        if tidalEnabled {
            tidalLogController.start()
        } else {
            tidalLogController.stop()
        }

        adapterSubscription = nowPlayingAdapter.track
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.adapterTrack = track
                self?.updateState()
            }
        if tidalEnabled || appleMusicEnabled {
            nowPlayingAdapter.start()
        } else {
            nowPlayingAdapter.stop()
        }
    }

    /// Tidal logs the exact format it plays, so its rate locks directly
    /// instead of going through the log-vote window.
    private func handleTidalFormatStarted(_ playback: TidalPlaybackState) {
        guard let format = playback.format else { return }
        clearSignalWarning(for: .tidal)
        tidalLockedRate = format.sampleRate
        tidalDeviceUID = playback.deviceUID
        guard arbiter.mayDrive(.tidal) else { return }
        trackFormatAt = Date()
        assign(\.trackFormat, TrackFormat(codec: nil, bitDepth: format.bitDepth, tier: nil))
        trackSampleRateDisplay = formatSampleRate(format.sampleRate)
        sampleRateSourceDisplay = "Log (locked)"
        logStatusMessage = L10n.format("Tidal locked at %@", formatSampleRate(format.sampleRate))
        driveTidal(rate: format.sampleRate)
    }

    private func driveTidal(rate: Double) {
        // In exclusive mode Tidal sets the device rate itself and holds the
        // device, so switching it from here would only fail.
        guard !audioController.isHeldByAnotherProcess(deviceUID: tidalDeviceUID) else {
            logStatusMessage = L10n.string("Tidal is in exclusive mode; not switching")
            return
        }
        applyLogAutoSwitch(sampleRate: rate, deviceUID: tidalDeviceUID)
    }

    /// Paths follow every connected device, whether or not it is the system
    /// output: Tidal keeps playing to its own device.
    private func updateVolumeStage() {
        let uids = audioController.outputDevices().map(\.uid).filter { !$0.isEmpty }
        assign(\.volumeControlledUIDs, Set(uids.filter { HostVolumeControl.isEnabled(uid: $0) }))
        OutputPaths.shared.updateDevices(connected: uids)
    }

    /// The rate the device plays `trackRate` at, noting when that isn't the
    /// track's own: the track is then resampled, which the user should know.
    private func playableSampleRate(_ trackRate: Double, deviceUID: String?) -> Double {
        let playable = audioController.playableSampleRate(trackRate, deviceUID: deviceUID) ?? trackRate
        guard abs(playable - trackRate) >= 1 else {
            assign(\.rateLimitNotice, nil)
            return trackRate
        }
        let device = outputDevices.first { deviceUID == nil ? $0.id == currentOutputDeviceID : $0.uid == deviceUID }
        let name = device?.name ?? outputDeviceName
        var notice = L10n.format("%1$@ can't play %2$@, so it plays resampled at %3$@.",
                                 name, formatSampleRate(trackRate), formatSampleRate(playable))
        if let hint = DeviceRateLimitHint.hint(modelUID: audioController.modelUID(deviceUID: deviceUID)) {
            notice += " " + hint
        }
        assign(\.rateLimitNotice, notice)
        return playable
    }

    private func updateOutputNotice() {
        let notice = PlayerSource.allCases.lazy.compactMap { source -> String? in
            guard self.isFollowed(source),
                  let devices = self.playbackDevices[source.audioBundleID], !devices.isEmpty,
                  let output = self.currentOutputDeviceID, !devices.contains(output),
                  let device = self.outputDevices.first(where: { devices.contains($0.id) }) else { return nil }
            return L10n.format("%1$@ plays to %2$@ from its own settings, not the Mac's output", source.name, device.name)
        }.first
        assign(\.outputNotice, notice)
    }

    func setVolumeControl(_ enabled: Bool, for device: AudioOutputDevice) {
        guard !device.uid.isEmpty else { return }
        HostVolumeControl.setEnabled(enabled, uid: device.uid)
        updateVolumeStage()
    }

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: PlayerSource.appleMusic.appBundleID).isEmpty
    }

    private func isFollowed(_ source: PlayerSource) -> Bool {
        switch source {
        case .tidal: return tidalEnabled
        case .appleMusic: return appleMusicEnabled
        }
    }

    /// The player whose rate the panel shows: the one driving the output,
    /// else the last one that did, else whichever has a rate.
    private var shownSource: PlayerSource? {
        arbiter.shown ?? (tidalLockedRate != nil ? .tidal : stableLogSampleRate != nil ? .appleMusic : nil)
    }

    /// Hands the output to the followed player that started last, and applies
    /// its rate when it takes over.
    private func rearbitrate() {
        let outputting = Set(outputtingBundleIDs.compactMap(PlayerSource.init(bundleID:)).filter(isFollowed))
        if arbiter.update(outputting: outputting), let active = arbiter.active {
            switch active {
            case .tidal:
                if let tidalLockedRate { driveTidal(rate: tidalLockedRate) }
            case .appleMusic:
                if let stableLogSampleRate { applyLogAutoSwitch(sampleRate: stableLogSampleRate) }
            }
            scheduleSignalCheck()
        }
        updateCurrentSampleRateDisplay()
    }

    private func knownRate(of source: PlayerSource) -> Double? {
        switch source {
        case .tidal: return tidalLockedRate
        case .appleMusic: return stableLogSampleRate
        }
    }

    /// A player playing with no rate from its log would play resampled
    /// without a word; give it the grace period, then say so.
    private func scheduleSignalCheck() {
        signalCheck?.cancel()
        guard let active = arbiter.active, knownRate(of: active) == nil else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.arbiter.active == active, self.knownRate(of: active) == nil else { return }
            self.reportSignalLost(active, L10n.format("%@: no sample rate; not switching", active.name))
        }
        signalCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.signalGracePeriod, execute: check)
    }

    private func reportSignalLost(_ source: PlayerSource, _ message: String) {
        signalLostSource = source
        assign(\.signalWarning, message)
    }

    /// With `source`, only that player's warning: a rate from it proves its signal.
    private func clearSignalWarning(for source: PlayerSource? = nil) {
        guard source == nil || source == signalLostSource else { return }
        signalLostSource = nil
        assign(\.signalWarning, nil)
    }

    private func applyLogAutoSwitch(sampleRate trackSampleRate: Double, deviceUID: String? = nil) {
        guard autoSwitchEnabled, OutputRateLock.shared.heldRate == nil else { return }
        let sampleRate = playableSampleRate(trackSampleRate, deviceUID: deviceUID)

        guard let currentOutputRate = audioController.nominalSampleRate(deviceUID: deviceUID),
              abs(currentOutputRate - sampleRate) >= 1.0 else {
            return
        }

        if let lastAppliedSampleRate,
           let lastAppliedAt,
           abs(lastAppliedSampleRate - sampleRate) < 1.0,
           Date().timeIntervalSince(lastAppliedAt) < 2 {
            return
        }

        if audioController.setOutputSampleRate(sampleRate, deviceUID: deviceUID) != nil {
            lastAppliedSampleRate = sampleRate
            lastAppliedAt = Date()
            if deviceUID == nil {
                outputSampleRateDisplay = formatSampleRate(sampleRate)
            }
            statusMessage = L10n.format("Switched output to %@", formatSampleRate(sampleRate))
        } else {
            statusMessage = L10n.string("Failed to switch output sample rate")
        }
    }

    /// Buffers a vote off the main thread and flushes the batch at most every
    /// `logFlushInterval`. The votes themselves (rate + weight) and the
    /// dominance math downstream are unchanged — only the cadence at which
    /// `logRateWindow` grows is throttled.
    private func enqueueLogVote(rate: Double, weight: Int) {
        logVoteQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLogVotes.append(LogVote(rate: rate, weight: weight))

            guard !self.logFlushScheduled else { return }
            self.logFlushScheduled = true

            self.logVoteQueue.asyncAfter(deadline: .now() + Self.logFlushInterval) { [weak self] in
                guard let self else { return }
                let batch = self.pendingLogVotes
                self.pendingLogVotes.removeAll(keepingCapacity: true)
                self.logFlushScheduled = false

                guard !batch.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.ingestLogVotes(batch)
                }
            }
        }
    }

    private func ingestLogVotes(_ votes: [LogVote]) {
        let now = Date()

        var latestCandidate: Double?
        for vote in votes {
            guard let candidateRate = quantizeLogRate(vote.rate) else { continue }
            latestCandidate = candidateRate
            logRateWindow.append((rate: candidateRate, date: now, weight: vote.weight))
        }

        guard let latestCandidate else { return }
        latestLogCandidateRate = latestCandidate

        logRateWindow = logRateWindow.filter { now.timeIntervalSince($0.date) <= 6.0 }

        let totalWeight = logRateWindow.reduce(0) { $0 + $1.weight }
        let counts = Dictionary(grouping: logRateWindow, by: { $0.rate }).mapValues { $0.reduce(0) { $0 + $1.weight } }
        guard let dominant = counts.max(by: { $0.value < $1.value }) else {
            return
        }

        let dominantRate = dominant.key
        let dominantWeight = dominant.value
        let dominance = totalWeight > 0 ? Double(dominantWeight) / Double(totalWeight) : 0.0

        if stableLogSampleRate == nil {
            if dominantWeight >= 6 && dominance >= 0.7 {
                lockSampleRate(dominantRate, statusKey: "Log locked at %@")
            } else {
                sampleRateSourceDisplay = "Log (estimating)"
                trackSampleRateDisplay = "Estimating"
            }
        } else if dominantRate != stableLogSampleRate {
            let stableAge = now.timeIntervalSince(stableLogSampleRateAt ?? now)
            if dominantWeight >= 9 && dominance >= 0.85 && stableAge > 3 {
                lockSampleRate(dominantRate, statusKey: "Log switched at %@")
            }
        }

        if stableLogSampleRate == nil {
            logStatusMessage = L10n.format("Log estimating %@ (%ld/%ld)",
                                           formatSampleRate(dominantRate), dominantWeight, totalWeight)
        }
    }

    private func updateTrackTitle(_ title: String) {
        guard !title.isEmpty else { return }
        if let lastTrackTitle, lastTrackTitle != title, !musicRateIsExact {
            resetLogLock(reason: "Track changed")
            // Music logs the new stream's format as playback starts, and the
            // title poll can trail that by a second or so — keep a format that
            // just arrived, since it belongs to this track, and drop older ones.
            if let trackFormatAt, Date().timeIntervalSince(trackFormatAt) < 3 {
                // fresh: keep
            } else {
                trackFormat = nil
            }
        }
        lastTrackTitle = title
    }

    private func resetLogLock(reason: String) {
        musicRateIsExact = false
        stableLogSampleRate = nil
        stableLogSampleRateAt = nil
        logRateWindow.removeAll()
        latestLogCandidateRate = nil
        trackSampleRateDisplay = "Unknown"
        sampleRateSourceDisplay = "Unknown"
        logStatusMessage = L10n.string(reason)
    }

    private func updateCurrentSampleRateDisplay() {
        if shownSource == .tidal, let tidalLockedRate {
            assign(\.trackSampleRateDisplay, formatSampleRate(tidalLockedRate))
            assign(\.sampleRateSourceDisplay, "Log (locked)")
        } else if let stableLogSampleRate {
            assign(\.trackSampleRateDisplay, formatSampleRate(stableLogSampleRate))
            assign(\.sampleRateSourceDisplay, "Log (locked)")
        } else if latestLogCandidateRate != nil {
            assign(\.trackSampleRateDisplay, "Estimating")
            assign(\.sampleRateSourceDisplay, "Log (estimating)")
        } else {
            assign(\.trackSampleRateDisplay, "Unknown")
            assign(\.sampleRateSourceDisplay, "Unknown")
        }
    }

    /// Core Audio's decoder line states the rate exactly, as Tidal's does, so
    /// it locks without going through the vote window.
    private func lockExactMusicRate(_ rate: Double) {
        logRateWindow.removeAll()
        latestLogCandidateRate = nil
        musicRateIsExact = true
        lockSampleRate(rate, statusKey: "Log locked at %@")
    }

    /// A rate Music logged before Hertzwise started. It drives only if Music
    /// is playing now; otherwise it waits for Music's output to start.
    private func restoreMusicRate(_ rate: Double) {
        guard arbiter.active != .appleMusic else {
            lockExactMusicRate(rate)
            return
        }
        stableLogSampleRate = rate
        stableLogSampleRateAt = Date()
        musicRateIsExact = true
    }

    /// Music's rate, from the log-vote window.
    private func lockSampleRate(_ rate: Double, statusKey: String) {
        clearSignalWarning(for: .appleMusic)
        stableLogSampleRate = rate
        stableLogSampleRateAt = Date()
        guard arbiter.mayDrive(.appleMusic) else { return }
        trackSampleRateDisplay = formatSampleRate(rate)
        sampleRateSourceDisplay = "Log (locked)"
        logStatusMessage = L10n.format(statusKey, formatSampleRate(rate))
        applyLogAutoSwitch(sampleRate: rate)
    }

    private func quantizeLogRate(_ rate: Double) -> Double? {
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        let nearest = candidates.min(by: { abs($0 - rate) < abs($1 - rate) })
        guard let nearest else { return nil }

        let diffRatio = abs(nearest - rate) / nearest
        if diffRatio <= 0.008 {
            return nearest
        }

        return nil
    }
}
