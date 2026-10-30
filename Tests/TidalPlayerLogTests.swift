import Combine
import XCTest

private let prefix = "[2026-10-29 09:26:55.153] [tisoc] "

private func sinkOpen(_ rate: Int, _ bits: Int) -> String {
    prefix + "[debug] [pcm_sink_coreaudio.cpp:36] CoreaudioSink::open, rate: \(rate), type: int\(bits)"
}

private func status(_ state: String) -> String {
    prefix + #"[debug] [client.hpp:37] SIGNAL: {"signal": "media.state", "state": "\#(state)", "url": "https://example.invalid/0.flac?token=REDACTED"}"#
}

private func device(_ uid: String, _ mode: String) -> String {
    prefix + "[debug] [pcm_sink_coreaudio.cpp:322] selectDevice - id: \(uid), mode: \(mode)"
}

private let play = prefix + "[debug] [media_player_tidal.cpp:97] Play()"
private let sinkStart = prefix + "[debug] [pcm_sink_coreaudio.cpp:207] CoreaudioSink::start"
private let sinkClose = prefix + "[debug] [pcm_sink_coreaudio.cpp:170] CoreaudioSink::close"
private let loadCommand = prefix + #"[debug] [desktop_console.cpp:129] COMMAND: {"command":"media.load","encryptionKey":"REDACTED","streamFormat":"flac","url":"https://example.invalid/0.flac?token=REDACTED"}"#
private let pawS1 = "AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1"

private func format(_ rate: Double, _ bits: Int?) -> TidalStreamFormat {
    TidalStreamFormat(sampleRate: rate, bitDepth: bits)
}

final class TidalPlayerLogParserTests: XCTestCase {
    func testSinkOpenGivesRateAndBitDepth() {
        XCTAssertEqual(TidalPlayerLogParser.parse(sinkOpen(96000, 24)), .sinkOpened(format(96000, 24)))
        XCTAssertEqual(TidalPlayerLogParser.parse(sinkOpen(44100, 16)), .sinkOpened(format(44100, 16)))
        let float = prefix + "[debug] [pcm_sink_coreaudio.cpp:36] CoreaudioSink::open, rate: 192000, type: float32"
        XCTAssertEqual(TidalPlayerLogParser.parse(float), .sinkOpened(format(192000, nil)))
    }

    func testImplausibleRatesAreIgnored() {
        for rate in [0, 7999, 1_000_000] {
            XCTAssertNil(TidalPlayerLogParser.parse(sinkOpen(rate, 24)), "\(rate)")
        }
    }

    func testPlaybackSignals() {
        XCTAssertEqual(TidalPlayerLogParser.parse(play), .playRequested)
        XCTAssertEqual(TidalPlayerLogParser.parse(sinkStart), .sinkStarted)
        XCTAssertEqual(TidalPlayerLogParser.parse(sinkClose), .sinkClosed)
        XCTAssertEqual(TidalPlayerLogParser.parse(prefix + "[debug] [pcm_sink_coreaudio.cpp:240] CoreaudioSink::stop"),
                       .sinkStopped)
        for state in ["active", "paused", "stopped", "completed"] {
            XCTAssertEqual(TidalPlayerLogParser.parse(status(state)),
                           .statusChanged(TidalPlaybackStatus(rawValue: state)!), state)
        }
        XCTAssertNil(TidalPlayerLogParser.parse(status("buffering")))
    }

    func testDeviceSelectionGivesUIDAndMode() {
        XCTAssertEqual(TidalPlayerLogParser.parse(device(pawS1, "Shared")),
                       .deviceSelected(uid: pawS1, exclusive: false))
        XCTAssertEqual(TidalPlayerLogParser.parse(device("BuiltInSpeakerDevice", "Exclusive")),
                       .deviceSelected(uid: "BuiltInSpeakerDevice", exclusive: true))
    }

    func testSystemControlledDeviceMeansDefaultOutput() {
        XCTAssertEqual(TidalPlayerLogParser.parse(device("SystemControlled", "Shared")),
                       .deviceSelected(uid: nil, exclusive: false))
        let attempt = prefix + "[info] [desktop_console.cpp:114] attempting to select system controlled device"
        XCTAssertEqual(TidalPlayerLogParser.parse(attempt), .deviceSelected(uid: nil, exclusive: false))
    }

