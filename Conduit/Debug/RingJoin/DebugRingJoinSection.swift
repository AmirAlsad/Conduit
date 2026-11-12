//
//  DebugRingJoinSection.swift
//  Conduit
//
//  DEBUG-only Settings section choosing the Daily ring-join strategy for the
//  next Daily transport (see `DebugDailyRingJoin`).
//

#if DEBUG
import SwiftUI

struct DebugRingJoinSection: View {
    @AppStorage(DebugDailyRingJoin.defaultsKey) private var choice: DebugDailyRingJoin = .off

    var body: some View {
        Section {
            Picker("Daily ring join", selection: $choice) {
                ForEach(DebugDailyRingJoin.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(AccessibilityID.DebugRingJoin.picker)
            .onChange(of: choice) { _, new in
                CallTrace.record("debug setting: daily ring-join -> \(new.rawValue)")
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Used by the next Daily call. A ring joins before the answer only when its push asks for preconnect media. Each call's timeline is in conduit-call-trace.log in the app's Documents.")
        }
    }
}
#endif
