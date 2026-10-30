import Foundation
import CoreAudio

struct OutputDeviceInfo {
    let id: AudioDeviceID?
    let name: String
    let sampleRate: Double?
    let iconName: String
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let iconName: String
}

/// Per output device: whether Hertzwise applies the Mac's volume to the
/// samples, for DACs that accept a volume from the Mac but ignore it.
enum HostVolumeControl {
    private static let key = "volumeControl.devices"
    /// Known to ignore the Mac's volume, by UID prefix: on unless turned off.
    private static let ignoresHostVolume = ["AppleUSBAudioEngine:Lotoo:PAW-S1:"]
    static let didChange = Notification.Name("io.github.zeetabit.hertzwise.hostVolumeControlDidChange")

    static func isEnabled(uid: String) -> Bool {
        stored[uid] ?? ignoresHostVolume.contains { uid.hasPrefix($0) }
    }

    static func setEnabled(_ enabled: Bool, uid: String) {
        var devices = stored
        devices[uid] = enabled
        UserDefaults.standard.set(devices, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static let volumesKey = "volumeControl.lastVolumes"

    /// The device volume Hertzwise last applied, as a scalar.
    static func rememberedVolume(uid: String) -> Float32? {
        (UserDefaults.standard.dictionary(forKey: volumesKey)?[uid] as? NSNumber)?.floatValue
    }

    static func remember(volume: Float32, uid: String) {
        var volumes = UserDefaults.standard.dictionary(forKey: volumesKey) ?? [:]
        guard (volumes[uid] as? NSNumber)?.floatValue != volume else { return }
        volumes[uid] = volume
        UserDefaults.standard.set(volumes, forKey: volumesKey)
    }

    private static var stored: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }
}

struct OutputVolumeInfo {
    let volume: Float
    let settable: Bool
}

final class AudioDeviceController {
    func defaultOutputDeviceInfo() -> OutputDeviceInfo {
        guard let deviceID = defaultOutputDeviceID() else {
            return OutputDeviceInfo(id: nil, name: "Unknown", sampleRate: nil, iconName: "speaker.wave.2.fill")
        }

        let name = stringProperty(objectID: deviceID,
                                  selector: kAudioObjectPropertyName) ?? "Unknown"
        let sampleRate = doubleProperty(objectID: deviceID,
                                        selector: kAudioDevicePropertyNominalSampleRate)

        return OutputDeviceInfo(id: deviceID,
                                name: name,
                                sampleRate: sampleRate,
                                iconName: transportIconName(deviceID: deviceID))
    }

