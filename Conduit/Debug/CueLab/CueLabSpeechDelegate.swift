//
//  CueLabSpeechDelegate.swift
//  Conduit
//
//  Logs an AVSpeechSynthesizer's start / finish / cancel callbacks for the Cue Lab.
//

#if DEBUG
import AVFoundation

final class CueLabSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let label: String
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(label: String) {
        self.label = label
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        startCount += 1
        CueLabLog.record("\(label) didStart")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishCount += 1
        CueLabLog.record("\(label) didFinish")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        cancelCount += 1
        CueLabLog.record("\(label) didCancel")
    }
}
#endif
