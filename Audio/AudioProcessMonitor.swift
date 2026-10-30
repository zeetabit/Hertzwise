import CoreAudio
import Foundation

/// Reports which apps are outputting audio, from Core Audio's process objects
/// (macOS 14.4+). Reading them needs no permission, and listeners replace
/// polling. Calls `onChange` on the main queue with the processes whose
/// output is running, by bundle ID, and the devices each plays to.
final class AudioProcessMonitor {
    private let onChange: ([String: Set<AudioObjectID>]) -> Void
    private var processes: [AudioObjectID] = []
    private var changePending = false
    /// One block for every registration: removal matches it by identity.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.propertyChanged()
    }

    private static var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var runningOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping ([String: Set<AudioObjectID>]) -> Void) {
        self.onChange = onChange
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.processListAddress, .main, listener)
        bindProcesses()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onChange(self.outputs())
        }
    }

    deinit {
        unbindProcesses()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &Self.processListAddress, .main, listener)
    }

    /// Runs on the main queue. A changed list rebinds; either way one
    /// coalesced report follows.
    private func propertyChanged() {
        let current = Self.processObjects()
        if current != processes {
            bindProcesses(current)
        }
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changePending = false
            self.onChange(self.outputs())
        }
    }

    private func bindProcesses(_ current: [AudioObjectID] = AudioProcessMonitor.processObjects()) {
        unbindProcesses()
        processes = current
        for process in processes {
            AudioObjectAddPropertyListenerBlock(process, &Self.runningOutputAddress, .main, listener)
            AudioObjectAddPropertyListenerBlock(process, &Self.devicesAddress, .main, listener)
        }
    }

    private func unbindProcesses() {
        for process in processes {
            AudioObjectRemovePropertyListenerBlock(process, &Self.runningOutputAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(process, &Self.devicesAddress, .main, listener)
        }
        processes = []
    }

    private func outputs() -> [String: Set<AudioObjectID>] {
        var result: [String: Set<AudioObjectID>] = [:]
        for process in processes {
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &Self.runningOutputAddress, 0, nil, &size, &running) == noErr,
                  running != 0, let bundleID = Self.bundleID(of: process) else { continue }
            result[bundleID, default: []].formUnion(Self.devices(of: process))
        }
        return result
    }

    /// Whether any process other than this one is outputting to `devices`.
    static func isOtherProcessOutputting(to devices: Set<AudioObjectID>) -> Bool {
        let ownBundleID = Bundle.main.bundleIdentifier
        return processObjects().contains { process in
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &runningOutputAddress, 0, nil, &size, &running) == noErr,
                  running != 0, bundleID(of: process) != ownBundleID else { return false }
            return !devices.isDisjoint(with: Self.devices(of: process))
        }
    }

    private static func devices(of process: AudioObjectID) -> [AudioObjectID] {
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(process, &devicesAddress, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &devicesAddress, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &processListAddress, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &processListAddress, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
