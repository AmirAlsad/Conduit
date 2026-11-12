//
//  CallTrace.swift
//  Conduit
//
//  DEBUG-only call tracer. Appends timestamped lines to `conduit-call-trace.log`
//  in Documents, so a real on-device session can be pulled and reconstructed:
//  each launch (a VoIP push's cold launch included), the call host's view of
//  every ring and call (`AgentCallHost`), the engine's pre-connect phase, hold,
//  audio activation, interruption and mute (`CallTraceObserver`), the transports
//  made, and the in-call screen's route snapshots. The file is kept across
//  launches and rotated to `conduit-call-trace.previous.log` once it is large.
//  Nothing is written until `startSession()` runs, which only the live
//  environment does.
//

#if DEBUG
import Foundation

enum CallTrace {
    private static let rotateAtBytes = 2_000_000
    private static var isEnabled = false

    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static var url: URL? {
        directory?.appendingPathComponent("conduit-call-trace.log")
    }

    /// Starts writing, after moving a large trace aside.
    static func startSession(_ line: String) {
        if let url, let directory,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > rotateAtBytes {
            let previous = directory.appendingPathComponent("conduit-call-trace.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        isEnabled = true
        record(line)
    }

    static func record(_ line: String) {
        guard isEnabled else { return }
        Log.info(.call, "TRACE \(line)")
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        guard let url, let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
