//
//  CallTrace.swift
//  Conduit
//
//  DEBUG-only call-state tracer. The in-call screen polls the coordinator and
//  appends every state/mute/activation change to `conduit-call-trace.log` in
//  Documents, so a real on-device call's timeline can be pulled and inspected
//  (e.g. to diagnose periodic mute toggling that the unit suite can't show).
//

#if DEBUG
import Foundation

enum CallTrace {
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("conduit-call-trace.log")
    }

    static func reset() {
        guard let url else { return }
        try? Data().write(to: url)
    }

    static func record(_ line: String) {
        Log.info(.call, "TRACE \(line)")
        guard let url, let data = "\(line)\n".data(using: .utf8) else { return }
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
