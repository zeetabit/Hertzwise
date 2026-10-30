import XCTest

final class LogStreamControllerTests: XCTestCase {
    func testRepeatedThreadIDsDoNotProduceSampleRateEvidence() {
        let line = #"{"eventMessage":"audio buffer scheduled","threadID":48000}"#
        XCTAssertEqual(sampleRates(from: Array(repeating: line, count: 6)), [])
    }

    func testUnrelatedNumericMetadataIsIgnoredAtEveryDepth() {
        let lines = [
            #"{"eventMessage":"audio buffer scheduled","processID":44100}"#,
            #"{"eventMessage":"audio buffer scheduled","count":96}"#,
            #"{"eventMessage":"audio buffer scheduled","duration":192}"#,
            #"{"eventMessage":"audio buffer scheduled","threadID":"48000"}"#,
            #"{"metadata":{"threadID":48000}}"#,
            #"{"metadata":[{"processID":"44100"},48000,"96",[192000]]}"#,
        ]
        for line in lines {
            XCTAssertEqual(sampleRates(from: [line]), [], line)
        }
    }

    func testMetadataTextIsNotReparsedAsAnAudioMessage() {
        let lines = [
            #"{"eventMessage":"audio route unchanged","metadata":"48 kHz"}"#,
            #"{"metadata":{"description":"sample rate: 96000"}}"#,
            #"{"metadata":["44100 Hz"]}"#,
        ]
        for line in lines {
            XCTAssertEqual(sampleRates(from: [line]), [], line)
        }
    }

    func testSampleRateCountersAreNotSampleRateFields() {
        for key in ["sampleRateCount", "sampleRateChangeCount"] {
            XCTAssertEqual(sampleRates(from: ["{\"\(key)\":48000}"]), [])
        }
    }