    func testOtherPlayerLinesAreIgnored() {
        let lines = [
            loadCommand,
            prefix + #"[debug] [desktop_console.cpp:129] COMMAND: {"command":"media.play"}"#,
            prefix + #"[debug] [desktop_console.cpp:129] COMMAND: {"command":"media.device.select","device":{"id":"AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1","supportedFormats":[{"sampleRate":96000}]},"options":{"mode":"exclusive"}}"#,
            prefix + #"[debug] [client.hpp:37] SIGNAL: {"devices": [{"id": "BuiltInSpeakerDevice", "supportedFormats": [{"sampleRate": 96000}]}], "signal": "media.devices"}"#,
            prefix + #"[debug] [client.hpp:37] SIGNAL: {"duration": 625.6, "signal": "media.duration", "url": "https://example.invalid/0.flac?token=REDACTED"}"#,
            prefix + "[info] [pcm_sink_coreaudio.cpp:284] device: PAW-S1, AppleUSBAudioEngine:Lotoo:PAW-S1:v1.00:1, 0",
            prefix + "[debug] [pcm_sink_coreaudio.cpp:357] getClosestMatch - exact match found: [AudioStreamBasicDescription mSampleRate: 44100 mBitsPerChannel: 16]",
            prefix + "[debug] [pcm_sink_coreaudio.cpp:229] AudioOutputUnitStart",
            prefix + "[debug] [factory.cpp:70] AudioDecoderFactory::create - got stream format flac",
            prefix + "[debug] [pcm_sink_coreaudio.cpp:215] ExclusiveModeHolder locked",
            "",
        ]
        for line in lines {
            XCTAssertNil(TidalPlayerLogParser.parse(line), line)
        }
    }
}

final class TidalPlaybackStateTests: XCTestCase {
    /// Feeds lines through the parser and state; returns each format started.
    private func run(_ lines: [String], from initial: TidalPlaybackState = TidalPlaybackState())
        -> (state: TidalPlaybackState, started: [TidalStreamFormat]) {
        var state = initial
        var started: [TidalStreamFormat] = []
        for event in lines.compactMap(TidalPlayerLogParser.parse) {
            if let format = state.apply(event) {
                started.append(format)
            }
        }
        return (state, started)
    }

    /// From the log: load → paused → (download) → open → Play() → active → start.
    func testUserStartedTrackStartsOnPlayNotOnOpen() {
        let opened = run([loadCommand, status("paused"), sinkClose, sinkOpen(96000, 24)])
        XCTAssertEqual(opened.started, [])
        XCTAssertEqual(opened.state.format, format(96000, 24))

        let playing = run([play, status("active"), sinkStart], from: opened.state)
        XCTAssertEqual(playing.started, [format(96000, 24)])
        XCTAssertTrue(playing.state.isPlaying)
    }

    /// Tidal restores the last track paused at launch, with the sink open.
    func testRestoredPausedTrackDoesNotStart() {
        let result = run([status("paused"), sinkClose, sinkOpen(44100, 16)])
        XCTAssertEqual(result.started, [])
        XCTAssertFalse(result.state.isPlaying)
    }

    /// Any one sign of play is enough; Tidal sometimes omits `state: active`.
    func testSinkStartAloneStartsTheFormat() {
        let result = run([status("paused"), sinkOpen(44100, 16), sinkStart])
        XCTAssertEqual(result.started, [format(44100, 16)])
    }

    /// Gapless to a new rate: completed → active → close → open, while playing.
    func testGaplessRateChangeStartsTheNewFormat() {
        let first = run([sinkOpen(44100, 16), play])
        let next = run([status("completed"), status("active"), sinkClose, sinkOpen(96000, 24)], from: first.state)
        XCTAssertEqual(next.started, [format(96000, 24)])
    }

    /// Gapless at the same rate: no reopen, nothing to switch.
    func testGaplessSameRateStartsNothing() {
        let first = run([sinkOpen(96000, 24), play])
        let next = run([status("completed"), status("active")], from: first.state)
        XCTAssertEqual(next.started, [])
        XCTAssertEqual(next.state.format, format(96000, 24))
    }

    /// Resume after pause restarts the format, in case another app changed the rate meanwhile.
    func testResumeAfterPauseStartsTheFormatAgain() {
        let result = run([sinkOpen(48000, 24), play, status("paused"), play])
        XCTAssertEqual(result.started, [format(48000, 24), format(48000, 24)])
    }

