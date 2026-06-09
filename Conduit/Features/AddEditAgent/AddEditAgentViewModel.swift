//
//  AddEditAgentViewModel.swift
//  Conduit
//
//  Form logic for adding or editing a bring-your-own-agent. Holds the editable
//  fields, validates the connection URL, persists via the repository, and runs a
//  one-shot test connection.
//
//  Pairing and direct mode each carry their own secret (the pairing API key and the
//  direct-room token), stored under separate Keychain refs so an agent can hold both.
//
//  TOKEN INVARIANT: secrets live only in the Keychain. They are never written to the
//  `Agent`, never persisted in SwiftData, and never logged.
//

import Foundation

@MainActor
@Observable
final class AddEditAgentViewModel {
    var name: String
    var detail: String
    var transportKind: TransportKind = .daily
    var connectionURLText: String
    var apiKey: String
    var directToken: String
    var pairingEndpointText: String
    var inboundEnabled: Bool
    var inboundRegistrationURLText: String
    var avatarData: Data? = nil

    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private(set) var testState: TestState = .idle

    private let editingAgent: Agent?
    private let repository: AgentRepository
    private let keychain: KeychainStoring
    private let contactSync: ContactSyncing
    private let transportFactory: (TransportKind) -> Transport

    init(
        editing agent: Agent? = nil,
        repository: AgentRepository,
        keychain: KeychainStoring,
        contactSync: ContactSyncing,
        transportFactory: @escaping (TransportKind) -> Transport
    ) {
        self.editingAgent = agent
        self.repository = repository
        self.keychain = keychain
        self.contactSync = contactSync
        self.transportFactory = transportFactory

        if let agent {
            self.name = agent.name
            self.detail = agent.detail
            self.transportKind = agent.transportKind
            self.connectionURLText = agent.connectionURL?.absoluteString ?? ""
            self.pairingEndpointText = agent.pairingEndpoint?.absoluteString ?? ""
            self.inboundEnabled = agent.inboundRegistrationURL != nil
            self.inboundRegistrationURLText = agent.inboundRegistrationURL?.absoluteString ?? ""
            self.avatarData = agent.avatarData
            self.apiKey = (try? keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef))).flatMap { $0 } ?? ""
            self.directToken = (try? keychain.token(for: KeychainTokenRef(directTokenForAgentID: agent.id))).flatMap { $0 } ?? ""
        } else {
            self.name = ""
            self.detail = ""
            self.connectionURLText = ""
            self.pairingEndpointText = ""
            self.inboundEnabled = false
            self.inboundRegistrationURLText = ""
            self.apiKey = ""
            self.directToken = ""
        }
    }

    var isEditing: Bool { editingAgent != nil }

    private static let allowedSchemes: Set<String> = ["http", "https", "ws", "wss"]

    var connectionURL: URL? {
        let trimmed = connectionURLText.trimmed
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    var pairingEndpoint: URL? {
        let trimmed = pairingEndpointText.trimmed
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// The endpoint the device's VoIP token is registered with, when inbound calls
    /// are enabled. `nil` disables inbound for this agent.
    var inboundRegistrationURL: URL? {
        guard inboundEnabled else { return nil }
        let trimmed = inboundRegistrationURLText.trimmed
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// Default the registration URL from the pairing endpoint the first time inbound
    /// is enabled (both usually point at the same server), leaving it editable.
    func prefillInboundURLIfNeeded() {
        guard inboundRegistrationURLText.trimmed.isEmpty else { return }
        inboundRegistrationURLText = pairingEndpointText
    }

    var canSave: Bool {
        !name.trimmed.isEmpty && (connectionURL != nil || pairingEndpoint != nil)
    }

    // MARK: - Save

    func save() async throws {
        guard connectionURL != nil || pairingEndpoint != nil else { return }

        let agent: Agent
        if let editingAgent {
            agent = editingAgent
            agent.name = name.trimmed
            agent.detail = detail.trimmed
            agent.avatarData = avatarData
            agent.transportKindRaw = transportKind.rawValue
            agent.connectionURL = connectionURL
            agent.pairingEndpoint = pairingEndpoint
            agent.inboundRegistrationURL = inboundRegistrationURL
        } else {
            agent = Agent(
                name: name.trimmed,
                detail: detail.trimmed,
                avatarData: avatarData,
                transportKind: transportKind,
                connectionURL: connectionURL,
                pairingEndpoint: pairingEndpoint,
                inboundRegistrationURL: inboundRegistrationURL
            )
            repository.insert(agent)
        }

        try persistSecret(apiKey, to: KeychainTokenRef(account: agent.keychainTokenRef))
        try persistSecret(directToken, to: KeychainTokenRef(directTokenForAgentID: agent.id))

        try repository.save()

        // Keep an already-linked contact in step with the agent (name + photo).
        // No-op for unlinked agents, so the default stays permission-free.
        if let identifier = agent.contactIdentifier {
            _ = await contactSync.sync(
                AgentMirrorInfo(
                    id: agent.id,
                    displayName: agent.name,
                    avatarData: agent.avatarData,
                    syntheticEmail: agent.syntheticEmail
                ),
                contactIdentifier: identifier
            )
        }
    }

    private func persistSecret(_ value: String, to ref: KeychainTokenRef) throws {
        if value.isEmpty {
            try? keychain.deleteToken(for: ref)
        } else {
            try keychain.setToken(value, for: ref)
        }
    }

    // MARK: - Test connection

    private enum TestResult {
        case success
        case failure(String)
    }

    /// The secret for the path under test — pairing wins when both are configured,
    /// matching how a real call resolves it.
    private var activeSecret: String {
        pairingEndpoint != nil ? apiKey : directToken
    }

    func testConnection() async {
        guard connectionURL != nil || pairingEndpoint != nil else {
            testState = .failure("Enter a connection URL or pairing endpoint")
            return
        }

        testState = .testing

        let config = TransportConfig(
            kind: transportKind,
            url: connectionURL,
            token: activeSecret,
            pairingEndpoint: pairingEndpoint
        )
        let transport = transportFactory(transportKind)

        do {
            try await transport.connect(config)
        } catch {
            Log.warning(.transport, "Test connection failed to start: \(error)")
            let message = (error as? TransportError) == .authenticationFailed
                ? "Authentication failed" : "Couldn't reach the agent"
            testState = .failure(message)
            await transport.disconnect()
            return
        }

        let result = await withTaskGroup(of: TestResult.self) { group -> TestResult in
            group.addTask {
                for await event in transport.events {
                    switch event {
                    case .connected:
                        return .success
                    case .error(.authenticationFailed), .disconnected(reason: .authFailed):
                        return .failure("Authentication failed")
                    case .error:
                        return .failure("Connection error")
                    case .disconnected:
                        return .failure("Disconnected")
                    default:
                        continue
                    }
                }
                return .failure("Disconnected")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .failure("Timed out")
            }

            let first = await group.next() ?? .failure("Connection error")
            group.cancelAll()
            return first
        }

        await transport.disconnect()

        switch result {
        case .success:
            testState = .success
        case .failure(let message):
            testState = .failure(message)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