    func testExplicitSampleRateFieldsSurviveNestedContainersAndMetadata() {
        let cases: [(String, Double)] = [
            (#"{"sampleRate":48000}"#, 48000),
            (#"{"SampleRate":"44.1"}"#, 44100),
            (#"{"format":{"mSampleRate":96000},"threadID":48000}"#, 96000),
            (#"{"formats":[48000,"44.1",{"sampleRate":"192000"}]}"#, 192000),
            (#"{"metadata":{"threadID":48000},"format":{"sampleRate":88200}}"#, 88200),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(sampleRates(from: [line]), [expected], line)
        }
    }

    func testRecognizedJSONMessagesStillProduceSampleRates() {
        let cases: [(String, Double)] = [
            (#"{"eventMessage":"sample rate: 44100","threadID":48000}"#, 44100),
            (#"{"message":"audio format: 96 kHz","processID":44100}"#, 96000),
            (#"{"formattedMessage":"audio format: 192000 Hz"}"#, 192000),
            (#"{"eventMessage":"sample rate: 48000","sampleRate":96000}"#, 48000),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(sampleRates(from: [line]), [expected], line)
        }
    }

    /// As Music logged it for a 48 kHz AAC radio stream on 2026-10-30.
    func testCoreAudioConverterLineGivesTheSourceRate() {
        let line = #"{"eventMessage":"AudioConverter.cpp:1077 Created a new in process converter -> 0x7834e5f80, from 2 ch, 48000 Hz, aach (0x00000000) 0 bits/channel, 0 bytes/packet, 2048 frames/packet, 0 bytes/frame, 0 channels/frame to 2 ch, 48000 Hz, Float32, deinterleaved"}"#
        XCTAssertEqual(sampleRates(from: [line]), [48000])
    }

    /// Its input is already decoded, so it states the device's rate, not the source's.
    func testDeviceSideConverterLineIsIgnored() {
        let line = #"{"eventMessage":"AudioConverter.cpp:1077 Created a new in process converter -> 0x7820a9980, from 2 ch, 44100 Hz, Float32, deinterleaved to 2 ch, 44100 Hz, Float32, interleaved"}"#
        XCTAssertEqual(sampleRates(from: [line]), [])
    }

    /// `log show` lines also carry the format string, whose "from %s%s to"
    /// must not count as a decoded input.
    func testCatchUpPicksTheLatestDecoderLine() {
        func line(_ message: String) -> String {
            #"{"formatString":"%25s:%-5d Created a new %s converter -> %p, from %s%s to %s%s","eventMessage":"\#(message)"}"#
        }
        let decoder = line("AudioConverter.cpp:1077  Created a new in process converter -> 0x1, from  2 ch,  48000 Hz, aach (0x00000000) 0 bits/channel to  2 ch,  48000 Hz, Float32, deinterleaved")
        let device = line("AudioConverter.cpp:1077  Created a new in process converter -> 0x2, from  2 ch,  44100 Hz, Float32, deinterleaved to  2 ch,  44100 Hz, Float32, interleaved")
        let summary = #"{"count":2,"finished":1}"#
        XCTAssertEqual(LogStreamController.latestSourceRateLine(in: [decoder, device, summary]), decoder)
        XCTAssertNil(LogStreamController.latestSourceRateLine(in: [device, summary]))
    }

    func testPlainTextAudioMessagesRemainSupported() {
        XCTAssertEqual(sampleRates(from: [
            "sample rate = 48000",
            "audio format: 44.1 kHz",
            "audio format: 96000 Hz",
            "audio route unchanged",
        ]), [48000, 44100, 96000])
    }

    func testActiveFormatLineYieldsCodecBitDepthAndTier() {
        // Shape of the line as captured from Music.app's log on macOS 27.
        let line = "|2026-10-15 02:38:23.882-0400 mus:nePSnYoK7  4 ┃┃┃┃  ╲╭ activeFormat: tier: Lossless; "
            + "groupID: audio-alac-stereo-48000-24; bitDepth: 24-bit; sampleRate: 48kh"
        let format = TrackFormat(logMessage: line)
        XCTAssertEqual(format?.codec, "ALAC")
        XCTAssertEqual(format?.bitDepth, 24)
        XCTAssertEqual(format?.tier, "Lossless")

        // The same line still votes for its sample rate.
        XCTAssertEqual(sampleRates(from: [line]), [48000])
    }

    func testActiveFormatTierSpellingsAreNormalised() {
        XCTAssertEqual(TrackFormat(logMessage: "activeFormat: tier: HiResLossless; bitDepth: 24-bit")?.tier,
                       "Hi-Res Lossless")
        XCTAssertEqual(TrackFormat(logMessage: "activeFormat: tier: Hi-Res Lossless")?.tier,
                       "Hi-Res Lossless")
        // A tier equal to the codec is not repeated.
        let atmos = TrackFormat(logMessage: "activeFormat: tier: Atmos; groupID: audio-atmos-2048")
        XCTAssertEqual(atmos?.codec, "Dolby Atmos")
        XCTAssertNil(atmos?.tier)
    }

    func testFormatLessLinesAreIgnored() {
        XCTAssertNil(TrackFormat(logMessage: "sample rate: 44100"))
        XCTAssertNil(TrackFormat(logMessage: "activeFormat: nothing useful here"))
        // An unknown group ID is not guessed at.
        XCTAssertNil(TrackFormat(logMessage: "activeFormat: groupID: audio-mystery-48000")?.codec)
    }

    func testActiveFormatIsReportedThroughTheCallback() {
        let controller = LogStreamController()
        var formats: [TrackFormat] = []
        controller.onTrackFormat = { formats.append($0) }
        controller.handleLogLine(#"{"eventMessage":"activeFormat: tier: Lossless; groupID: audio-alac-stereo-44100-16; bitDepth: 16-bit; sampleRate: 44.1kh"}"#)
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats.first?.bitDepth, 16)
    }

    private func sampleRates(from lines: [String]) -> [Double] {
        let controller = LogStreamController()
        var rates: [Double] = []
        controller.onSampleRate = { rate, _ in rates.append(rate) }
        for line in lines {
            controller.handleLogLine(line)
        }
        return rates
    }
}

final class ChildLifelineTests: XCTestCase {
    /// Starts a command that prints its pid and then becomes a 30 s sleep.
    private func launch() throws -> (process: Process, lifeline: FileHandle, childPID: pid_t) {
        let process = Process()
        let lifeline = ChildLifeline.attach(to: process, command: ["/bin/sh", "-c", "echo $$; exec /bin/sleep 30"])
        let output = Pipe()
        process.standardOutput = output
        try process.run()

        var text = ""
        let deadline = Date().addingTimeInterval(3)
        while !text.contains("\n"), Date() < deadline {
            text += String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        }
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isAlive(pid))
        return (process, lifeline, pid)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitUntilGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while isAlive(pid), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(isAlive(pid), "child \(pid) outlived its lifeline", file: file, line: line)
    }

    /// What the kernel does when the app dies, however it dies.
    func testClosingTheLifelineStopsTheCommand() throws {
        let launched = try launch()
        try launched.lifeline.close()
        waitUntilGone(launched.childPID)
        launched.process.waitUntilExit()
    }

    /// A deliberate stop: `Process.terminate()` sends SIGTERM to the shell.
    func testTerminatingTheShellStopsTheCommand() throws {
        let launched = try launch()
        launched.process.terminate()
        waitUntilGone(launched.childPID)
        launched.process.waitUntilExit()
        try launched.lifeline.close()
    }

    /// A command that ends on its own ends the shell with its status, so the
    /// restart logic still sees the exit.
    func testCommandExitEndsTheShellWithItsStatus() throws {
        let process = Process()
        let lifeline = ChildLifeline.attach(to: process, command: ["/bin/sh", "-c", "exit 7"])
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 7)
        try lifeline.close()
    }
}
