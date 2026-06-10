//
//  SiriCallHandlerTests.swift
//  ConduitTests
//
//  SiriKit contact resolution against the agent list: unique spoken names
//  succeed with the agent's identity wired into the INPerson, ties surface as
//  disambiguation, unknown names are unsupported.
//

import Foundation
import Intents
import Testing
@testable import Conduit

@MainActor
struct SiriCallHandlerTests {

    private func makeEnvironment(agentNames: [String]) throws -> (AppEnvironment, [Agent]) {
        let environment = AppEnvironment.inMemory()
        var agents: [Agent] = []
        for name in agentNames {
            let agent = Agent(name: name, transportKind: .daily)
            environment.agentRepository.insert(agent)
            agents.append(agent)
        }
        try environment.agentRepository.save()
        return (environment, agents)
    }

    private func intent(spokenName: String) -> INStartCallIntent {
        INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [
                INPerson(
                    personHandle: INPersonHandle(value: nil, type: .unknown),
                    nameComponents: nil,
                    displayName: spokenName,
                    image: nil,
                    contactIdentifier: nil,
                    customIdentifier: nil
                )
            ],
            callCapability: .audioCall
        )
    }

    private func resolve(
        _ handler: SiriCallHandler, spokenName: String
    ) async -> [INStartCallContactResolutionResult] {
        await withCheckedContinuation { continuation in
            handler.resolveContacts(for: intent(spokenName: spokenName)) { results in
                continuation.resume(returning: results)
            }
        }
    }

    @Test func uniqueNameResolvesWithAgentIdentity() async throws {
        let (environment, agents) = try makeEnvironment(agentNames: ["Marvin"])
        let handler = SiriCallHandler(environment: environment)

        let results = await resolve(handler, spokenName: "Marvin")
        let result = try #require(results.first)
        // The resolution case isn't exposed as API; assert on the description,
        // which carries the code and the resolved INPerson's fields.
        let description = String(describing: result)
        #expect(description.contains("resolutionResultCode = Success"))
        #expect(description.contains(agents[0].id.uuidString))
        #expect(description.contains(agents[0].syntheticEmail))
    }

    @Test func ambiguousNamesAskForDisambiguation() async throws {
        let (environment, _) = try makeEnvironment(agentNames: ["Marvin Home", "Marvin Work"])
        let handler = SiriCallHandler(environment: environment)

        let results = await resolve(handler, spokenName: "Marvin")
        let result = try #require(results.first)
        #expect(String(describing: result).lowercased().contains("disambiguation"))
    }

    @Test func unknownNameIsUnsupported() async throws {
        let (environment, _) = try makeEnvironment(agentNames: ["Marvin"])
        let handler = SiriCallHandler(environment: environment)

        let results = await resolve(handler, spokenName: "Jarvis")
        let result = try #require(results.first)
        #expect(String(describing: result).lowercased().contains("unsupported"))
    }

    @Test func handleContinuesInApp() async throws {
        let (environment, _) = try makeEnvironment(agentNames: ["Marvin"])
        let handler = SiriCallHandler(environment: environment)

        let response: INStartCallIntentResponse = await withCheckedContinuation { continuation in
            handler.handle(intent: intent(spokenName: "Marvin")) { response in
                continuation.resume(returning: response)
            }
        }
        #expect(response.code == .continueInApp)
        #expect(response.userActivity?.activityType == NSStringFromClass(INStartCallIntent.self))
    }

    @Test func handleCarriesAgentIDInUserInfo() async throws {
        let (environment, agents) = try makeEnvironment(agentNames: ["Marvin"])
        let handler = SiriCallHandler(environment: environment)
        // A post-resolution intent: the contact is OUR person, identifier set.
        let resolved = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [SiriCallHandler.person(for: agents[0])],
            callCapability: .audioCall
        )

        let response: INStartCallIntentResponse = await withCheckedContinuation { continuation in
            handler.handle(intent: resolved) { continuation.resume(returning: $0) }
        }
        let stored = response.userActivity?.userInfo?[SiriCallHandler.agentIDUserInfoKey] as? String
        #expect(stored == agents[0].id.uuidString)
    }
}
