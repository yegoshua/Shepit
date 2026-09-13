import Foundation

/// The "System Audio Recording" privacy permission needed by process taps.
/// macOS has no public API to query or request it, so this uses the TCC framework's
/// preflight/request calls when they can be loaded; otherwise the status is unknown and
/// the system prompts by itself when the tap starts.
enum SystemAudioPermission {
    enum Status { case authorized, denied, undetermined, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .undetermined
        default: return .unknown
        }
    }

    /// Shows the system dialog when undetermined; returns whether access was granted.
    static func request() async -> Bool {
        guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessRequest") }) else { return true }
        let request = unsafeBitCast(symbol, to: Request.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
