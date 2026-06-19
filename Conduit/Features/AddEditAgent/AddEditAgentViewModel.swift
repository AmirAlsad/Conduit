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
    /// The user's explicit color pick, or `nil` while it should track the typed
    /// name (a fresh add, untouched). Frozen on edit — loaded as a concrete value
    /// so renaming an existing agent never re-rolls its color.
    var selectedColor: AgentColor? = nil

    /// The color shown and saved: the explicit pick, else the name-derived slot.
    var effectiveColor: AgentColor { selectedColor ?? .derived(forName: name) }

    enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private(set) var testState: TestState = .idle
    /// The staged "Test connection" checklist (empty until the first run).
    private(set) var diagnosticSteps: [DiagnosticStep] = []

    private let editingAgent: Agent?
    private let repository: AgentRepository
    private let keychain: KeychainStoring
    private let contactSync: ContactSyncing
    private let transportFactory: (TransportKind) -> Transport
    private let inboundRegistrar: InboundRegistering?
    private let pairingResolver: @Sendable (URL, String, TransportKind) async throws -> PairingCredentials

    init(
        editing agent: Agent? = nil,
        repository: AgentRepository,
        keychain: KeychainStoring,
        contactSync: ContactSyncing,
        transportFactory: @escaping (TransportKind) -> Transport,
        inboundRegistrar: InboundRegistering? = nil,
        pairingResolver: @escaping @Sendable (URL, String, TransportKind) async throws -> PairingCredentials = {
            try await PairingClient.resolve(endpoint: $0, apiKey: $1, transport: $2)
        }
    ) {
        self.editingAgent = agent
        self.repository = repository
        self.keychain = keychain
        self.contactSync = contactSync
        self.transportFactory = transportFactory
        self.inboundRegistrar = inboundRegistrar
        self.pairingResolver = pairingResolver

        if let agent {
            self.name = agent.name
            self.detail = agent.detail
            self.transportKind = agent.transportKind
            self.connectionURLText = agent.connectionURL?.absoluteString ?? ""
            self.pairingEndpointText = agent.pairingEndpoint?.absoluteString ?? ""
            self.inboundEnabled = agent.inboundRegistrationURL != nil
            self.inboundRegistrationURLText = agent.inboundRegistrationURL?.absoluteString ?? ""
            self.avatarData = agent.avatarData
            self.selectedColor = agent.paletteColor
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

    /// Layer a conduit:// link's values over the form (a blank add, or an
    /// existing agent being updated by a re-scan). A link without a key keeps
    /// whatever key is already loaded, so re-pairing never wipes a secret —
    /// and on a re-scan the link refreshes CONNECTION details only: the name
    /// is the user's customization, not the server's to overwrite.
    func apply(_ link: AgentDeepLink) {
        if editingAgent == nil { name = link.name }
        transportKind = link.transport
        pairingEndpointText = link.pairingEndpoint.absoluteString
        if let key = link.apiKey { apiKey = key }
        if let inbound = link.inboundRegistrationURL {
            inboundEnabled = true
            inboundRegistrationURLText = inbound.absoluteString
        }
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
            agent.colorTokenRaw = effectiveColor.rawValue
            agent.transportKindRaw = transportKind.rawValue
            agent.connectionURL = connectionURL
            agent.pairingEndpoint = pairingEndpoint
            agent.inboundRegistrationURL = inboundRegistrationURL
        } else {
            agent = Agent(
                name: name.trimmed,
                detail: detail.trimmed,
                avatarData: avatarData,
                colorToken: effectiveColor,
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
        ConduitAppShortcuts.refreshParameters()

        // Register the VoIP token now (not just on the next launch) so inbound works
        // the moment the toggle is saved. Fire-and-forget: a slow endpoint must not
        // hold the sheet open, and the launch-time pass self-heals any failure.
        if agent.inboundRegistrationURL != nil, let inboundRegistrar {
            Task { await inboundRegistrar.registerInbound(for: agent) }
        }

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

    // MARK: - Test connection (staged diagnostics)
    //
    // The VM sequences the stages itself: pairing is resolved here (not inside the
    // transport adapter, which does its own pairing on a real call) so a failure
    // names the step that broke. Bounded divergence — both paths share
    // PairingClient and then connect with the same room URL + token.

    private enum TestResult {
        case success
        case authFailure
        case failure(String)
        case timeout
    }

    func testConnection() async {
        guard connectionURL != nil || pairingEndpoint != nil else {
            testState = .failure("Enter a connection URL or pairing endpoint")
            return
        }

        testState = .testing
        diagnosticSteps = (pairingEndpoint != nil
            ? [DiagnosticStage.pairing, .credentials, .transport, .ready]
            : [.transport, .ready]
        ).map { DiagnosticStep(stage: $0) }

        var roomURL = connectionURL
        var token = directToken

        if let endpoint = pairingEndpoint {
            setStatus(.running, for: .pairing)
            do {
                let creds = try await resolvePairing(endpoint)
                setStatus(.passed, for: .pairing)
                setStatus(.passed, for: .credentials)
                roomURL = creds.roomURL
                token = creds.token
            } catch PairingError.missingCredentials {
                setStatus(.passed, for: .pairing)
                failDiagnostics(at: .credentials, message: "Response missing room URL or token")
                return
            } catch {
                Log.warning(.transport, "Test connection pairing failed: \(error)")
                failDiagnostics(at: .pairing, message: Self.pairingFailureMessage(error, endpoint: endpoint))
                return
            }
        }

        setStatus(.running, for: .transport)
        let transport = transportFactory(transportKind)
        do {
            try await transport.connect(TransportConfig(kind: transportKind, url: roomURL, token: token))
        } catch {
            Log.warning(.transport, "Test connection failed to start: \(error)")
            let message = (error as? TransportError) == .authenticationFailed
                ? "Room token rejected"
                : "Couldn't negotiate the \(transportKind.displayName) connection"
            failDiagnostics(at: .transport, message: message)
            await transport.disconnect()
            return
        }
        setStatus(.passed, for: .transport)
        setStatus(.running, for: .ready)

        let result = await withTaskGroup(of: TestResult.self) { group -> TestResult in
            group.addTask {
                for await event in transport.events {
                    switch event {
                    case .connected:
                        return .success
                    case .error(.authenticationFailed), .disconnected(reason: .authFailed):
                        return .authFailure
                    case .error:
                        return .failure("Connected, but the agent never became ready — is the bot running?")
                    case .disconnected:
                        return .failure("Disconnected before the agent was ready")
                    default:
                        continue
                    }
                }
                return .failure("Disconnected before the agent was ready")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .timeout
            }

            let first = await group.next() ?? .failure("Connection error")
            group.cancelAll()
            return first
        }

        await transport.disconnect()

        switch result {
        case .success:
            setStatus(.passed, for: .ready)
            testState = .success
        case .authFailure:
            // The room rejected the token after the join started — a transport-
            // stage fact discovered late; report it on that stage.
            setStatus(.pending, for: .ready)
            failDiagnostics(at: .transport, message: "Room token rejected")
        case .failure(let message):
            failDiagnostics(at: .ready, message: message)
        case .timeout:
            failDiagnostics(at: .ready, message: "Timed out after 20 seconds waiting for the agent")
        }
    }

    private func setStatus(_ status: DiagnosticStatus, for stage: DiagnosticStage) {
        guard let index = diagnosticSteps.firstIndex(where: { $0.stage == stage }) else { return }
        diagnosticSteps[index].status = status
    }

    private func failDiagnostics(at stage: DiagnosticStage, message: String) {
        setStatus(.failed(message), for: stage)
        testState = .failure(message)
    }

    /// Race the pairing resolve against its own timeout so a hung endpoint fails
    /// in 10 s instead of URLSession's 60 s default.
    private func resolvePairing(_ endpoint: URL) async throws -> PairingCredentials {
        let resolver = pairingResolver
        let key = apiKey
        let kind = transportKind
        return try await withThrowingTaskGroup(of: PairingCredentials.self) { group in
            group.addTask { try await resolver(endpoint, key, kind) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { throw PairingError.invalidResponse }
            group.cancelAll()
            return first
        }
    }

    private static func pairingFailureMessage(_ error: Error, endpoint: URL) -> String {
        switch error {
        case PairingError.unauthorized:
            return "API key rejected (401) — check it matches your server's key"
        case PairingError.server(let code):
            return "Server error (HTTP \(code))"
        case PairingError.invalidResponse:
            return "Endpoint didn't return JSON — is this the right URL?"
        case let urlError as URLError where urlError.code == .timedOut:
            return "Timed out reaching \(endpoint.host() ?? "the endpoint")"
        default:
            return "Couldn't reach \(endpoint.host() ?? "the endpoint")"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
