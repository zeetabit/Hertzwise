import Foundation
import AppKit
import CoreAudio
import Accelerate
import OSLog
import Synchronization

/// Inserts an EQ into Apple Music's audio without a driver or admin rights, using
/// the macOS 14.4+ Core Audio process-tap API.
///
/// Pipeline: a *muted* process tap on Music.app silences Music's normal output
/// and hands us its samples; a private aggregate device bundles that tap (as
/// input) with the real output device (as output); our IOProc copies tap →
/// (optional biquad EQ) → real device. Because SyncHz renders from a separate
/// process, there is no feedback loop.
///
/// Coefficient changes are crossfaded and bypass changes are ramped by the
/// processor. Output-device and sample-rate changes trigger a full path rebuild.
// Control methods are serialized on `controlQueue`; render runs on the audio
// thread. That manual discipline is what `@unchecked Sendable` asserts here.
final class ProcessTapEngine: @unchecked Sendable {
    /// What the tap captures.
    enum Source {
        /// Apple Music only, for the headphone EQ.
        case appleMusic
        /// Everything playing to the output device except Hertzwise itself,
        /// whose own re-rendered output would otherwise loop back. For the
        /// volume stage: copied through untouched, no EQ.
        case allButHertzwise
    }

    let source: Source
    /// The device this engine renders to whatever the system output is; nil
    /// follows the system output. The volume stage binds to its DAC: an app
    /// such as Tidal keeps playing there after the system output moves.
    private let boundDeviceUID: String?
    private var gainListenerBlock: AudioObjectPropertyListenerBlock?
    private var gainListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private let log: Logger
    private let musicBundleID = "com.apple.Music"
    private let aggregateUID: String

    private let processor = BiquadProcessor()

