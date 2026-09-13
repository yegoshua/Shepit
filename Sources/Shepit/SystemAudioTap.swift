import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (except Shepit's own sounds) through a Core Audio
/// process tap wrapped in a private aggregate device, and writes it to a track file.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TrackFileWriter?
    private let queue = DispatchQueue(label: "dev.yegor.shepit.system-audio", qos: .userInitiated)

    func start(writingTo url: URL) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
            var format = try Self.tapFormat(tapID)
            guard let inputFormat = AVAudioFormat(streamDescription: &format) else {
                throw Self.error("unsupported tap format", status: 0)
            }
            let writer = try TrackFileWriter(url: url, inputFormat: inputFormat)
            self.writer = writer

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Shepit System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
                ],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil) else { return }
                writer.write(buffer)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        writer?.close()
        writer = nil
    }

    /// Shepit's own Core Audio process object, so its start/stop sounds stay out of "Others".
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw error("read tap format", status: status) }
        return format
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Self.error(step, status: status) }
    }

    private static func error(_ step: String, status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Системний звук недоступний (\(step), код \(status))"])
    }
}
