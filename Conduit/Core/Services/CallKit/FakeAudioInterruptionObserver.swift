//
//  FakeAudioInterruptionObserver.swift
//  Conduit
//
//  In-app fake conforming to `AudioInterruptionObserving`. Lets tests synthesize an
//  interruption begin/end without a live AVAudioSession, and lets the simulator
//  wiring use a no-op observer.
//

import Foundation

@MainActor
final class FakeAudioInterruptionObserver: AudioInterruptionObserving {
    weak var delegate: AudioInterruptionObserverDelegate?
    private(set) var isObserving = false

    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }

    // MARK: - Test hooks

    func simulateBegan() { delegate?.audioInterruptionBegan() }
    func simulateEnded(shouldResume: Bool) { delegate?.audioInterruptionEnded(shouldResume: shouldResume) }
}
