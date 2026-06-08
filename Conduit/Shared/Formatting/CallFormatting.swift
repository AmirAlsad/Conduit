//
//  CallFormatting.swift
//  Conduit
//
//  Small formatting helpers shared by call-history rows and the in-call timer.
//

import Foundation

enum CallFormatting {
    /// Connected duration as `m:ss` (e.g. `3:07`).
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A relative, human date for a log row (e.g. "yesterday", "2 weeks ago").
    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
