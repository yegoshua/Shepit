import Foundation
import os

/// Startup and runtime diagnostics, mirrored to ~/Library/Logs/Shepit.log so they can be read without Xcode.
enum Log {
    private static let logger = Logger(subsystem: "dev.yegor.shepit", category: "app")
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Shepit.log")
    private static let queue = DispatchQueue(label: "dev.yegor.shepit.log")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
