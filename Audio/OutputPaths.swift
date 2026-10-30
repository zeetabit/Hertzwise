import Foundation
import Observation
import OSLog

/// Owns one `ProcessTapEngine` per connected output device that needs one:
/// "Control volume" on, or the EQ on with that device's EQ switch on. The
/// EQ and the volume stage share the device's one path, so no device is
/// tapped twice. Main thread only.
@Observable
final class OutputPaths {
    static let shared = OutputPaths()

    /// What the EQ applies while it is on.
    struct EQ {
        var profile: PEQProfile
        var holdsProcessingRate: Bool
        let spectrum: SpectrumAnalyzer
    }

    /// Connected devices with their EQ switch on, whether or not the EQ is.
    private(set) var eqDeviceUIDs: Set<String> = []
    /// The device the EQ's spectrum, rate and headroom come from: the first
    /// connected one the EQ processes. Nil while the EQ is off or no device
    /// with its EQ switch on is connected.
    private(set) var eqPrimaryUID: String?

    /// Main queue, from the EQ's primary device.
    @ObservationIgnored var onEQSampleRateChange: ((Double) -> Void)?
    @ObservationIgnored var onEQHeadroomChange: ((Double) -> Void)?
    /// Main queue: an EQ'd device's path failed.
    @ObservationIgnored var onEQError: ((String) -> Void)?

    @ObservationIgnored private var eq: EQ?
    @ObservationIgnored private var engines: [String: ProcessTapEngine] = [:]
    /// Whether each engine was last configured with the EQ processing.
    @ObservationIgnored private var eqApplied: [String: Bool] = [:]
    @ObservationIgnored private var connectedUIDs: [String] = []
    @ObservationIgnored private let log = Logger(subsystem: "io.github.zeetabit.hertzwise", category: "OutputPaths")

    func updateDevices(connected uids: [String]) {
        connectedUIDs = uids.filter { !$0.isEmpty }
        reconcile()
    }

    func setDeviceEQ(_ enabled: Bool, uid: String) {
        DeviceEQ.setting.setEnabled(enabled, uid: uid)
        reconcile()
    }

    func volumeControlChanged() {
        reconcile()
    }

    /// Nil turns the EQ off: its devices go back to the players' own
    /// samples, and a path that only existed for the EQ is removed.
    func setEQ(_ eq: EQ?) {
        self.eq = eq
        reconcile(reconfigureEQ: true)
    }

    func apply(profile: PEQProfile) {
        guard eq != nil else { return }
        eq?.profile = profile
        for (uid, engine) in engines where eqApplied[uid] == true {
            engine.controlQueue.async { engine.apply(profile: profile) }
        }
    }

    func setHoldsProcessingRate(_ hold: Bool) {
        guard eq != nil else { return }
        eq?.holdsProcessingRate = hold
        for (uid, engine) in engines where eqApplied[uid] == true {
            engine.controlQueue.async { engine.setHoldsProcessingRate(hold) }
        }
    }

    /// Clipping events across every device the EQ processes; a change means
    /// one clipped.
    func eqClippingEventCount() -> UInt64 {
        engines.filter { eqApplied[$0.key] == true }.values.reduce(0) { $0 &+ $1.clippingEventCount() }
    }

    private func reconcile(reconfigureEQ: Bool = false) {
        eqDeviceUIDs = Set(connectedUIDs.filter { DeviceEQ.setting.isEnabled(uid: $0) })
        let eqUIDs = eq == nil ? [] : connectedUIDs.filter { eqDeviceUIDs.contains($0) }
        let primary = eqUIDs.first
        let primaryChanged = primary != eqPrimaryUID
        if primaryChanged { eqPrimaryUID = primary }

        for (uid, engine) in engines where !connectedUIDs.contains(uid)
            || !(HostVolumeControl.isEnabled(uid: uid) || eqUIDs.contains(uid)) {
            engines[uid] = nil
            eqApplied[uid] = nil
            engine.controlQueue.async {
                engine.setSampleSink(nil)
                engine.stop()
                engine.restoreOutputRate()
            }
        }

        for uid in connectedUIDs where HostVolumeControl.isEnabled(uid: uid) || eqUIDs.contains(uid) {
            let applyEQ = eqUIDs.contains(uid)
            if let engine = engines[uid] {
                if reconfigureEQ || primaryChanged || eqApplied[uid] != applyEQ {
                    configure(engine, uid: uid, applyEQ: applyEQ, isPrimary: uid == primary)
                }
            } else {
                let engine = makeEngine(uid: uid)
                engines[uid] = engine
                configure(engine, uid: uid, applyEQ: applyEQ, isPrimary: uid == primary)
                engine.controlQueue.async { [weak self] in
                    let started = engine.start()
                    let rate = engine.sampleRate
                    let error = engine.lastError
                    DispatchQueue.main.async {
                        guard let self, self.engines[uid] === engine else { return }
                        if started, self.eqPrimaryUID == uid {
                            self.onEQSampleRateChange?(rate)
                        } else if !started, self.eqApplied[uid] == true {
                            self.onEQError?(error ?? L10n.string("Couldn't start the EQ engine."))
                        }
                    }
                }
            }
        }
    }

    private func configure(_ engine: ProcessTapEngine, uid: String, applyEQ: Bool, isPrimary: Bool) {
        let wasApplied = eqApplied[uid] == true
        eqApplied[uid] = applyEQ
        let profile = eq?.profile
        let hold = applyEQ && eq?.holdsProcessingRate == true
        let spectrum = isPrimary ? eq?.spectrum : nil
        engine.controlQueue.async { [weak self] in
            engine.setSampleSink(spectrum)
            if applyEQ, let profile { engine.apply(profile: profile) }
            engine.setHoldsProcessingRate(hold)
            engine.setActive(applyEQ)
            if wasApplied, !applyEQ { engine.restoreOutputRate() }
            guard isPrimary, engine.isRunning else { return }
            let rate = engine.sampleRate
            DispatchQueue.main.async {
                guard let self, self.eqPrimaryUID == uid else { return }
                self.onEQSampleRateChange?(rate)
            }
        }
    }

    private func makeEngine(uid: String) -> ProcessTapEngine {
        let engine = ProcessTapEngine(deviceUID: uid)
        engine.onSampleRateChange = { [weak self] rate in
            DispatchQueue.main.async {
                guard let self, self.eqPrimaryUID == uid else { return }
                self.onEQSampleRateChange?(rate)
            }
        }
        engine.onHeadroomChange = { [weak self] attenuation in
            DispatchQueue.main.async {
                guard let self, self.eqPrimaryUID == uid else { return }
                self.onEQHeadroomChange?(attenuation)
            }
        }
        engine.onRuntimeError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.error("Path for \(uid, privacy: .public) failed: \(message, privacy: .public)")
                if self.eqApplied[uid] == true { self.onEQError?(message) }
            }
        }
        return engine
    }
}
