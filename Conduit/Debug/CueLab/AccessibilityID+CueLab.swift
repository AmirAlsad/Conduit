//
//  AccessibilityID+CueLab.swift
//  Conduit
//
//  Identifiers for the DEBUG-only Cue Lab. See AccessibilityID.swift.
//

#if DEBUG
import Foundation

extension AccessibilityID {
    enum CueLab {
        static let openButton = "CueLab_OpenButton"
        static let screen = "CueLab_Screen"
        static let doneButton = "CueLab_DoneButton"
        static let contextLabel = "CueLab_ContextLabel"
        static let resultLabel = "CueLab_ResultLabel"
        static let logSessionButton = "CueLab_LogSessionButton"
        static let duckingDefaultToggle = "CueLab_DuckingDefaultToggle"
        static let advancedDuckingToggle = "CueLab_AdvancedDuckingToggle"
        static func candidateButton(_ candidate: CueCandidate) -> String {
            "CueLab_Candidate_\(candidate.rawValue)"
        }
    }
}
#endif