    func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
            .filter { hasOutputStreams(deviceID: $0) }
            .map { deviceID in
                AudioOutputDevice(id: deviceID,
                                  uid: stringProperty(objectID: deviceID,
                                                      selector: kAudioDevicePropertyDeviceUID) ?? "",
                                  name: stringProperty(objectID: deviceID,
                                                       selector: kAudioObjectPropertyName) ?? "Unknown",
                                  iconName: transportIconName(deviceID: deviceID))
            }
    }

    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil, size, &newID) == noErr
    }

    func availableSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }

        let standardRates: [Double] = [8000, 11025, 16000, 22050, 32000,
                                       44100, 48000, 88200, 96000,
                                       176400, 192000, 352800, 384000,
                                       705600, 768000]
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for rate in standardRates
                where rate >= range.mMinimum - 0.5 && rate <= range.mMaximum + 0.5 {
                    rates.insert(rate)
                }
            }
        }

        return rates.sorted()
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }

        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    func outputVolumeInfo() -> OutputVolumeInfo? {
        guard let deviceID = defaultOutputDeviceID(),
              let (selector, elements) = volumeAddress(deviceID: deviceID) else {
            return nil
        }

        var values: [Float] = []
        var settable = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )

            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
                continue
            }

            values.append(value)
            var isSettable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue {
                settable = true
            }
        }

        guard !values.isEmpty else {
            return nil
        }

        return OutputVolumeInfo(volume: values.reduce(0, +) / Float(values.count), settable: settable)
    }

    func setOutputVolume(_ volume: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID(),
              let (selector, elements) = volumeAddress(deviceID: deviceID) else {
            return false
        }

        let clamped = min(max(volume, 0), 1)
        var success = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )

            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else {
                continue
            }

            var value = Float32(clamped)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                success = true
            }
        }

        return success
    }

    private func volumeAddress(deviceID: AudioDeviceID) -> (selector: AudioObjectPropertySelector, elements: [AudioObjectPropertyElement])? {
        // 'vmvc' — virtual main volume synthesized by the HAL for devices
        // without a settable hardware main volume.
        let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)
        let candidates: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

        for selector in [kAudioDevicePropertyVolumeScalar, virtualMainVolume] {
            let present = candidates.filter { element in
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                return AudioObjectHasProperty(deviceID, &address)
            }

            if present.contains(kAudioObjectPropertyElementMain) {
                return (selector, [kAudioObjectPropertyElementMain])
            }

            if !present.isEmpty {
                return (selector, present)
            }
        }

        return nil
    }

    private func transportIconName(deviceID: AudioDeviceID) -> String {
        guard let transport = uint32Property(objectID: deviceID,
                                             selector: kAudioDevicePropertyTransportType) else {
            return "speaker.wave.2.fill"
        }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            return "hifispeaker.fill"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return "waveform"
        default:
            return "speaker.wave.2.fill"
        }
    }

    func setDefaultOutputSampleRate(_ sampleRate: Double) -> Bool {
        setOutputSampleRate(sampleRate, deviceUID: nil)
    }

    /// `deviceUID` nil means the system default output.
    func nominalSampleRate(deviceUID: String?) -> Double? {
        guard let deviceID = outputDeviceID(uid: deviceUID) else {
            return nil
        }
        return doubleProperty(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate)
    }

    /// True when another process holds the device exclusively (hog mode), as
    /// a player in exclusive mode does. `deviceUID` nil means the system
    /// default output.
    func isHeldByAnotherProcess(deviceUID: String?) -> Bool {
        guard let deviceID = outputDeviceID(uid: deviceUID) else {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var owner = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &owner) == noErr else {
            return false
        }
        return owner != -1 && owner != getpid()
    }

    /// `deviceUID` nil means the system default output.
    func setOutputSampleRate(_ sampleRate: Double, deviceUID: String?) -> Bool {
        guard let deviceID = outputDeviceID(uid: deviceUID) else {
            return false
        }

        guard let targetRate = nearestSupportedSampleRate(sampleRate, deviceID: deviceID) else {
            return false
        }

        var settable: DarwinBoolean = false
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard status == noErr, settable.boolValue else {
            return false
        }

        var rate = targetRate
        var size = UInt32(MemoryLayout<Double>.size)
        let setStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &rate)
        return setStatus == noErr
    }

    private func outputDeviceID(uid: String?) -> AudioDeviceID? {
        guard let uid else {
            return defaultOutputDeviceID()
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address,
                                       UInt32(MemoryLayout<CFString>.size),
                                       uidPointer,
                                       &size,
                                       &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                0,
                                                nil,
                                                &size,
                                                &deviceID)
        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private func stringProperty(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            return nil
        }

        var cfString: CFString?
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfString)
        guard status == noErr else {
            return nil
        }

        return cfString as String?
    }

    private func uint32Property(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private func doubleProperty(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private func nearestSupportedSampleRate(_ desired: Double,
                                            deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return desired
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return desired
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = Array(repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return desired
        }

        for range in ranges {
            if desired >= range.mMinimum - 0.5 && desired <= range.mMaximum + 0.5 {
                return desired
            }
        }

        var closest: Double?
        var minDiff = Double.greatestFiniteMagnitude
        for range in ranges {
            let candidates = [range.mMinimum, range.mMaximum]
            for candidate in candidates {
                let diff = abs(desired - candidate)
                if diff < minDiff {
                    minDiff = diff
                    closest = candidate
                }
            }
        }

        return closest
    }
}

extension AudioDeviceController {
    /// Calls `onChange` on the main queue when the default output device, the
    /// device list, or the default device's rate or volume changes. Listening
    /// stops when the returned observation is released.
    func observeChanges(_ onChange: @escaping () -> Void) -> AudioDeviceObservation {
        AudioDeviceObservation(
            onChange: onChange,
            currentDevice: { [weak self] in self?.defaultOutputDeviceID() },
            deviceAddresses: { [weak self] deviceID in self?.observedAddresses(deviceID: deviceID) ?? [] }
        )
    }

    private func observedAddresses(deviceID: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var addresses = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates].map {
            AudioObjectPropertyAddress(mSelector: $0,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
        }
        if let (selector, elements) = volumeAddress(deviceID: deviceID) {
            addresses += elements.map {
                AudioObjectPropertyAddress(mSelector: selector,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: $0)
            }
        }
        return addresses
    }
}

/// Core Audio listeners that replace polling the device state. A device switch
/// fires several changes at once; they are coalesced into one `onChange`.
final class AudioDeviceObservation {
    private let onChange: () -> Void
    private let currentDevice: () -> AudioDeviceID?
    private let deviceAddresses: (AudioDeviceID) -> [AudioObjectPropertyAddress]
    private var boundDevice: AudioDeviceID?
    private var deviceRegistrations: [AudioObjectPropertyAddress] = []
    private var systemRegistrations: [AudioObjectPropertyAddress] = []
    private var changePending = false
    /// One block for every registration: removal matches it by identity.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.propertyChanged()
    }

    fileprivate init(onChange: @escaping () -> Void,
                     currentDevice: @escaping () -> AudioDeviceID?,
                     deviceAddresses: @escaping (AudioDeviceID) -> [AudioObjectPropertyAddress]) {
        self.onChange = onChange
        self.currentDevice = currentDevice
        self.deviceAddresses = deviceAddresses

        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, listener) == noErr {
                systemRegistrations.append(address)
            }
        }
        bindCurrentDevice()
    }

    deinit {
        unbindDevice()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var address in systemRegistrations {
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener)
        }
    }

    /// Runs on the main queue.
    private func propertyChanged() {
        if currentDevice() != boundDevice {
            bindCurrentDevice()
        }
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changePending = false
            self.onChange()
        }
    }

    private func bindCurrentDevice() {
        unbindDevice()
        guard let deviceID = currentDevice() else { return }
        boundDevice = deviceID
        for var address in deviceAddresses(deviceID) {
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener) == noErr {
                deviceRegistrations.append(address)
            }
        }
    }

    private func unbindDevice() {
        if let boundDevice {
            for var address in deviceRegistrations {
                AudioObjectRemovePropertyListenerBlock(boundDevice, &address, .main, listener)
            }
        }
        deviceRegistrations = []
        boundDevice = nil
    }
}
