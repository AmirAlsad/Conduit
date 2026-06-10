//
//  SiriCallHandler.swift
//  Conduit
//
//  SiriKit calling-domain coverage: "Hey Siri, call <agent>" without the app
//  name, plus the calling domain's special-cased lock-screen/CarPlay handling
//  that plain App Shortcuts don't get (pre-iOS 27 — the .phone.startCall App
//  Intents schema supersedes this eventually). In-app handling, no extension:
//  the system launches the app in the background, resolveContacts maps the
//  spoken name onto our agents via AgentNameMatcher, and handle responds
//  .continueInApp — the system then foregrounds the app and delivers the
//  NSUserActivity, which feeds the same pendingSiriCall funnel as the App
//  Intent (Speakerbox pattern).
//

import Foundation
import Intents

final class SiriCallHandler: NSObject, INStartCallIntentHandling {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func resolveContacts(
        for intent: INStartCallIntent,
        with completion: @escaping ([INStartCallContactResolutionResult]) -> Void
    ) {
        guard let spoken = intent.contacts?.first?.displayName, !spoken.isEmpty else {
            completion([.needsValue()])
            return
        }
        Task { @MainActor in
            let agents = (try? environment.agentRepository.fetchAll()) ?? []
            let candidates = agents.map { AgentNameMatcher.Candidate(id: $0.id, name: $0.name) }
            switch AgentNameMatcher.match(spoken, in: candidates) {
            case .none:
                completion([.unsupported(forReason: .noContactFound)])
            case .unique(let match):
                if let agent = agents.first(where: { $0.id == match.id }) {
                    completion([.success(with: Self.person(for: agent))])
                } else {
                    completion([.unsupported(forReason: .noContactFound)])
                }
            case .ambiguous(let matches):
                let people = matches
                    .compactMap { match in agents.first { $0.id == match.id } }
                    .map(Self.person(for:))
                completion([.disambiguation(with: people)])
            }
        }
    }

    func handle(
        intent: INStartCallIntent,
        completion: @escaping (INStartCallIntentResponse) -> Void
    ) {
        // .continueInApp foregrounds the app and delivers this activity (with the
        // INInteraction attached) to onContinueUserActivity in ConduitApp, which
        // sets pendingSiriCall — the dial itself waits for the .active scene.
        let activity = NSUserActivity(activityType: NSStringFromClass(INStartCallIntent.self))
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }

    /// The handle matches the contact mirror's synthetic email so Siri shows the
    /// agent's contact card (name/photo); customIdentifier carries our UUID back.
    static func person(for agent: Agent) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: agent.syntheticEmail, type: .emailAddress),
            nameComponents: nil,
            displayName: agent.name,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: agent.id.uuidString
        )
    }
}