    /// With `holdsProcessingRate` on, the output device is held at this rate
    /// while the EQ runs and Core Audio resamples Apple Music into it, instead
    /// of the device (and the whole tap/aggregate path) following every track:
    /// one coefficient set, no path rebuilds between tracks — kinder to DACs
    /// that switch slowly or click. 48 kHz is PEQdB's design rate, so its
    /// presets play exactly as fitted.
    static let processingRate = 48_000.0
    /// Control queue. Off (the default): the device keeps following each
    /// track, so Music isn't resampled, and the path is rebuilt — with
    /// coefficients re-matched — at every rate change.
    private(set) var holdsProcessingRate = false
    /// The device's rate before the EQ took it over, restored when the user
    /// turns the EQ off.
    private var rateToRestore: (device: AudioObjectID, rate: Double)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// The volume stage's previous path, still playing and muting while its
    /// replacement is built after a rate change. Control queue only.
    private var retiringPath: (tap: AudioObjectID, aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID?)?
    /// Each path's aggregate needs its own UID while two exist at once.
    private var pathGeneration = 0
    /// True while `start()` builds a replacement: its failure path calls
    /// `stop()`, which must then leave the old path for the fallback.
    private var isReplacingPath = false
    private(set) var sampleRate: Double = 48000
    private var currentProfile: PEQProfile = .flat
    private var inputFormat = AudioStreamBasicDescription()
    /// Index of the tap's first buffer in the IOProc's input list. The
    /// aggregate's inputs are its sub-device's own input streams (a DAC or
    /// interface with a mic/line input has some) followed by the tap, so the
    /// tap is not necessarily buffer 0. Set before the IOProc starts.
    private var inputFirstBuffer = 0
    private var outputFormat = AudioStreamBasicDescription()
    private var desiredActive = false
    // Raw buffers the IOProc reuses, allocated once: the render path never
    // allocates or goes through Array bounds/exclusivity checks.
    private static let spectrumCapacity = 8_192
    private let spectrumScratch: UnsafeMutablePointer<Float> = {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: ProcessTapEngine.spectrumCapacity)
        pointer.initialize(repeating: 0, count: ProcessTapEngine.spectrumCapacity)
        return pointer
    }()
    private let inputScratch: UnsafeMutablePointer<Float> = {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: BiquadProcessor.blockFrames)
        pointer.initialize(repeating: 0, count: BiquadProcessor.blockFrames)
        return pointer
    }()

    /// Unretained because EQModel owns the analyzer for the whole engine lifetime.
    /// Updated only while audio IO is stopped, avoiding ARC on the render thread.
    private var sampleSinkPointer: UnsafeMutableRawPointer?
    /// Fired on the main queue when the output device's sample rate changes.
    var onSampleRateChange: ((Double) -> Void)?
    var onHeadroomChange: ((Double) -> Void)?
    var onRuntimeError: ((String) -> Void)?
    /// Main queue: `true` once the tap has delivered only silence for ~6 s
    /// while rendering, `false` when audio arrives again.
    var onInputSilence: ((Bool) -> Void)?

    // Render health. The IOProc raises these; a 2 s timer on the control
    // queue reads and resets them and logs them at notice level, so whether
    // audio arrives from the tap and leaves for the device is never a guess.
    private let renderCycles = Atomic<UInt64>(0)
    /// Output frames the tap had no samples for, filled with silence: each
    /// is an audible dropout.
    private let missingFrames = Atomic<UInt64>(0)
    /// Linear gain for `.allButHertzwise`, at most 1, set from any thread.
    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// The gain the last render ended at. Render thread only.
    private var renderGain: Float = 1
    private let inputPeakBits = Atomic<UInt32>(0)
    private let outputPeakBits = Atomic<UInt32>(0)
    private var healthTimer: DispatchSourceTimer?
    private var silentWindows = 0
    private var reportedSilence = false

    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var rebuildWork: DispatchWorkItem?

    /// Serializes all engine control (start/stop/apply) and the rate-change
    /// listener off the main thread, so toggling the EQ never blocks the UI on
    /// Core Audio device creation.
    let controlQueue = DispatchQueue(label: "io.github.zeetabit.hertzwise.eq.control")

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(source: Source = .appleMusic, deviceUID: String? = nil) {
        self.source = source
        boundDeviceUID = deviceUID
        switch source {
        case .appleMusic:
            log = Logger(subsystem: "io.github.zeetabit.hertzwise", category: "EQEngine")
            aggregateUID = "io.github.zeetabit.hertzwise.eq-aggregate"
        case .allButHertzwise:
            log = Logger(subsystem: "io.github.zeetabit.hertzwise", category: "VolumeEngine")
            aggregateUID = "io.github.zeetabit.hertzwise.volume-aggregate"
        }
    }

    deinit {
        // The IOProc reads the scratch buffers, so it must be gone first.
        stop()
        spectrumScratch.deallocate()
        inputScratch.deallocate()
    }

    // MARK: - Lifecycle

    /// Start tapping Music and rendering to the current default output device.
    /// Returns false (and sets `lastError`) on the first step that fails.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        let target: AudioObjectID?
        switch source {
        case .appleMusic: target = processObject(bundleID: musicBundleID)
        case .allButHertzwise: target = processObject(pid: ProcessInfo.processInfo.processIdentifier)
        }
        guard let processObject = target else {
            return fail(source == .appleMusic
                ? "Apple Music isn't running (no audio process to tap)."
                : "Hertzwise has no Core Audio process object to exclude from the tap.")
        }
        let resolvedDevice = boundDeviceUID.map { deviceID(uid: $0) } ?? defaultOutputDeviceID()
        guard let outputDevice = resolvedDevice else {
            return fail("No output device.")
        }
        guard let outputUID = deviceUID(outputDevice) else {
            return fail("Couldn't read the output device UID.")
        }
        if holdsProcessingRate { holdProcessingRate(on: outputDevice) }
        sampleRate = nominalSampleRate(outputDevice) ?? Self.processingRate

        // The tap's format follows Music's own output, which Music reconfigures
        // on its own schedule after a device rate change — right after a
        // switch the tap can still be at the old rate. Confirm the formats
        // agree before rendering: wait for them, and recreate the tap if the
        // first one stays behind.
        var confirmed: (tap: (format: AudioStreamBasicDescription, firstBuffer: Int, streamCount: Int),
                        output: AudioStreamBasicDescription)?
        for attempt in 1...3 {
            guard let tap = createTap(processObject: processObject, deviceUID: outputUID) else {
                stop()
                return fail("AudioHardwareCreateProcessTap failed.")
            }
            tapID = tap
            guard let tapUID = stringProperty(tap, selector: kAudioTapPropertyUID) else {
                stop()
                return fail("Couldn't read the tap UID.")
            }
            guard let aggregate = createAggregate(tapUID: tapUID, outputUID: outputUID) else {
                stop()
                return fail("AudioHardwareCreateAggregateDevice failed.")
            }
            aggregateID = aggregate
            if let formats = awaitMatchingFormats(of: aggregate, timeout: 1.0, attempt: attempt) {
                confirmed = formats
                break
            }
            tearDownAudio()
        }
        guard let confirmed else {
            stop()
            return fail("Unsupported Core Audio stream format. Hertzwise requires matching Float32 PCM streams.")
        }
        let tapStream = confirmed.tap
        let capturedOutputFormat = confirmed.output
        inputFormat = tapStream.format
        inputFirstBuffer = tapStream.firstBuffer
        outputFormat = capturedOutputFormat
        log.notice("Aggregate has \(tapStream.streamCount, privacy: .public) input stream(s); reading the tap from the last one, buffer \(tapStream.firstBuffer, privacy: .public)")
        sampleRate = capturedOutputFormat.mSampleRate

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID,
                                                     ioProc,
                                                     Unmanaged.passUnretained(self).toOpaque(),
                                                     &procID)
        guard createStatus == noErr, let procID else {
            stop()
            return fail("AudioDeviceCreateIOProcID failed (\(createStatus)).")
        }
        ioProcID = procID

        apply(profile: currentProfile)
        processor.requestReset()
        processor.setActive(desiredActive)

        if source == .allButHertzwise {
            setGain(deviceGain(outputDevice))
        }
        // The first render starts at the volume already set, not ramping
        // down from full level: the tap has muted the device's own output.
        renderGain = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        // The old path stops only now, with the new one ready to start: both
        // taps mute the device, so the handover is silence, never full level.
        if let retiringPath, let oldProc = retiringPath.ioProc {
            AudioDeviceStop(retiringPath.aggregate, oldProc)
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stop()
            return fail("AudioDeviceStart failed (\(startStatus)).")
        }

        isRunning = true
        dismantleRetiringPath()
        installLifecycleListeners(device: outputDevice)
        log.notice("EQ engine started at \(self.sampleRate, privacy: .public) Hz; tap in \(Self.describe(self.inputFormat), privacy: .public); device out \(Self.describe(self.outputFormat), privacy: .public)")
        startHealthTimer()
        return true
    }

    /// Volume stage, control queue: a path kept running through a rate change
    /// can fall out of step with the device and deliver ~1% too few samples,
    /// heard as dropouts. A fresh path is right, so build one while the old
    /// keeps playing and muting, then hand over. On failure the old one stays.
    private func replacePathForRateChange() {
        guard isRunning else { return }
        stopHealthTimer()
        removeLifecycleListeners()
        retiringPath = (tapID, aggregateID, ioProcID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        pathGeneration += 1
        isRunning = false
        isReplacingPath = true
        let started = start()
        isReplacingPath = false
        if started {
            log.notice("Volume path replaced at \(self.sampleRate, privacy: .public) Hz")
            return
        }
        // start() failed and tore down its partial path; resume the old one.
        guard let old = retiringPath else { return }
        retiringPath = nil
        tapID = old.tap
        aggregateID = old.aggregate
        ioProcID = old.ioProc
        if let oldProc = old.ioProc { AudioDeviceStart(old.aggregate, oldProc) }
        isRunning = true
        if let device = boundDeviceUID.flatMap({ deviceID(uid: $0) }) {
            installLifecycleListeners(device: device)
        }
        startHealthTimer()
        log.error("Volume path replacement failed; kept the old path")
    }

    private func dismantleRetiringPath() {
        guard let old = retiringPath else { return }
        retiringPath = nil
        if let oldProc = old.ioProc, old.aggregate != kAudioObjectUnknown {
            AudioDeviceStop(old.aggregate, oldProc)
            AudioDeviceDestroyIOProcID(old.aggregate, oldProc)
        }
        if old.aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(old.aggregate) }
        if old.tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(old.tap) }
    }

    func stop() {
        stopHealthTimer()
        rebuildWork?.cancel()
        rebuildWork = nil
        removeLifecycleListeners()
        tearDownAudio()
        if !isReplacingPath { dismantleRetiringPath() }
        processor.setActive(false)
        processor.requestReset()
        isRunning = false
        log.info("EQ engine stopped")
    }

    private func tearDownAudio() {
        if let ioProcID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - EQ control

    /// Turn DSP processing on or off. Coefficients are supplied separately via
    /// `apply(profile:)`; bypass = true is a true passthrough.
    func setActive(_ active: Bool) {
        desiredActive = active
        processor.setActive(active)
    }

    /// Recompute coefficients for a profile at the current sample rate.
    /// Coefficients are sample-rate dependent, so this also runs automatically
    /// when the device rate changes (see `handleRateChange`). `sampleRate` is
    /// the aggregate's actual stream rate — the rate the IOProc processes at.
    ///
    /// Bands are matched to the profile's design-rate response, so a preset
    /// sounds the same whether this track plays at 44.1 or 192 kHz.
    func apply(profile: PEQProfile) {
        let validated = profile.sanitized()
        currentProfile = validated
        // A band the matcher can't reproduce with one section may take two,
        // while the processor has sections to spare.
        let enabledBands = validated.bands.filter { $0.isEnabled }
        var spareSections = BiquadProcessor.maximumSections - enabledBands.count
        var coefficients: [BiquadCoefficients] = []
        for band in enabledBands {
            let sections = PEQRateMatcher.sections(for: band,
                                                   designRate: validated.designSampleRate,
                                                   playbackRate: sampleRate,
                                                   maxSections: spareSections > 0 ? 2 : 1)
            spareSections -= sections.count - 1
            coefficients += sections
        }
        // Headroom from exactly what will play: the matched sections at this rate.
        let automaticHeadroom = PEQResponse.requiredAutomaticHeadroomDB(sections: coefficients,
                                                                         preampDB: validated.preampDB,
                                                                         sampleRate: sampleRate)
        processor.setSections(coefficients,
                              preampDB: validated.preampDB - automaticHeadroom,
                              sampleRate: sampleRate)
        onHeadroomChange?(automaticHeadroom)
    }

    func clippingEventCount() -> UInt64 {
        processor.clippingEventCount()
    }

    func setSampleSink(_ sink: SpectrumAnalyzer?) {
        sampleSinkPointer = sink.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    // MARK: - Render (audio thread)

    fileprivate func render(input: UnsafePointer<AudioBufferList>,
                            output: UnsafeMutablePointer<AudioBufferList>) {
        if source == .allButHertzwise {
            renderPassThrough(input: input, output: output)
            return
        }
        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outputFrames = frameCapacity(of: outList, format: outputFormat)
        guard outputFrames > 0 else { return }
        let inputFrames = frameCapacity(of: inList, format: inputFormat, firstBuffer: inputFirstBuffer)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        let capturedChannels = min(Int(inputFormat.mChannelsPerFrame), BiquadProcessor.maximumChannels)
        let renderedChannels = min(outputChannels, BiquadProcessor.maximumChannels)
        let spectrumFrames = min(outputFrames, Self.spectrumCapacity)

        // Blocks of up to `blockFrames`, channel by channel: the processor runs
        // each section over a whole block (vDSP) instead of sample by sample.
        processor.beginRender(frameCount: outputFrames)
        var start = 0
        while start < outputFrames {
            let count = min(BiquadProcessor.blockFrames, outputFrames - start)
            let available = max(0, min(count, inputFrames - start))
            for channel in 0..<outputChannels {
                guard let destination = channelBuffer(outList, format: outputFormat, channel: channel) else {
                    continue
                }
                let out = destination.base + start * destination.stride
                guard channel < renderedChannels else {
                    for index in 0..<count { out[index * destination.stride] = 0 }
                    continue
                }

                gatherInput(channel: channel, from: inList, start: start,
                            count: count, available: available,
                            downmix: outputChannels == 1 && capturedChannels >= 2,
                            capturedChannels: capturedChannels)
                processor.process(channel: channel,
                                  input: inputScratch,
                                  output: out,
                                  outputStride: destination.stride,
                                  frameOffset: start,
                                  frameCount: count)

                var peak: Float = 0
                vDSP_maxmgv(inputScratch, 1, &peak, vDSP_Length(count))
                if peak > Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) {
                    inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
                }
                vDSP_maxmgv(out, vDSP_Stride(destination.stride), &peak, vDSP_Length(count))
                if peak > Float(bitPattern: outputPeakBits.load(ordering: .relaxed)) {
                    outputPeakBits.store(peak.bitPattern, ordering: .relaxed)
                }

                if channel == 0, start < spectrumFrames {
                    for index in 0..<min(count, spectrumFrames - start) {
                        spectrumScratch[start + index] = out[index * destination.stride]
                    }
                }
            }
            start += count
        }
        processor.endRender(frameCount: outputFrames)
        renderCycles.wrappingAdd(1, ordering: .relaxed)

        if spectrumFrames > 0, let sampleSinkPointer {
            let sampleSink = Unmanaged<SpectrumAnalyzer>
                .fromOpaque(sampleSinkPointer)
                .takeUnretainedValue()
            sampleSink.append(spectrumScratch, count: spectrumFrames)
        }
    }

    /// Sets the volume stage's gain, clamped to 0…1. A change ramps across
    /// the next render, so it never clicks.
    func setGain(_ gain: Float) {
        targetGainBits.store(min(max(gain, 0), 1).bitPattern, ordering: .relaxed)
    }

    /// Copies each tap channel to the same output channel at the volume
    /// stage's gain. At gain 1 the device receives the players' own samples.
    private func renderPassThrough(input: UnsafePointer<AudioBufferList>,
                                   output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outputFrames = frameCapacity(of: outList, format: outputFormat)
        guard outputFrames > 0 else { return }
        let available = min(outputFrames,
                            frameCapacity(of: inList, format: inputFormat, firstBuffer: inputFirstBuffer))
        if available < outputFrames {
            missingFrames.wrappingAdd(UInt64(outputFrames - available), ordering: .relaxed)
        }
        let startGain = renderGain
        let targetGain = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        let step = available > 0 ? (targetGain - startGain) / Float(available) : 0
        var inPeak: Float = 0
        var outPeak: Float = 0
        for channel in 0..<Int(outputFormat.mChannelsPerFrame) {
            guard let destination = channelBuffer(outList, format: outputFormat, channel: channel) else { continue }
            var copied = 0
            if let source = channelBuffer(inList, format: inputFormat, channel: channel, firstBuffer: inputFirstBuffer) {
                for index in 0..<available {
                    let sample = source.base[index * source.stride]
                    let gain = step == 0 ? targetGain : startGain + step * Float(index + 1)
                    let out = sample * gain
                    destination.base[index * destination.stride] = out
                    outPeak = max(outPeak, abs(out))
                    inPeak = max(inPeak, abs(sample))
                }
                copied = available
            }
            for index in copied..<outputFrames { destination.base[index * destination.stride] = 0 }
        }
        renderGain = targetGain
        if inPeak > Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) {
            inputPeakBits.store(inPeak.bitPattern, ordering: .relaxed)
        }
        if outPeak > Float(bitPattern: outputPeakBits.load(ordering: .relaxed)) {
            outputPeakBits.store(outPeak.bitPattern, ordering: .relaxed)
        }
        renderCycles.wrappingAdd(1, ordering: .relaxed)
    }

    /// Fills `inputScratch[0..<count]` with one output channel's source: the
    /// matching tap channel, a stereo downmix for a mono device, or silence;
    /// zero-padded past what the tap delivered.
    @inline(__always)
    private func gatherInput(channel: Int,
                             from list: UnsafeMutableAudioBufferListPointer,
                             start: Int, count: Int, available: Int,
                             downmix: Bool, capturedChannels: Int) {
        var filled = 0
        if available > 0 {
            if downmix,
               let left = channelBuffer(list, format: inputFormat, channel: 0, firstBuffer: inputFirstBuffer),
               let right = channelBuffer(list, format: inputFormat, channel: 1, firstBuffer: inputFirstBuffer) {
                for index in 0..<available {
                    inputScratch[index] = (left.base[(start + index) * left.stride]
                                           + right.base[(start + index) * right.stride]) * 0.5
                }
                filled = available
            } else if channel < capturedChannels,
                      let source = channelBuffer(list, format: inputFormat, channel: channel,
                                                 firstBuffer: inputFirstBuffer) {
                for index in 0..<available {
                    inputScratch[index] = source.base[(start + index) * source.stride]
                }
                filled = available
            }
        }
        if filled < count {
            (inputScratch + filled).update(repeating: 0, count: count - filled)
        }
    }

    // MARK: - Fixed processing rate

    /// Sets `device` to `processingRate` — or the closest rate it supports —
    /// and waits until the device actually reports it: a rate change finishes
    /// asynchronously, so a fixed delay would only be a guess.
    private func holdProcessingRate(on device: AudioObjectID) {
        guard let current = nominalSampleRate(device) else { return }
        let target = closestSupportedRate(to: Self.processingRate, device: device) ?? current
        if rateToRestore == nil { rateToRestore = (device, current) }
        guard abs(current - target) >= 0.5 else { return }

        guard setNominalSampleRate(target, on: device) else {
            log.error("Couldn't set the output to \(target, privacy: .public) Hz for the EQ")
            return
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let now = nominalSampleRate(device), abs(now - target) < 0.5 { break }
            usleep(10_000)
        }
        log.notice("Output held at \(target, privacy: .public) Hz for the EQ (was \(current, privacy: .public) Hz)")
    }

    /// Control queue: switches between holding `processingRate` and following
    /// each track. Turning the hold on while running rebuilds the path at the
    /// held rate; turning it off leaves the device where it is for automatic
    /// switching to take over.
    func setHoldsProcessingRate(_ hold: Bool) {
        guard hold != holdsProcessingRate else { return }
        holdsProcessingRate = hold
        if hold {
            scheduleRebuild()
        } else {
            rateToRestore = nil
        }
    }

    /// Puts the device back at the rate it had before the EQ held it. Call
    /// after `stop()` when the user turns the EQ off.
    func restoreOutputRate() {
        guard let saved = rateToRestore else { return }
        rateToRestore = nil
        if let now = nominalSampleRate(saved.device), abs(now - saved.rate) >= 0.5 {
            _ = setNominalSampleRate(saved.rate, on: saved.device)
        }
    }

    private func setNominalSampleRate(_ rate: Double, on device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Double>.size), &value) == noErr
    }

    private func closestSupportedRate(to wanted: Double, device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else {
            return nil
        }
        if ranges.contains(where: { $0.mMinimum <= wanted && wanted <= $0.mMaximum }) { return wanted }
        let candidates = ranges.flatMap { [$0.mMinimum, $0.mMaximum] }
        return candidates.min { abs($0 - wanted) < abs($1 - wanted) }
    }

    // MARK: - Render health

    private func startHealthTimer() {
        stopHealthTimer()
        silentWindows = 0
        reportedSilence = false
        _ = renderCycles.exchange(0, ordering: .relaxed)
        _ = inputPeakBits.exchange(0, ordering: .relaxed)
        _ = outputPeakBits.exchange(0, ordering: .relaxed)
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.reportHealth() }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func reportHealth() {
        let cycles = renderCycles.exchange(0, ordering: .relaxed)
        let input = Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed))
        let output = Float(bitPattern: outputPeakBits.exchange(0, ordering: .relaxed))
        let missing = missingFrames.exchange(0, ordering: .relaxed)
        log.notice("Health: \(cycles, privacy: .public) renders in 2 s, tap peak \(Self.dBFS(input), privacy: .public), output peak \(Self.dBFS(output), privacy: .public), \(missing, privacy: .public) frames missing")

        silentWindows = cycles > 0 && input == 0 ? silentWindows + 1 : 0
        let silent = silentWindows >= 3
        if silent != reportedSilence {
            reportedSilence = silent
            DispatchQueue.main.async { [weak self] in self?.onInputSilence?(silent) }
        }
    }

    private static func dBFS(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "silence"
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(format.mChannelsPerFrame) ch \(interleaved ? "interleaved" : "non-interleaved") @ \(format.mSampleRate) Hz"
    }

    // MARK: - Core Audio setup

    /// Taps Music's audio on its way to the output device's first stream.
    /// Bound to that stream, the tap takes the stream's own format — the
    /// device's current rate, so a 96 kHz track arrives at 96 kHz. A plain
    /// stereo mixdown tap is delivered at a fixed system rate instead (48 kHz
    /// here), which no other device rate could match.
    private func createTap(processObject: AudioObjectID, deviceUID: String) -> AudioObjectID? {
        let description: CATapDescription
        switch source {
        case .appleMusic:
            description = CATapDescription(processes: [processObject], deviceUID: deviceUID, stream: 0)
            description.name = "Hertzwise EQ Tap"
        case .allButHertzwise:
            description = CATapDescription(excludingProcesses: [processObject], deviceUID: deviceUID, stream: 0)
            description.name = "Hertzwise Volume Tap"
        }
        description.isPrivate = true
        description.muteBehavior = .muted   // silence Music's own output; we re-render
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateProcessTap failed: \(status)")
            return nil
        }
        return tap
    }

    private func createAggregate(tapUID: String, outputUID: String) -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: source == .appleMusic ? "Hertzwise EQ" : "Hertzwise Volume",
            kAudioAggregateDeviceUIDKey as String: "\(aggregateUID).\(pathGeneration)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    // The volume tap is bound to the output device's own
                    // stream, so it shares its clock; drift compensation would
                    // only resample it and cost bit-exactness.
                    kAudioSubTapDriftCompensationKey as String: source == .appleMusic,
                    kAudioSubTapUIDKey as String: tapUID,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return aggregate
    }

    // MARK: - Output-device / sample-rate following

    private func installLifecycleListeners(device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The notification for our own switch to `processingRate` can
            // arrive after the path is already up at that rate; only a real
            // change of rate needs a rebuild.
            guard let self else { return }
            guard let rate = self.nominalSampleRate(device), abs(rate - self.sampleRate) >= 0.5 else { return }
            if self.source == .allButHertzwise {
                // Not the EQ's rebuild: tearing down first would drop the
                // tap, and its mute, for seconds, so full level would reach
                // the DAC. The replacement is built before the old one goes.
                self.replacePathForRateChange()
                return
            }
            self.scheduleRebuild()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, controlQueue, block)
        if status == noErr {
            rateListenerDevice = device
            rateListenerBlock = block
        }

        if source == .allButHertzwise {
            let gainBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.setGain(self.deviceGain(device))
            }
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var gainAddress = AudioObjectPropertyAddress(mSelector: selector,
                                                             mScope: kAudioDevicePropertyScopeOutput,
                                                             mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(device, &gainAddress, controlQueue, gainBlock)
            }
            gainListenerBlock = gainBlock
            gainListenerDevice = device
        }
        guard boundDeviceUID == nil else { return }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            controlQueue,
            defaultBlock)
        if defaultStatus == noErr {
            defaultDeviceListenerBlock = defaultBlock
        }
    }

    private func removeLifecycleListeners() {
        if let block = gainListenerBlock, gainListenerDevice != kAudioObjectUnknown {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = AudioObjectPropertyAddress(mSelector: selector,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(gainListenerDevice, &address, controlQueue, block)
            }
        }
        gainListenerBlock = nil
        gainListenerDevice = kAudioObjectUnknown

        if let block = rateListenerBlock, rateListenerDevice != kAudioObjectUnknown {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, controlQueue, block)
        }
        rateListenerBlock = nil
        rateListenerDevice = kAudioObjectUnknown

        if let block = defaultDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address,
                                                   controlQueue,
                                                   block)
        }
        defaultDeviceListenerBlock = nil
    }

    private func scheduleRebuild() {
        guard isRunning else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildAudioPath() }
        rebuildWork = work
        controlQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func rebuildAudioPath() {
        guard isRunning else { return }
        let shouldBeActive = desiredActive
        removeLifecycleListeners()
        tearDownAudio()
        isRunning = false
        processor.requestReset()

        desiredActive = shouldBeActive
        if start() {
            onSampleRateChange?(sampleRate)
            log.notice("EQ audio path rebuilt at \(self.sampleRate, privacy: .public) Hz")
        } else {
            let message = lastError ?? "Couldn't rebuild the EQ audio path."
            onRuntimeError?(message)
        }
    }

    // MARK: - Stream format / buffer helpers

    /// The tap's stream among the aggregate's inputs — the last one, after
    /// the sub-device's own input streams — with its format and the index of
    /// its first buffer in the IOProc's input list.
    private func tapInputStream(of aggregate: AudioObjectID)
        -> (format: AudioStreamBasicDescription, firstBuffer: Int, streamCount: Int)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &streams) == noErr,
              !streams.isEmpty else { return nil }

        var firstBuffer = 0
        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr else {
                return nil
            }
            formats.append(format)
        }
        for format in formats.dropLast() {
            let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            firstBuffer += nonInterleaved ? Int(format.mChannelsPerFrame) : 1
        }
        return (formats[formats.count - 1], firstBuffer, streams.count)
    }

    private func streamFormat(device: AudioObjectID,
                              scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    /// Polls the aggregate until the tap's stream and the output agree
    /// (Float32 PCM, same rate), or `timeout` passes; logs both formats
    /// when they never do.
    private func awaitMatchingFormats(of aggregate: AudioObjectID, timeout: TimeInterval, attempt: Int)
        -> (tap: (format: AudioStreamBasicDescription, firstBuffer: Int, streamCount: Int),
            output: AudioStreamBasicDescription)? {
        let deadline = Date().addingTimeInterval(timeout)
        var tap = tapInputStream(of: aggregate)
        var output = streamFormat(device: aggregate, scope: kAudioObjectPropertyScopeOutput)
        while true {
            if let tap, let output, validateFormats(input: tap.format, output: output) {
                return (tap, output)
            }
            guard Date() < deadline else { break }
            usleep(25_000)
            tap = tapInputStream(of: aggregate)
            output = streamFormat(device: aggregate, scope: kAudioObjectPropertyScopeOutput)
        }
        log.notice("Tap and output formats disagree (attempt \(attempt, privacy: .public)): tap \(tap.map { Self.describe($0.format) } ?? "none", privacy: .public), output \(output.map(Self.describe) ?? "none", privacy: .public)")
        return nil
    }

    private func validateFormats(input: AudioStreamBasicDescription,
                                 output: AudioStreamBasicDescription) -> Bool {
        guard isSupportedFloatPCM(input), isSupportedFloatPCM(output),
              input.mChannelsPerFrame > 0, output.mChannelsPerFrame > 0,
              input.mSampleRate > 0, output.mSampleRate > 0,
              abs(input.mSampleRate - output.mSampleRate) < 0.5 else {
            return false
        }
        return true
    }

    private func isSupportedFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mBitsPerChannel == 32,
              format.mFramesPerPacket == 1 else {
            return false
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytes = UInt32(MemoryLayout<Float>.size)
            * (nonInterleaved ? 1 : format.mChannelsPerFrame)
        return format.mBytesPerFrame == expectedBytes
            && format.mBytesPerPacket == expectedBytes
    }

    @inline(__always)
    private func frameCapacity(of list: UnsafeMutableAudioBufferListPointer,
                               format: AudioStreamBasicDescription,
                               firstBuffer: Int = 0) -> Int {
        let bytesPerFrame = Int(format.mBytesPerFrame)
        guard bytesPerFrame > 0, firstBuffer < list.count else { return 0 }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved {
            let count = min(Int(format.mChannelsPerFrame), list.count - firstBuffer)
            guard count > 0 else { return 0 }
            var result = Int.max
            for index in firstBuffer..<(firstBuffer + count) {
                result = min(result, Int(list[index].mDataByteSize) / bytesPerFrame)
            }
            return result == Int.max ? 0 : result
        }
        return Int(list[firstBuffer].mDataByteSize) / bytesPerFrame
    }

    /// First sample and stride of one channel, for interleaved or
    /// non-interleaved Float32 buffers.
    @inline(__always)
    private func channelBuffer(_ list: UnsafeMutableAudioBufferListPointer,
                               format: AudioStreamBasicDescription,
                               channel: Int,
                               firstBuffer: Int = 0) -> (base: UnsafeMutablePointer<Float>, stride: Int)? {
        let channels = Int(format.mChannelsPerFrame)
        guard channel < channels else { return nil }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferIndex = firstBuffer + (nonInterleaved ? channel : 0)
        guard bufferIndex < list.count, let data = list[bufferIndex].mData else { return nil }
        let samples = data.assumingMemoryBound(to: Float.self)
        return nonInterleaved ? (samples, 1) : (samples + channel, channels)
    }

    // MARK: - Property helpers

    private func processObject(bundleID: String) -> AudioObjectID? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        return processObject(pid: app.processIdentifier)
    }

    private func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func deviceID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The device's own volume as a linear gain, from its dB value; 0 when
    /// muted, 1 when it has no volume to read.
    private func deviceGain(_ device: AudioObjectID) -> Float {
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var muted = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr, muted != 0 {
            return 0
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var decibels = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &decibels) == noErr else { return 1 }
        return min(pow(10, decibels / 20), 1)
    }

    private func deviceUID(_ device: AudioObjectID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private func stringProperty(_ object: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        lastError = message
        log.error("\(message, privacy: .public)")
        return false
    }
}

// Top-level C-compatible IOProc; recovers the engine from the client-data pointer.
private func ioProc(_ device: AudioObjectID,
                    _ now: UnsafePointer<AudioTimeStamp>,
                    _ inputData: UnsafePointer<AudioBufferList>,
                    _ inputTime: UnsafePointer<AudioTimeStamp>,
                    _ outputData: UnsafeMutablePointer<AudioBufferList>,
                    _ outputTime: UnsafePointer<AudioTimeStamp>,
                    _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let engine = Unmanaged<ProcessTapEngine>.fromOpaque(clientData).takeUnretainedValue()
    engine.render(input: inputData, output: outputData)
    return noErr
}
