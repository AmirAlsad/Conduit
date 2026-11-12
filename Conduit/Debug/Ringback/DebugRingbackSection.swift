//
//  DebugRingbackSection.swift
//  Conduit
//
//  DEBUG-only Settings section choosing how the next call's ringback is played
//  (see `DebugRingbackMethod`).
//

#if DEBUG
import SwiftUI

struct DebugRingbackSection: View {
    @AppStorage(DebugRingbackMethod.defaultsKey) private var method: DebugRingbackMethod = .systemSound

    var body: some View {
        Section {
            Picker("Ringback", selection: $method) {
                ForEach(DebugRingbackMethod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(AccessibilityID.DebugRingback.picker)
            .onChange(of: method) { _, new in
                CallTrace.record("debug setting: ringback -> \(new.rawValue)")
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Used by the next call you place. The audio player waits for CallKit to activate the call's audio. Each call's timeline is in conduit-call-trace.log in the app's Documents.")
        }
    }
}
#endif
