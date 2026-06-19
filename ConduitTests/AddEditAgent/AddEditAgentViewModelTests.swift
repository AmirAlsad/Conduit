//
//  AddEditAgentViewModelTests.swift
//  ConduitTests
//
//  The bring-your-own-agent form logic against fakes: validation, persistence
//  (token to Keychain, never on the agent), edit identity-stability, and the
//  test-connection state machine.
//

import Foundation
import SwiftData
import Testing
@testable import Conduit

@MainActor
struct AddEditAgentViewModelTests {
    private func makeRepository() throws -> SwiftDataAgentRepository {
        let container = try ModelContainer(
            for: Agent.self, CallLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // A fresh ModelContext retains its container; `container.mainContext` does
        // not, so the container would deallocate and the context dangle on save.
        return SwiftDataAgentRepository(context: ModelContext(container))
    }

    private func makeViewModel(
        editing agent: Agent? = nil,
        repository: SwiftDataAgentRepository,
        keychain: KeychainStoring = InMemoryKeychain(),
        contactSync: ContactSyncing = FakeContactSync(),
        transportFactory: @escaping (TransportKind) -> Transport = { _ in FakeTransport() },
        inboundRegistrar: InboundRegistering? = nil,
        pairingResolver: @escaping @Sendable (URL, String, TransportKind) async throws -> PairingCredentials = { _, _, _ in
            throw PairingError.invalidResponse
        }
    ) -> AddEditAgentViewModel {
        AddEditAgentViewModel(
            editing: agent,
            repository: repository,
            keychain: keychain,
            contactSync: contactSync,
            transportFactory: transportFactory,
            inboundRegistrar: inboundRegistrar,
            pairingResolver: pairingResolver
        )
    }

    // MARK: - Validation

    @Test func canSaveRequiresNameAndAConnection() throws {
        let vm = makeViewModel(repository: try makeRepository())
        #expect(!vm.canSave)
        vm.name = "Jarvis"
        #expect(!vm.canSave) // no connection method yet
        vm.connectionURLText = "https://x.daily.co/room"
        #expect(vm.canSave) // name + a direct room URL is enough
    }

    @Test func pairingEndpointAloneIsEnough() throws {
        let vm = makeViewModel(repository: try makeRepository())
        vm.name = "Jarvis"
        vm.pairingEndpointText = "https://engine.example.com/connect"
        #expect(vm.canSave) // pairing endpoint, no direct room URL
    }

    @Test func connectionURLValidatesScheme() throws {
        let vm = makeViewModel(repository: try makeRepository())
        vm.connectionURLText = "ftp://example.com"
        #expect(vm.connectionURL == nil)
        vm.connectionURLText = "nonsense"
        #expect(vm.connectionURL == nil)
        vm.connectionURLText = "https://room.daily.co/abc"
        #expect(vm.connectionURL != nil)
        vm.connectionURLText = "wss://host.livekit.cloud"
        #expect(vm.connectionURL != nil)
    }

    // MARK: - Save

    @Test func savingNewAgentInsertsItAndStoresTokenInKeychain() async throws {
        let repo = try makeRepository()
        let keychain = InMemoryKeychain()
        let vm = makeViewModel(repository: repo, keychain: keychain)
        vm.name = "Jarvis"
        vm.detail = "Personal"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "secret-token"

        try await vm.save()

        let agents = try repo.fetchAll()
        #expect(agents.count == 1)
        let agent = try #require(agents.first)
        #expect(agent.name == "Jarvis")
        #expect(agent.detail == "Personal")
        #expect(agent.connectionURL?.absoluteString == "https://x.daily.co/room")
        // The direct token lives ONLY in the Keychain, under the direct-token ref.
        #expect(try keychain.token(for: KeychainTokenRef(directTokenForAgentID: agent.id)) == "secret-token")
    }

    @Test func savingPairingAgentPersistsEndpointAndApiKey() async throws {
        let repo = try makeRepository()
        let keychain = InMemoryKeychain()
        let vm = makeViewModel(repository: repo, keychain: keychain)
        vm.name = "Engine Agent"
        vm.pairingEndpointText = "https://engine.example.com/connect"
        vm.apiKey = "api-key"

        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        #expect(agent.connectionURL == nil)
        #expect(agent.pairingEndpoint?.absoluteString == "https://engine.example.com/connect")
        #expect(try keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef)) == "api-key")
    }

    @Test func bothPathsPersistTheirOwnSecretIndependently() async throws {
        let repo = try makeRepository()
        let keychain = InMemoryKeychain()
        let vm = makeViewModel(repository: repo, keychain: keychain)
        vm.name = "Dual"
        vm.pairingEndpointText = "https://engine.example.com/connect"
        vm.apiKey = "the-api-key"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "the-direct-token"

        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        #expect(try keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef)) == "the-api-key")
        #expect(try keychain.token(for: KeychainTokenRef(directTokenForAgentID: agent.id)) == "the-direct-token")
    }

    @Test func editingKeepsSyntheticIdentityStableAndDoesNotDuplicate() async throws {
        let repo = try makeRepository()
        let agent = Agent(name: "Old Name", transportKind: .daily, connectionURL: URL(string: "https://a.daily.co/r")!)
        repo.insert(agent)
        try repo.save()
        let originalEmail = agent.syntheticEmail
        let originalRef = agent.keychainTokenRef

        let vm = makeViewModel(editing: agent, repository: repo)
        vm.name = "New Name"
        vm.directToken = "tok"
        try await vm.save()

        #expect(agent.name == "New Name")
        #expect(agent.syntheticEmail == originalEmail)
        #expect(agent.keychainTokenRef == originalRef)
        #expect(try repo.fetchAll().count == 1)
    }

    // MARK: - Color selection

    @Test func newAgentColorFollowsTheNameUntilTouched() throws {
        let vm = makeViewModel(repository: try makeRepository())
        vm.name = "Jarvis"
        #expect(vm.selectedColor == nil) // untouched
        #expect(vm.effectiveColor == .derived(forName: "Jarvis"))
        vm.name = "Vision"
        #expect(vm.effectiveColor == .derived(forName: "Vision")) // tracks the name
    }

    @Test func savingNewAgentStampsTheEffectiveColor() async throws {
        let repo = try makeRepository()
        let vm = makeViewModel(repository: repo)
        vm.name = "Jarvis"
        vm.connectionURLText = "https://x.daily.co/room"

        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        #expect(agent.paletteColor == .derived(forName: "Jarvis"))
    }

    @Test func tappingASwatchOverridesTheNameColor() async throws {
        let repo = try makeRepository()
        let vm = makeViewModel(repository: repo)
        vm.name = "Jarvis"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.selectedColor = .pink // user tapped a swatch

        #expect(vm.effectiveColor == .pink)
        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        #expect(agent.paletteColor == .pink)
    }

    @Test func editingLoadsTheStoredColorAndFreezesItOnRename() async throws {
        let repo = try makeRepository()
        let agent = Agent(
            name: "Jarvis", colorToken: .indigo, transportKind: .daily,
            connectionURL: URL(string: "https://a.daily.co/r")!
        )
        repo.insert(agent)
        try repo.save()

        let vm = makeViewModel(editing: agent, repository: repo)
        #expect(vm.selectedColor == .indigo) // loaded as a concrete value
        vm.name = "Vision"
        #expect(vm.effectiveColor == .indigo) // frozen — a rename doesn't re-roll

        try await vm.save()
        #expect(agent.paletteColor == .indigo)
    }

    // MARK: - Deep-link prefill

    @Test func applyingALinkPrefillsTheForm() throws {
        let vm = makeViewModel(repository: try makeRepository())
        vm.apply(AgentDeepLink(
            name: "Live Agent",
            transport: .livekit,
            pairingEndpoint: URL(string: "https://h.example/connect/live")!,
            apiKey: "sk-123",
            inboundRegistrationURL: URL(string: "https://h.example/inbound/register/live")!
        ))

        #expect(vm.name == "Live Agent")
        #expect(vm.transportKind == .livekit)
        #expect(vm.pairingEndpointText == "https://h.example/connect/live")
        #expect(vm.apiKey == "sk-123")
        #expect(vm.inboundEnabled)
        #expect(vm.inboundRegistrationURLText == "https://h.example/inbound/register/live")
        #expect(vm.canSave)
    }

    @Test func linkWithoutKeyPreservesTheExistingKeyOnEdit() async throws {
        let repo = try makeRepository()
        let keychain = InMemoryKeychain()
        let agent = Agent(
            name: "Live", transportKind: .livekit,
            pairingEndpoint: URL(string: "https://h.example/connect/live")!
        )
        repo.insert(agent)
        try repo.save()
        try keychain.setToken("existing-key", for: KeychainTokenRef(account: agent.keychainTokenRef))

        let vm = makeViewModel(editing: agent, repository: repo, keychain: keychain)
        vm.apply(AgentDeepLink(
            name: "Live v2",
            transport: .livekit,
            pairingEndpoint: URL(string: "https://h.example/connect/live")!,
            apiKey: nil,
            inboundRegistrationURL: nil
        ))

        #expect(vm.name == "Live") // a re-scan refreshes connection details, not the user's name
        #expect(vm.apiKey == "existing-key") // a key-less re-scan never wipes the secret
    }

    // MARK: - Inbound registration on save

    @Test func savingWithInboundEnabledRegistersImmediately() async throws {
        let repo = try makeRepository()
        let registrar = FakeInboundRegistrar()
        let vm = makeViewModel(repository: repo, inboundRegistrar: registrar)
        vm.name = "Jarvis"
        vm.pairingEndpointText = "https://engine.example.com/connect"
        vm.inboundEnabled = true
        vm.inboundRegistrationURLText = "https://engine.example.com/inbound/register/live"

        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        await waitUntil { !registrar.registeredAgentIDs.isEmpty }
        #expect(registrar.registeredAgentIDs == [agent.id])
    }

    @Test func savingWithInboundDisabledDoesNotRegister() async throws {
        let repo = try makeRepository()
        let registrar = FakeInboundRegistrar()
        let vm = makeViewModel(repository: repo, inboundRegistrar: registrar)
        vm.name = "Jarvis"
        vm.pairingEndpointText = "https://engine.example.com/connect"

        try await vm.save()

        await waitUntil(ticks: 50) { !registrar.registeredAgentIDs.isEmpty }
        #expect(registrar.registeredAgentIDs.isEmpty)
    }

    // MARK: - Contact sync on save

    @Test func editingALinkedAgentSyncsTheContact() async throws {
        let repo = try makeRepository()
        let agent = Agent(name: "Old Name", transportKind: .daily, connectionURL: URL(string: "https://a.daily.co/r")!)
        agent.contactIdentifier = "contact-123"
        repo.insert(agent)
        try repo.save()

        let sync = FakeContactSync()
        let vm = makeViewModel(editing: agent, repository: repo, contactSync: sync)
        vm.name = "New Name"
        try await vm.save()

        #expect(sync.syncCount == 1)
        #expect(sync.lastSync?.contactIdentifier == "contact-123")
        #expect(sync.lastSync?.info.displayName == "New Name")
    }

    @Test func savingAnUnlinkedAgentDoesNotSync() async throws {
        let repo = try makeRepository()
        let sync = FakeContactSync()
        let vm = makeViewModel(repository: repo, contactSync: sync)
        vm.name = "Echo"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "t"

        try await vm.save()

        #expect(sync.syncCount == 0) // no contact linked → permission-free
    }

    // MARK: - Test connection (staged diagnostics)

    private func status(of stage: DiagnosticStage, in vm: AddEditAgentViewModel) -> DiagnosticStatus? {
        vm.diagnosticSteps.first { $0.stage == stage }?.status
    }

    @Test func directModeShowsTwoStagesAndSucceeds() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "t"

        async let run: Void = vm.testConnection()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(.connected)
        await run

        #expect(vm.testState == .success)
        #expect(vm.diagnosticSteps.map(\.stage) == [.transport, .ready])
        #expect(status(of: .transport, in: vm) == .passed)
        #expect(status(of: .ready, in: vm) == .passed)
        #expect(fake.disconnectCount == 1) // always tears the probe down
    }