    func testDeviceSelectionIsTracked() {
        let result = run([device(pawS1, "Exclusive"), device(pawS1, "Shared")])
        XCTAssertEqual(result.state.deviceUID, pawS1)
    }

    // MARK: Unified log

    private func runSystem(_ messages: [String], from initial: TidalPlaybackState = TidalPlaybackState())
        -> (state: TidalPlaybackState, started: [TidalStreamFormat]) {
        var state = initial
        var started: [TidalStreamFormat] = []
        for event in messages.compactMap(TidalPlayerLogParser.parseSystemLog) {
            if let format = state.apply(event) {
                started.append(format)
            }
        }
        return (state, started)
    }

    /// The first track after launch, as logged at 09:01:07–08: setup passes
    /// through the default device, and output starts 0.8 s after the first
    /// converter. Nothing has played yet, so the switch waits for `Started`.
    func testFirstTrackStartsWhenOutputStarts() {
        let setup = runSystem([playStopped(pawS1), converter(96000, 24, to: 96000), playStopped(speakers),
                               converter(96000, 24, to: 44100), playStopped(pawS1), converter(96000, 24, to: 96000)])
        XCTAssertEqual(setup.started, [])
        XCTAssertFalse(setup.state.isPlaying)

        let playing = runSystem([playStarted(pawS1), converter(96000, 24, to: 96000), playStarted(pawS1)], from: setup.state)
        XCTAssertEqual(playing.started, [format(96000, 24)])
        XCTAssertEqual(playing.state.deviceUID, pawS1)
    }

    /// A skip once Tidal has played switches at setup, before output starts.
    func testSkipAfterPlayingSwitchesAtSetup() {
        let first = runSystem([converter(44100, 16, to: 44100), playStarted(pawS1)])
        let skip = runSystem([playStopped(pawS1), converter(96000, 24, to: 44100), playStopped(speakers),
                              converter(96000, 24, to: 44100)], from: first.state)
        XCTAssertEqual(skip.started, [format(96000, 24)])

        let resumed = runSystem([playStarted(pawS1)], from: skip.state)
        XCTAssertEqual(resumed.started, [format(96000, 24)])
    }

    /// Setup briefly stops the default device; that is not the device Tidal plays to.
    func testStopOnAnotherDeviceDoesNotStopPlayback() {
        let playing = runSystem([converter(44100, 16, to: 44100), playStarted(pawS1), playStopped(speakers)])
        XCTAssertTrue(playing.state.isPlaying)
    }

    /// Changing the device rate restarts output with no stop: nothing to repeat.
    func testOutputRestartFromOurOwnSwitchStartsNothing() {
        let playing = runSystem([converter(96000, 24, to: 44100), playStarted(pawS1)])
        let restarted = runSystem([playStarted(pawS1), playStarted(pawS1)], from: playing.state)
        XCTAssertEqual(restarted.started, [])
    }

    /// Output moving to another device while playing switches that device.
    func testOutputMovingToAnotherDeviceStartsTheFormatThere() {
        let playing = runSystem([converter(96000, 24, to: 96000), playStarted(pawS1)])
        let moved = runSystem([playStarted(speakers)], from: playing.state)
        XCTAssertEqual(moved.started, [format(96000, 24)])
        XCTAssertEqual(moved.state.deviceUID, speakers)
    }
}

private let speakers = "BuiltInSpeakerDevice"

private func converter(_ rate: Int, _ bits: Int, to deviceRate: Int) -> String {
    let source = bits == 16 ? "Int16, interleaved"
                            : "lpcm (0x0000000C) \(bits)-bit little-endian signed integer"
    return "       AudioConverter.cpp:1077  Created a new in process converter -> 0x7850baee0, from  2 ch,  \(rate) Hz, \(source) to  2 ch,  \(deviceRate) Hz, Float32, interleaved"
}

private func playStarted(_ uid: String) -> String {
    "SessionCore_macOS_Legacy.mm:131   --> setPlayState Started  Output {\(uid), 0x36}"
}

private func playStopped(_ uid: String) -> String {
    "SessionCore_macOS_Legacy.mm:131   --> setPlayState Stopped  Output {\(uid), 0x34}"
}

