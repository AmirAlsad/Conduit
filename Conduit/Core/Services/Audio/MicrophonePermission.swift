//
//  MicrophonePermission.swift
//  Conduit
//
//  The seam over record permission. Neither the engine nor the transport SDKs
//  prompt reliably (LiveKit 2.17+ never prompts on its own, and refuses to unless
//  the app is active), so a first call answered from the lock screen on an
//  undecided install would have no mic. The app asks itself, in the foreground,
//  where a call is about to start or has just been allowed to come in.
//

import AVFAudio
import UIKit

enum MicrophonePermissionStatus: Equatable {
    case undetermined
    case granted
    case denied
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    var status: MicrophonePermissionStatus { get }
    /// Prompts when undecided. Returns whether the app may record.
    func requestAccess() async -> Bool
}

@MainActor
final class SystemMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    func requestAccess() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            // The prompt makes the app inactive, and its answer can arrive before the
            // app is active again; CallKit refuses a call started from an inactive app.
            await Self.untilActive(timeout: .seconds(2))
            return granted
        }
    }

    private static func untilActive(timeout: Duration) async {
        guard UIApplication.shared.applicationState != .active else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    return
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}

@MainActor
final class FakeMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    /// What the user picks when prompted.
    var answersPrompt: Bool
    private(set) var promptCount = 0

    init(status: MicrophonePermissionStatus = .granted, answersPrompt: Bool = true) {
        self.status = status
        self.answersPrompt = answersPrompt
    }

    func requestAccess() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            promptCount += 1
            status = answersPrompt ? .granted : .denied
            return answersPrompt
        }
    }
}
