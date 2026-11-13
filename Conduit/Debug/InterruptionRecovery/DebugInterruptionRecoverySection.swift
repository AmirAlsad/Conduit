//
//  DebugInterruptionRecoverySection.swift
//  Conduit
//
//  DEBUG-only Settings section choosing, per layer, the experimental recovery to
//  try when a phone call has interrupted a call (see `DebugInterruptionRecovery`).
//

#if DEBUG
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngine
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineDaily
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineLiveKit
import SwiftUI

struct DebugInterruptionRecoverySection: View {
    @AppStorage(DebugInterruptionRecovery.sessionKey) private var session: SessionInterruptionRecovery = .off
    @AppStorage(DebugInterruptionRecovery.liveKitKey) private var liveKit: LiveKitInterruptionRecovery = .off
    @AppStorage(DebugInterruptionRecovery.dailyKey) private var daily: DailyInterruptionRecovery = .off

    var body: some View {
        Section {
            Picker("Session", selection: $session) {
                ForEach(SessionInterruptionRecovery.allCases, id: \.self) { Text($0.debugTitle).tag($0) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(AccessibilityID.DebugInterruptionRecovery.sessionPicker)

            Picker("LiveKit", selection: $liveKit) {
                ForEach(LiveKitInterruptionRecovery.allCases, id: \.self) { Text($0.debugTitle).tag($0) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(AccessibilityID.DebugInterruptionRecovery.liveKitPicker)

            Picker("Daily", selection: $daily) {
                ForEach(DailyInterruptionRecovery.allCases, id: \.self) { Text($0.debugTitle).tag($0) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier(AccessibilityID.DebugInterruptionRecovery.dailyPicker)
        } header: {
            Text("Debug: audio after interruption")
        } footer: {
            Text("Tried when a call resumes after a phone call. The session choice applies at once; the LiveKit and Daily choices to the next call. Each call's timeline is in conduit-call-trace.log in the app's Documents.")
        }
        .onChange(of: session) { _, new in CallTrace.record("debug setting: interruption recovery session -> \(new.rawValue)") }
        .onChange(of: liveKit) { _, new in CallTrace.record("debug setting: interruption recovery livekit -> \(new.rawValue)") }
        .onChange(of: daily) { _, new in CallTrace.record("debug setting: interruption recovery daily -> \(new.rawValue)") }
    }
}
#endif