final class TidalSystemLogParserTests: XCTestCase {
    func testConverterGivesTheSourceFormat() {
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLog(converter(96000, 24, to: 44100)),
                       .sinkOpened(format(96000, 24)))
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLog(converter(44100, 16, to: 96000)),
                       .sinkOpened(format(44100, 16)))
        let float = "AudioConverter.cpp:1077  Created a new in process converter -> 0x1, from  2 ch,  192000 Hz, Float32, interleaved to  2 ch,  192000 Hz, Float32, interleaved"
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLog(float), .sinkOpened(format(192000, nil)))
    }

    func testPlayStateGivesDevice() {
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLog(playStarted(pawS1)), .outputStarted(deviceUID: pawS1))
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLog(playStopped(speakers)), .outputStopped(deviceUID: speakers))
    }

    func testOtherCoreAudioMessagesAreIgnored() {
        let messages = [
            "SessionCore_macOS_Legacy.mm:162   <-- setPlayState IOState: [0, 0]. BT device UIDS: {(",
            "SessionCore_macOS_Legacy.mm:167   <-- setPlayState Server update was required.",
            "AudioConverter -> 0x1: The in-process SetProperty call returned 1886547824 for property 1886547309 with size 4.",
            "AUHAL.cpp:629   SelectDevice: -> (0x1)",
        ]
        for message in messages {
            XCTAssertNil(TidalPlayerLogParser.parseSystemLog(message), message)
        }
    }

    func testNdjsonLineIsDecoded() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "eventMessage": playStarted(pawS1),
            "processImagePath": "/Applications/TIDAL.app/Contents/Resources/app.asar.unpacked/resources/osx/arm64/TIDALPlayer.app/Contents/MacOS/TIDALPlayer",
        ])
        XCTAssertEqual(TidalPlayerLogParser.parseSystemLogLine(String(decoding: json, as: UTF8.self)),
                       .outputStarted(deviceUID: pawS1))
        XCTAssertNil(TidalPlayerLogParser.parseSystemLogLine("not json"))
    }
}

final class TidalPlayerLogControllerTests: XCTestCase {
    private var directory: URL!
    private var logURL: URL { directory.appendingPathComponent("player.log") }
    private var controller: TidalPlayerLogController!
    private var subscriptions: Set<AnyCancellable> = []
    private let lock = NSLock()
    private var events: [TidalPlayerEvent] = []
    private var started: [TidalPlaybackState] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TidalPlayerLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.stop()
        subscriptions.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func testCatchUpRebuildsStateWithoutReplayingEvents() throws {
        try write([device("BuiltInSpeakerDevice", "Exclusive"), device(pawS1, "Shared"),
                   status("paused"), sinkOpen(96000, 24)])
        startController()

        var state: TidalPlaybackState?
        controller.state.sink { state = $0 }.store(in: &subscriptions)
        XCTAssertEqual(state?.deviceUID, pawS1)
        XCTAssertEqual(state?.format, format(96000, 24))
        XCTAssertEqual(state?.isPlaying, false)
        assertEventually(events: [], started: [])
    }

    func testCatchUpStartsATrackThatIsStillPlaying() throws {
        try write([device(pawS1, "Shared"), sinkOpen(96000, 24), play])
        startController(playerRunning: true)

        assertEventually(events: [], started: [format(96000, 24)])
        lock.lock(); let deviceUID = started.first?.deviceUID; lock.unlock()
        XCTAssertEqual(deviceUID, pawS1)
    }

    func testCatchUpIgnoresPlaybackOfAPlayerThatQuit() throws {
        try write([sinkOpen(96000, 24), play])
        startController(playerRunning: false)

        assertEventually(events: [], started: [])
    }

    func testEverySubscriberReceivesEvents() throws {
        try write([])
        startController()
        var second: [TidalPlayerEvent] = []
        let secondLock = NSLock()
        controller.events.sink { event in
            secondLock.lock(); second.append(event); secondLock.unlock()
        }.store(in: &subscriptions)

        try append([sinkOpen(44100, 16), "unrelated line", play])

        assertEventually(events: [.sinkOpened(format(44100, 16)), .playRequested],
                         started: [format(44100, 16)])
        secondLock.lock(); let secondEvents = second; secondLock.unlock()
        XCTAssertEqual(secondEvents, [.sinkOpened(format(44100, 16)), .playRequested])
    }

