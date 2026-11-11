//
//  FakeVoIPPushRegistry.swift
//  Conduit
//
//  In-app fake conforming to `VoIPPushRegistering`: counts starts and lets a test
//  deliver token updates and pushes through the same callbacks PushKit would.
//

import Foundation

@MainActor
final class FakeVoIPPushRegistry: VoIPPushRegistering {
    var pushToken: Data?
    private(set) var startCount = 0
    private var onTokenUpdate: (@MainActor (Data) -> Void)?
    private var onIncomingPush: (@MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void)?

    func start(
        onTokenUpdate: @escaping @MainActor (Data) -> Void,
        onIncomingPush: @escaping @MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void
    ) {
        startCount += 1
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingPush = onIncomingPush
    }

    /// PushKit issued (or rotated) the token.
    func simulateTokenUpdate(_ token: Data) {
        pushToken = token
        onTokenUpdate?(token)
    }

    /// PushKit delivered a VoIP push.
    func simulateIncomingPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        onIncomingPush?(payload, completion)
    }
}
