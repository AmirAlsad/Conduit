//
//  ConnectionDiagnostics.swift
//  Conduit
//
//  The staged "Test connection" model: each stage of getting a call up is a
//  checklist row, so a failure names the step that broke instead of one vague
//  line. Pure types — the flow lives in AddEditAgentViewModel.
//

import Foundation

enum DiagnosticStage: String, CaseIterable, Sendable {
    case pairing
    case credentials
    case transport
    case ready

    var title: String {
        switch self {
        case .pairing: "Pairing endpoint reached"
        case .credentials: "Credentials minted"
        case .transport: "Transport connected"
        case .ready: "Agent ready"
        }
    }
}

enum DiagnosticStatus: Equatable, Sendable {
    case pending
    case running
    case passed
    case failed(String)
}

struct DiagnosticStep: Equatable, Identifiable, Sendable {
    let stage: DiagnosticStage
    var status: DiagnosticStatus = .pending

    var id: DiagnosticStage { stage }
}
