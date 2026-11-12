//
//  CueLabPlayerDelegate.swift
//  Conduit
//
//  Logs an AVAudioPlayer's completion for the Cue Lab.
//

#if DEBUG
import AVFoundation

final class CueLabPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let label: String

    init(label: String) {
        self.label = label
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        CueLabLog.record("\(label) AVAudioPlayer didFinish successfully=\(flag)")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        CueLabLog.record("\(label) AVAudioPlayer decodeError=\(String(describing: error))")
    }
}
#endif
