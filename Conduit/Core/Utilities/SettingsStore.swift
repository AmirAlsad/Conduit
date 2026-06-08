//
//  SettingsStore.swift
//  Conduit
//
//  Keys for the handful of user preferences kept in `UserDefaults` (via
//  `@AppStorage` in Settings). Shared so the Settings UI and `AppEnvironment`
//  (which feeds the coordinator) agree on the exact key.
//

import Foundation

enum SettingsStore {
    /// When true, the mic opens only while the in-call button is held
    /// (push-to-talk); otherwise the agent is always listening during a call.
    static let pushToTalkKey = "settings.pushToTalk"
}
