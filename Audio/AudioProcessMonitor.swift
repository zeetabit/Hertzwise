import CoreAudio
import Foundation

/// Reports which apps are outputting audio, from Core Audio's process objects
/// (macOS 14.4+). Reading them needs no permission, and listeners replace
/// polling. Calls `onChange` on the main queue with the bundle IDs of the
/// processes whose output is running.
final class AudioProcessMonitor {
    private let onChange: (Set<String>) -> Void
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

    init(onChange: @escaping (Set<String>) -> Void) {
        self.onChange = onChange
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.processListAddress, .main, listener)
        bindProcesses()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onChange(self.outputtingBundleIDs())
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
            self.onChange(self.outputtingBundleIDs())
        }
    }

    private func bindProcesses(_ current: [AudioObjectID] = AudioProcessMonitor.processObjects()) {
        unbindProcesses()
        processes = current
        for process in processes {
            AudioObjectAddPropertyListenerBlock(process, &Self.runningOutputAddress, .main, listener)
        }
    }

    private func unbindProcesses() {
        for process in processes {
            AudioObjectRemovePropertyListenerBlock(process, &Self.runningOutputAddress, .main, listener)
        }
        processes = []
    }

    private func outputtingBundleIDs() -> Set<String> {
        Set(processes.compactMap { process in
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &Self.runningOutputAddress, 0, nil, &size, &running) == noErr,
                  running != 0 else { return nil }
            return Self.bundleID(of: process)
        })
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
