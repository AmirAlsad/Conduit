//
//  AddEditAgentViewModelTests.swift
//  ConduitTests
//
//  The bring-your-own-agent form logic against fakes: validation, persistence
//  (token to Keychain, never on the agent), the contacts-mirror lifecycle, edit
//  identity-stability, and the test-connection state machine.
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
        contacts: ContactsMirroring = FakeContactsMirror(),
        transportFactory: @escaping (TransportKind) -> Transport = { _ in FakeTransport() }
    ) -> AddEditAgentViewModel {
        AddEditAgentViewModel(
            editing: agent,
            repository: repository,
            keychain: keychain,
            contacts: contacts,
            transportFactory: transportFactory
        )
    }

    // MARK: - Validation

    @Test func canSaveRequiresNameURLAndCredential() throws {
        let vm = makeViewModel(repository: try makeRepository())
        #expect(!vm.canSave)
        vm.name = "Jarvis"
        #expect(!vm.canSave) // no URL
        vm.connectionURLText = "https://x.daily.co/room"
        #expect(!vm.canSave) // no token or pairing endpoint
        vm.token = "secret"
        #expect(vm.canSave)
    }

    @Test func pairingEndpointSatisfiesCredentialRequirement() throws {
        let vm = makeViewModel(repository: try makeRepository())
        vm.name = "Jarvis"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.pairingEndpointText = "https://x.daily.co/pair"
        #expect(vm.canSave) // pairing endpoint stands in for a static token
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
        vm.token = "secret-token"

        try await vm.save()

        let agents = try repo.fetchAll()
        #expect(agents.count == 1)
        let agent = try #require(agents.first)
        #expect(agent.name == "Jarvis")
        #expect(agent.detail == "Personal")
        #expect(agent.connectionURL.absoluteString == "https://x.daily.co/room")
        // Token lives ONLY in the Keychain.
        #expect(try keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef)) == "secret-token")
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
        vm.token = "tok"
        try await vm.save()

        #expect(agent.name == "New Name")
        #expect(agent.syntheticEmail == originalEmail)
        #expect(agent.keychainTokenRef == originalRef)
        #expect(try repo.fetchAll().count == 1)
    }

    // MARK: - Contacts mirror lifecycle

    @Test func savingWithMirrorOnUpsertsContact() async throws {
        let repo = try makeRepository()
        let contacts = FakeContactsMirror(grantsAccess: true)
        let vm = makeViewModel(repository: repo, contacts: contacts)
        vm.name = "Echo"
        vm.connectionURLText = "https://x.daily.co/room"
        vm.token = "t"
        vm.mirrorsToContacts = true

        try await vm.save()

        let agent = try #require(try repo.fetchAll().first)
        #expect(contacts.mirror(for: agent.id) != nil)
    }

    @Test func editingWithMirrorOffRemovesContact() async throws {
        let repo = try makeRepository()
        let contacts = FakeContactsMirror(grantsAccess: true)

        let create = makeViewModel(repository: repo, contacts: contacts)
        create.name = "Echo"
        create.connectionURLText = "https://x.daily.co/room"
        create.token = "t"
        create.mirrorsToContacts = true
        try await create.save()
        let agent = try #require(try repo.fetchAll().first)
        #expect(contacts.mirror(for: agent.id) != nil)

        let edit = makeViewModel(editing: agent, repository: repo, contacts: contacts)
        edit.mirrorsToContacts = false
        try await edit.save()
        #expect(contacts.mirror(for: agent.id) == nil)
    }

    // MARK: - Test connection

    @Test func testConnectionSucceedsOnConnectedEvent() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.token = "t"

        async let run: Void = vm.testConnection()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(.connected)
        await run

        #expect(vm.testState == .success)
        #expect(fake.disconnectCount == 1) // always tears the probe down
    }

    @Test func testConnectionReportsAuthFailureFromEvent() async throws {
        let fake = FakeTransport()
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.token = "bad"

        async let run: Void = vm.testConnection()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(.error(.authenticationFailed))
        await run

        #expect(vm.testState == .failure("Authentication failed"))
    }

    @Test func testConnectionFailsWhenConnectThrows() async throws {
        let fake = FakeTransport()
        fake.connectError = .authenticationFailed
        let vm = makeViewModel(repository: try makeRepository(), transportFactory: { _ in fake })
        vm.connectionURLText = "https://x.daily.co/room"
        vm.token = "t"

        await vm.testConnection()

        #expect(vm.testState == .failure("Couldn't reach the agent"))
    }
}
