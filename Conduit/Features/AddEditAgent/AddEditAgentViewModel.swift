//
//  AddEditAgentViewModel.swift
//  Conduit
//
//  Form logic for adding or editing a bring-your-own-agent. Holds the editable
//  fields, validates the connection URL, persists via the repository, syncs the
//  optional contacts mirror, and runs a one-shot test connection.
//
//  TOKEN INVARIANT: the connection token lives only in the Keychain. It is never
//  written to the `Agent`, never persisted in SwiftData, and never logged.
//

import Foundation

@MainActor
@Observable
final class AddEditAgentViewModel {
    var name: String
    var detail: String
    var transportKind: TransportKind = .daily
    var connectionURLText: String
    var token: String
    var pairingEndpointText: String
    var pairingAgentID = ""
    var mirrorsToContacts: Bool = false
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
    private let contacts: ContactsMirroring
    private let transportFactory: (TransportKind) -> Transport

    init(
        editing agent: Agent? = nil,
        repository: AgentRepository,
        keychain: KeychainStoring,
        contacts: ContactsMirroring,
        transportFactory: @escaping (TransportKind) -> Transport
    ) {
        self.editingAgent = agent
        self.repository = repository
        self.keychain = keychain
        self.contacts = contacts
        self.transportFactory = transportFactory

        if let agent {
            self.name = agent.name
            self.detail = agent.detail
            self.transportKind = agent.transportKind
            self.connectionURLText = agent.connectionURL?.absoluteString ?? ""
            self.pairingEndpointText = agent.pairingEndpoint?.absoluteString ?? ""
            self.pairingAgentID = agent.pairingAgentID ?? ""
            self.mirrorsToContacts = agent.mirrorsToContacts
            self.avatarData = agent.avatarData
            self.token = (try? keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef))).flatMap { $0 } ?? ""
        } else {
            self.name = ""
            self.detail = ""
            self.connectionURLText = ""
            self.pairingEndpointText = ""
            self.token = ""
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

    var canSave: Bool {
        !name.trimmed.isEmpty && (connectionURL != nil || pairingEndpoint != nil)
    }

    // MARK: - Save

    func save() async throws {
        guard connectionURL != nil || pairingEndpoint != nil else { return }
        let agentID = pairingAgentID.trimmed.isEmpty ? nil : pairingAgentID.trimmed

        let agent: Agent
        if let editingAgent {
            agent = editingAgent
            agent.name = name.trimmed
            agent.detail = detail.trimmed
            agent.avatarData = avatarData
            agent.transportKindRaw = transportKind.rawValue
            agent.connectionURL = connectionURL
            agent.pairingEndpoint = pairingEndpoint
            agent.pairingAgentID = agentID
            agent.mirrorsToContacts = mirrorsToContacts
        } else {
            agent = Agent(
                name: name.trimmed,
                detail: detail.trimmed,
                avatarData: avatarData,
                transportKind: transportKind,
                connectionURL: connectionURL,
                pairingEndpoint: pairingEndpoint,
                pairingAgentID: agentID,
                mirrorsToContacts: mirrorsToContacts
            )
            repository.insert(agent)
        }

        let ref = KeychainTokenRef(account: agent.keychainTokenRef)
        if token.isEmpty {
            try? keychain.deleteToken(for: ref)
        } else {
            try keychain.setToken(token, for: ref)
        }

        try repository.save()

        await syncMirror(for: agent)
    }

    private func syncMirror(for agent: Agent) async {
        if mirrorsToContacts {
            if contacts.authorizationStatus() == .notDetermined {
                _ = await contacts.requestAccess()
            }
            let status = contacts.authorizationStatus()
            guard status == .authorized || status == .limited else { return }
            try? await contacts.upsertMirror(
                for: AgentMirrorInfo(
                    id: agent.id,
                    displayName: agent.name,
                    avatarData: agent.avatarData,
                    syntheticEmail: agent.syntheticEmail
                )
            )
        } else {
            try? await contacts.removeMirror(agentID: agent.id)
        }
    }

    // MARK: - Test connection

    private enum TestResult {
        case success
        case failure(String)
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
            token: token,
            pairingEndpoint: pairingEndpoint,
            pairingAgentID: pairingAgentID.trimmed.isEmpty ? nil : pairingAgentID.trimmed
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
