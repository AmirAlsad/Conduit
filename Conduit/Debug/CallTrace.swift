//
//  CallTrace.swift
//  Conduit
//
//  DEBUG-only call tracer. Appends timestamped lines to `conduit-call-trace.log`
//  in Documents, so a real on-device session can be pulled and reconstructed:
//  each launch (a VoIP push's cold launch included), the call host's view of
//  every ring and call (`AgentCallHost`), the engine's pre-connect phase, hold,
//  audio activation, interruption and mute (`CallTraceObserver`), the engine's
//  pre-connect phase changes, every log event of the call engine package (including
//  CallKit's raw audio activations), the transports made, and the in-call screen's
//  route snapshots. The file is kept across
//  launches and rotated to `conduit-call-trace.previous.log` once it is large.
//  Nothing is written until `startSession()` runs, which only the live
//  environment does.
//

#if DEBUG
import ConduitCallEngine
import Foundation

enum CallTrace {
    private static let rotateAtBytes = 2_000_000
    private static var isEnabled = false
    /// The package logs from any thread, so every write goes through one serial
    /// queue; the timestamp is taken before the hop so the order stays true.
    private static let queue = DispatchQueue(label: "conduit.call-trace")

    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static var url: URL? {
        directory?.appendingPathComponent("conduit-call-trace.log")
    }

    /// Routes every log event of the call engine package into the trace as well as
    /// to Console. The hook is process-wide, so call this once, before the engine
    /// is created.
    static func captureEngineLog() {
        CallEngineLog.handler = { event in
            append("engine \(event.category.rawValue) \(event.level): \(event.message)")
            CallEngineLog.writeToOSLog(event)
        }
    }

    /// Starts writing, after moving a large trace aside.
    static func startSession(_ line: String) {
        queue.sync {
            if let url, let directory,
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > rotateAtBytes {
                let previous = directory.appendingPathComponent("conduit-call-trace.previous.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            isEnabled = true
        }
        record(line)
    }

    static func record(_ line: String) {
        append(line, toConsole: true)
    }

    private static func append(_ line: String, toConsole: Bool = false) {
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        queue.async {
            guard isEnabled else { return }
            if toConsole { Log.info(.call, "TRACE \(line)") }
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
}
#endif
