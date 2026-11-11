//
//  FakeRingStatusReporter.swift
//  Conduit
//
//  In-app fake conforming to `RingStatusReporting`: records each receipt instead
//  of POSTing it.
//

import Foundation

@MainActor
final class FakeRingStatusReporter: RingStatusReporting {
    struct Report: Equatable {
        let status: RingStatus
        let callID: UUID
        let endpoint: URL
        let apiKey: String
    }

    private(set) var reports: [Report] = []
    /// Receives a label per receipt, for tests that assert order across fakes.
    var onEvent: ((String) -> Void)?

    func report(_ status: RingStatus, callID: UUID, endpoint: URL, apiKey: String) {
        onEvent?("receipt(\(status.rawValue))")
        reports.append(Report(status: status, callID: callID, endpoint: endpoint, apiKey: apiKey))
    }
}