    func testPartialLineWaitsForItsNewline() throws {
        try write([])
        startController()

        let line = sinkOpen(88200, 24)
        try appendRaw(String(line.prefix(30)))
        try appendRaw(String(line.dropFirst(30)) + "\n")

        assertEventually(events: [.sinkOpened(format(88200, 24))], started: [])
    }

    func testRotationFollowsTheNewFile() throws {
        try write([])
        startController()

        try append([sinkOpen(48000, 24)])
        assertEventually(events: [.sinkOpened(format(48000, 24))], started: [])

        try FileManager.default.moveItem(at: logURL, to: directory.appendingPathComponent("player.1.log"))
        try write([sinkOpen(192000, 24)])

        assertEventually(events: [.sinkOpened(format(48000, 24)), .sinkOpened(format(192000, 24))],
                         started: [])
    }

    func testMissingFileIsPickedUpWhenItAppears() throws {
        startController()

        try write([sinkOpen(96000, 24)])

        assertEventually(events: [.sinkOpened(format(96000, 24))], started: [])
    }

    func testTruncationStartsOverFromTheTop() throws {
        try write([])
        startController()

        try append([sinkOpen(44100, 16), sinkOpen(48000, 16)])
        assertEventually(events: [.sinkOpened(format(44100, 16)), .sinkOpened(format(48000, 16))],
                         started: [])

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((sinkOpen(96000, 24) + "\n").utf8))
        try handle.close()

        assertEventually(events: [.sinkOpened(format(44100, 16)), .sinkOpened(format(48000, 16)),
                                  .sinkOpened(format(96000, 24))],
                         started: [])
    }

    /// `player.log` arrives seconds late; once the unified log is live, a
    /// stale "paused" from the file must not stop playback.
    func testFileIsIgnoredOnceTheSystemLogIsLive() throws {
        try write([])
        startController()

        controller.ingestSystemLogLine(ndjson(converter(96000, 24, to: 44100)))
        controller.ingestSystemLogLine(ndjson(playStarted(pawS1)))
        assertEventually(events: [.sinkOpened(format(96000, 24)), .outputStarted(deviceUID: pawS1)],
                         started: [format(96000, 24)])

        try append([sinkOpen(96000, 24), status("paused")])
        Thread.sleep(forTimeInterval: 0.2)
        var state: TidalPlaybackState?
        controller.state.sink { state = $0 }.store(in: &subscriptions)
        XCTAssertEqual(state?.isPlaying, true)
        assertEventually(events: [.sinkOpened(format(96000, 24)), .outputStarted(deviceUID: pawS1)],
                         started: [format(96000, 24)])
    }

    // MARK: - Helpers

    private func ndjson(_ message: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["eventMessage": message])
        return String(decoding: data, as: UTF8.self)
    }

    private func startController(playerRunning: Bool = true) {
        controller = TidalPlayerLogController(url: logURL, reopenInterval: 0.05,
                                              isPlayerRunning: { playerRunning }, systemLog: nil)
        controller.events.sink { [weak self] event in
            guard let self else { return }
            self.lock.lock(); self.events.append(event); self.lock.unlock()
        }.store(in: &subscriptions)
        controller.formatStarted.sink { [weak self] state in
            guard let self else { return }
            self.lock.lock(); self.started.append(state); self.lock.unlock()
        }.store(in: &subscriptions)
        controller.start()
        // Let the initial open (and its catch-up read) finish before writing.
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func assertEventually(events expectedEvents: [TidalPlayerEvent],
                                  started expectedStarted: [TidalStreamFormat],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        var seenEvents: [TidalPlayerEvent] = []
        var seenStarted: [TidalStreamFormat] = []
        while Date() < deadline {
            lock.lock()
            seenEvents = events
            seenStarted = started.compactMap(\.format)
            lock.unlock()
            if seenEvents == expectedEvents && seenStarted == expectedStarted { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(seenEvents, expectedEvents, file: file, line: line)
        XCTAssertEqual(seenStarted, expectedStarted, file: file, line: line)
    }

    private func write(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: logURL)
    }

    private func append(_ lines: [String]) throws {
        try appendRaw(lines.map { $0 + "\n" }.joined())
    }

    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}
