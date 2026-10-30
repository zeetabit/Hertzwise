import XCTest

final class NowPlayingAdapterTests: XCTestCase {
    /// As the adapter streamed it for Tidal on 2026-10-30.
    private let tidalTrack = #"{"type":"data","diff":false,"payload":{"artist":"ENIGMA","timestamp":"2026-10-30T09:23:38Z","contentItemIdentifier":"707D6EB2-4FEF-49F1-9E1E-1A349B0FDA3C","title":"Principles Of Lust: Sadeness\/Find Love\/Sadeness (Reprise) (Medley)","elapsedTime":0,"bundleIdentifier":"com.tidal.desktop","playing":true,"processIdentifier":42156,"duration":703.93299999999999,"playbackRate":1,"album":"MCMXC A.D."}}"#

    private func apply(_ lines: [String]) -> [String: Any] {
        lines.reduce([:]) { NowPlayingAdapter.merge(line: $1, into: $0) ?? $0 }
    }

    func testFullPayloadGivesTheTrack() throws {
        let track = try XCTUnwrap(NowPlayingAdapter.track(from: apply([tidalTrack])))
        XCTAssertEqual(track.bundleID, "com.tidal.desktop")
        XCTAssertEqual(track.title, "Principles Of Lust: Sadeness/Find Love/Sadeness (Reprise) (Medley)")
        XCTAssertEqual(track.artist, "ENIGMA")
        XCTAssertEqual(track.album, "MCMXC A.D.")
        XCTAssertTrue(track.isPlaying)
        XCTAssertEqual(track.elapsed, 0)
        XCTAssertEqual(try XCTUnwrap(track.duration), 703.933, accuracy: 0.001)
        XCTAssertEqual(track.timestamp, ISO8601DateFormatter().date(from: "2026-10-30T09:23:38Z"))
    }

    func testDiffMergesIntoTheSameTrack() throws {
        let paused = #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTime":42.5,"timestamp":"2026-10-30T09:24:20Z"}}"#
        let track = try XCTUnwrap(NowPlayingAdapter.track(from: apply([tidalTrack, paused])))
        XCTAssertFalse(track.isPlaying)
        XCTAssertEqual(track.elapsed, 42.5)
        XCTAssertEqual(track.artist, "ENIGMA")
    }

    func testNullInADiffRemovesTheKey() throws {
        let noAlbum = #"{"type":"data","diff":true,"payload":{"album":null}}"#
        let track = try XCTUnwrap(NowPlayingAdapter.track(from: apply([tidalTrack, noAlbum])))
        XCTAssertNil(track.album)
    }

    func testANewItemReplacesEverything() throws {
        let musicTrack = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Clair de lune","playing":true}}"#
        let track = try XCTUnwrap(NowPlayingAdapter.track(from: apply([tidalTrack, musicTrack])))
        XCTAssertEqual(track.bundleID, "com.apple.Music")
        XCTAssertNil(track.artist)
        XCTAssertNil(track.album)
    }

    func testArtworkIsDecoded() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let line = #"{"type":"data","diff":true,"payload":{"artworkData":"\#(png.base64EncodedString())","artworkMimeType":"image/png"}}"#
        let track = try XCTUnwrap(NowPlayingAdapter.track(from: apply([tidalTrack, line])))
        XCTAssertEqual(track.artwork, png)
    }

    func testHelperProcessesReportTheirParentApplication() throws {
        let line = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.example.player.helper","parentApplicationBundleIdentifier":"com.example.player","title":"T","playing":true}}"#
        XCTAssertEqual(NowPlayingAdapter.track(from: apply([line]))?.bundleID, "com.example.player")
    }

    func testNothingPlayingGivesNoTrack() {
        XCTAssertNil(NowPlayingAdapter.track(from: apply([#"{"type":"data","diff":false,"payload":{}}"#])))
        let untitled = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.tidal.desktop","title":"","playing":true}}"#
        XCTAssertNil(NowPlayingAdapter.track(from: apply([untitled])))
    }

    func testOtherLinesAreIgnored() {
        XCTAssertNil(NowPlayingAdapter.merge(line: "not json", into: [:]))
        XCTAssertNil(NowPlayingAdapter.merge(line: #"{"type":"error","message":"x"}"#, into: [:]))
    }
}