    @Test func authEventAfterJoinFailsTheTransportStage() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "bad"

        async let run: Void = vm.testConnection()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(.error(.authenticationFailed))
        await run

        #expect(vm.testState == .failure("Room token rejected"))
        #expect(status(of: .transport, in: vm) == .failed("Room token rejected"))
    }

    @Test func connectThrowingFailsTheTransportStage() async throws {
        let fake = FakeTransport()
        fake.connectError = .timedOut
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.directToken = "t"

        await vm.testConnection()

        #expect(status(of: .transport, in: vm) == .failed("Couldn't negotiate the Daily connection"))
        #expect(status(of: .ready, in: vm) == .pending) // run stopped at the failure
    }

    @Test func pairingResolveDrivesAllFourStages() async throws {
        let fake = FakeTransport()
        let room = URL(string: "https://x.daily.co/minted")!
        let vm = makeViewModel(
            repository: try makeRepository(),
            transportFactory: { _ in fake },
            pairingResolver: { _, _, _ in PairingCredentials(roomURL: room, token: "minted-token") }
        )
        vm.pairingEndpointText = "https://engine.example.com/connect/live"
        vm.apiKey = "key"
        vm.name = "Live"

        async let run: Void = vm.testConnection()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(.connected)
        await run

        #expect(vm.testState == .success)
        #expect(vm.diagnosticSteps.map(\.stage) == [.pairing, .credentials, .transport, .ready])
        #expect(vm.diagnosticSteps.allSatisfy { $0.status == .passed })
        // The transport joined with the RESOLVED creds, not the pairing config.
        #expect(fake.lastConfig?.url == room)
        #expect(fake.lastConfig?.token == "minted-token")
        #expect(fake.lastConfig?.pairingEndpoint == nil)
    }

    @Test func unauthorizedPairingFailsStageOneWithoutConnecting() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(
            repository: try makeRepository(),
            transportFactory: { _ in fake },
            pairingResolver: { _, _, _ in throw PairingError.unauthorized }
        )
        vm.pairingEndpointText = "https://engine.example.com/connect/live"

        await vm.testConnection()

        #expect(status(of: .pairing, in: vm) == .failed("API key rejected (401) — check it matches your server's key"))
        #expect(status(of: .credentials, in: vm) == .pending)
        #expect(fake.connectCount == 0)
    }

    @Test func missingCredentialsPassesPairingFailsCredentials() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(
            repository: try makeRepository(),
            transportFactory: { _ in fake },
            pairingResolver: { _, _, _ in throw PairingError.missingCredentials }
        )
        vm.pairingEndpointText = "https://engine.example.com/connect/live"

        await vm.testConnection()

        #expect(status(of: .pairing, in: vm) == .passed)
        #expect(status(of: .credentials, in: vm) == .failed("Response missing room URL or token"))
        #expect(fake.connectCount == 0)
    }

    @Test func serverErrorSurfacesTheStatusCode() async throws {
        let vm = makeViewModel(
            repository: try makeRepository(),
            pairingResolver: { _, _, _ in throw PairingError.server(503) }
        )
        vm.pairingEndpointText = "https://engine.example.com/connect/live"

        await vm.testConnection()

        #expect(status(of: .pairing, in: vm) == .failed("Server error (HTTP 503)"))
    }
}
