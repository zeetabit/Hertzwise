import XCTest

final class SourceArbiterTests: XCTestCase {
    /// Restarting Hertzwise while Music plays must not let Tidal's restored
    /// paused track switch the rate before Core Audio says who is playing.
    func testNobodyDrivesBeforeTheFirstReport() {
        let arbiter = SourceArbiter()
        XCTAssertFalse(arbiter.mayDrive(.tidal))
        XCTAssertFalse(arbiter.mayDrive(.appleMusic))
    }

    func testNothingPlayingLetsEitherPrepare() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [])
        XCTAssertNil(arbiter.active)
        XCTAssertTrue(arbiter.mayDrive(.tidal))
        XCTAssertTrue(arbiter.mayDrive(.appleMusic))
    }

    /// Tidal paused, Apple Music starts: Music takes the output.
    func testMusicStartingWhileTidalIsIdleTakesOver() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [.tidal])
        arbiter.update(outputting: [])
        XCTAssertTrue(arbiter.update(outputting: [.appleMusic]))
        XCTAssertEqual(arbiter.active, .appleMusic)
        XCTAssertFalse(arbiter.mayDrive(.tidal))
    }

    /// Both playing: the one that started last drives.
    func testTheLatestStartWins() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [.appleMusic])
        XCTAssertTrue(arbiter.update(outputting: [.appleMusic, .tidal]))
        XCTAssertEqual(arbiter.active, .tidal)

        XCTAssertTrue(arbiter.update(outputting: [.appleMusic]))
        XCTAssertEqual(arbiter.active, .appleMusic)
    }

    /// Everything paused: the panel keeps showing the last driver, and both may prepare.
    func testPauseKeepsTheLastActiveForDisplay() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [.tidal])
        XCTAssertTrue(arbiter.update(outputting: []))
        XCTAssertNil(arbiter.active)
        XCTAssertEqual(arbiter.shown, .tidal)
        XCTAssertTrue(arbiter.mayDrive(.appleMusic))
    }

    /// Our own rate switch restarts Tidal's output; it stays in charge.
    func testOutputRestartKeepsTheSameDriver() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [.tidal])
        arbiter.update(outputting: [])
        XCTAssertTrue(arbiter.update(outputting: [.tidal]))
        XCTAssertEqual(arbiter.active, .tidal)
    }

    func testUnchangedOutputReportsNoChange() {
        var arbiter = SourceArbiter()
        arbiter.update(outputting: [.tidal])
        XCTAssertFalse(arbiter.update(outputting: [.tidal]))
    }

    func testBundleIDsMapToPlayers() {
        XCTAssertEqual(PlayerSource(bundleID: "com.tidal.desktop.player"), .tidal)
        XCTAssertEqual(PlayerSource(bundleID: "com.tidal.desktop"), .tidal)
        XCTAssertEqual(PlayerSource(bundleID: "com.apple.Music"), .appleMusic)
        XCTAssertNil(PlayerSource(bundleID: "com.tidal.desktop.helper"))
        XCTAssertNil(PlayerSource(bundleID: "com.google.Chrome"))
    }
}
