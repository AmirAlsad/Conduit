//
//  CallProviderDelegate.swift
//  Conduit
//
//  The system → app direction of the CallKit seam. The coordinator conforms to
//  this; the provider calls it. `providerDidActivate` is the audio-session
//  ownership boundary — the one place media may attach.
//

import Foundation

@MainActor
protocol CallProviderDelegate: AnyObject {
    /// CallKit activated the audio session. The coordinator attaches media here
    /// (and nowhere else) and sets the hands-free default route.
    func providerDidActivate(_ audioSession: AudioSessionActivating)
    /// CallKit deactivated the audio session. The coordinator detaches media.
    func providerDidDeactivate(_ audioSession: AudioSessionActivating)
    /// The user answered an agent-initiated incoming call from the system UI.
    func providerPerformAnswerCall(_ id: UUID)
    /// The user ended the call from the system UI (lock screen, CarPlay). Also the
    /// decline path for an incoming call that's still ringing.
    func providerPerformEndCall(_ id: UUID)
    /// The user toggled mute from the system UI.
    func providerPerformSetMuted(_ id: UUID, muted: Bool)
    /// The system reset the provider; tear everything down defensively.
    func providerWasReset()
}
