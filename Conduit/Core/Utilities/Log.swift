//
//  Log.swift
//  Conduit
//
//  Centralized logging built on Apple's unified logging (os.Logger).
//
//  Design:
//  - Categories are emoji-prefixed for fast visual scanning of the console.
//  - `debug` / `info` are compiled out of release builds (`#if DEBUG`), so
//    verbose checkpoints stay free in production. `warning` / `error` always log.
//  - Tiny call-site API: `Log.info(.network, "…")`, `Log.error(.callkit, "Failed: \(error)")`.
//  - Pure os.log — no third-party, no analytics, no crash reporting.
//

import Foundation
import OSLog

/// Severity of a log message.
///
/// `debug` and `info` are intended for development checkpoints and are stripped
/// from release builds. `warning` and `error` always emit.
enum LogLevel {
    /// Verbose details (DEBUG builds only).
    case debug
    /// Key checkpoints (DEBUG builds only).
    case info
    /// Recoverable issues (always shown).
    case warning
    /// Failures (always shown).
    case error

    /// The matching `OSLogType` for the unified logging backend.
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// A logging domain with an emoji-prefixed label for fast console scanning.
///
/// The emoji prefix makes a category instantly recognizable when skimming the
/// console; the bracketed name keeps logs greppable.
enum LogCategory: String {
    /// App lifecycle, launch, and global wiring.
    case app = "📱 [App]"
    /// Call session state machine and orchestration.
    case call = "📞 [Call]"
    /// CallKit integration (provider, call controller, system call UI).
    case callkit = "☎️ [CallKit]"
    /// Signaling / transport layer (Pipecat connection, room join/leave).
    case transport = "🔌 [Transport]"
    /// WebRTC peer connection, ICE, and media tracks.
    case webrtc = "📡 [WebRTC]"
    /// Audio session, routing, and playback/capture.
    case audio = "🔊 [Audio]"
    /// Contacts access and the agent address book.
    case contacts = "👤 [Contacts]"
    /// Bring-your-own-agent configuration and behavior.
    case agent = "🤖 [Agent]"
    /// Outbound HTTP / API requests.
    case network = "🌐 [Network]"
    /// View layer, navigation, and user interaction.
    case ui = "🎨 [UI]"
}

/// Centralized logging facade.
///
/// Routes every message through Apple's unified logging system, keyed by
/// `LogCategory`. Call sites stay terse: `Log.info(.transport, "Connected")`.
enum Log {
    /// One `Logger` per category, reused across calls.
    ///
    /// The subsystem groups all Conduit logs together in Console.app; the
    /// category carries the emoji-prefixed label.
    private static let loggers: [LogCategory: Logger] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.conduit.app"
        var map: [LogCategory: Logger] = [:]
        for category in [
            LogCategory.app, .call, .callkit, .transport, .webrtc,
            .audio, .contacts, .agent, .network, .ui,
        ] {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    // MARK: - Core Logging

    /// Logs a verbose detail. Compiled out of release builds.
    static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.debug, category, message())
        #endif
    }

    /// Logs a key checkpoint. Compiled out of release builds.
    static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.info, category, message())
        #endif
    }

    /// Logs a recoverable issue. Always emitted.
    static func warning(_ category: LogCategory, _ message: @autoclosure () -> String) {
        emit(.warning, category, message())
    }

    /// Logs a failure. Always emitted.
    ///
    /// A crash-reporting or analytics hook (intentionally not wired here, per the
    /// pure-os.log decision) could later attach inside this function to forward
    /// errors to an external sink.
    static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        emit(.error, category, message())
    }

    // MARK: - Implementation

    /// Forwards a fully-rendered message to the unified logging backend.
    ///
    /// The message is logged as `public` so it remains readable in Console; do
    /// not pass raw PII (use ``redact(_:chars:)`` and friends for sensitive values).
    private static func emit(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let logger = loggers[category] ?? Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.conduit.app",
            category: category.rawValue
        )
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }

    // MARK: - Privacy Helpers

    /// Truncates a value to a short, non-identifying prefix for safe logging.
    /// - Parameters:
    ///   - value: The sensitive string to redact.
    ///   - chars: How many leading characters to keep before eliding.
    /// - Returns: A redacted representation, or `(nil)` when empty.
    static func redact(_ value: String?, chars: Int = 4) -> String {
        guard let value, !value.isEmpty else { return "(nil)" }
        if value.count <= chars { return "***" }
        return "\(value.prefix(chars))..."
    }

    /// Redacts an email address, keeping a short leading prefix.
    static func redactEmail(_ email: String?) -> String { redact(email, chars: 3) }
}
