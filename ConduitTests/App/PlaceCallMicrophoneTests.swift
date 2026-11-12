//
//  PlaceCallMicrophoneTests.swift
//  ConduitTests
//
//  Placing a call asks for the microphone first, and never places a call the
//  agent could not hear: without access it records why, for the root view to
//  explain, and leaves the engine idle.
//

import Foundation
import Testing
@testable import Conduit
import ConduitCallEngine

@MainActor
struct PlaceCallMicrophoneTests {

    private func environment(
        _ microphone: FakeMicrophonePermission
    ) throws -> (AppEnvironment, Agent) {
        let environment = AppEnvironment.inMemory(microphone: microphone)
        let agent = Agent(
            name: "Nova",
            transportKind: .daily,
            connectionURL: URL(string: "https://example.daily.co/room")!
        )
        environment.agentRepository.insert(agent)
        try environment.agentRepository.save()
        return (environment, agent)
    }

    @Test func grantedPlacesTheCallWithoutPrompting() async throws {
        let microphone = FakeMicrophonePermission(status: .granted)
        let (environment, agent) = try environment(microphone)

        await environment.placeCall(agent)

        #expect(environment.callEngine.state.isActive)
        #expect(environment.callRefusedForMicrophone == nil)
        #expect(microphone.promptCount == 0)
    }

    @Test func undecidedPromptsThenPlacesWhenAllowed() async throws {
        let microphone = FakeMicrophonePermission(status: .undetermined, answersPrompt: true)
        let (environment, agent) = try environment(microphone)

        await environment.placeCall(agent)

        #expect(microphone.promptCount == 1)
        #expect(environment.callEngine.state.isActive)
        #expect(environment.callRefusedForMicrophone == nil)
    }

    /// Denied earlier, or denied at the prompt this call raised.
    @Test(arguments: [MicrophonePermissionStatus.denied, .undetermined])
    func withoutAccessNoCallIsPlacedAndTheRefusalIsRecorded(status: MicrophonePermissionStatus) async throws {
        let microphone = FakeMicrophonePermission(status: status, answersPrompt: false)
        let (environment, agent) = try environment(microphone)

        await environment.placeCall(agent)

        #expect(environment.callEngine.state == .idle)
        #expect(environment.callRefusedForMicrophone == "Nova")
    }
}
