//
//  CallInterruptionTests.swift
//  ConduitTests
//
//  Audio-interruption handling: a transient takeover (Siri, navigation, a phone
//  call) pauses the mic while interrupted and re-applies the correct mic state on
//  resume — respecting mute and push-to-talk. Driven through the fake observer at
//  simulator speed; the live audio behavior is device-only.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallInterruptionTests {

    /// Place + connect + activate so the mic is live before the interruption.
    private func connectedCall(pushToTalk: Bool = false) async throws -> CoordinatorHarness {
        let h = try CoordinatorHarness(pushToTalk: pushToTalk)
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        await h.coordinator.activate(FakeAudioSession(hasExternalAudioRoute: false))
        return h
    }

    @Test func observingStartsOnPlaceCallAndStopsOnEnd() async throws {
        let h = try CoordinatorHarness()
        #expect(!h.interruption.isObserving)

        await h.coordinator.placeCall(h.agent)
        #expect(h.interruption.isObserving)

        await h.coordinator.endCall()
        #expect(!h.interruption.isObserving)
    }

    @Test func interruptionBeganPausesMic() async throws {
        let h = try await connectedCall()
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateBegan()

        #expect(h.coordinator.isInterrupted)
        await waitUntil { !h.transport.isMicEnabled }
        #expect(!h.transport.isMicEnabled)
    }

    @Test func interruptionEndedWithResumeReenablesMic() async throws {
        let h = try await connectedCall()
        h.interruption.simulateBegan()
        await waitUntil { !h.transport.isMicEnabled }

        h.interruption.simulateEnded(shouldResume: true)

        #expect(!h.coordinator.isInterrupted)
        await waitUntil { h.transport.isMicEnabled }
        #expect(h.transport.isMicEnabled)
    }

    @Test func interruptionEndedWithoutResumeStaysPaused() async throws {
        let h = try await connectedCall()
        h.interruption.simulateBegan()
        await waitUntil { !h.transport.isMicEnabled }

        h.interruption.simulateEnded(shouldResume: false)

        #expect(!h.coordinator.isInterrupted)
        #expect(!h.transport.isMicEnabled) // not auto-resumed
    }

    @Test func resumeRespectsMute() async throws {
        let h = try await connectedCall()
        await h.coordinator.setMuted(true)
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)

        // Yield for the async re-apply, then confirm mute survived the interruption.
        await waitUntil { !h.coordinator.isInterrupted }
        #expect(h.coordinator.isMuted)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func resumeKeepsMicOffInPushToTalk() async throws {
        let h = try await connectedCall(pushToTalk: true)
        #expect(!h.transport.isMicEnabled) // PTT holds the mic closed

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)

        await waitUntil { !h.coordinator.isInterrupted }
        #expect(!h.transport.isMicEnabled)
    }

    @Test func endedWithoutBeganIsIgnored() async throws {
        let h = try await connectedCall()
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true) // no preceding interruption

        #expect(!h.coordinator.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }
}
