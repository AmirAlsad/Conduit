//
//  CueLabEnginePlayback.swift
//  Conduit
//
//  One short AVAudioEngine + AVAudioPlayerNode playback for the Cue Lab. It only
//  starts and stops its own engine; the shared AVAudioSession is never configured.
//

#if DEBUG
import AVFoundation

final class CueLabEnginePlayback: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let label: String

    init(label: String) {
        self.label = label
    }

    func start(file url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CueLab.CueError.message("could not allocate PCM buffer")
        }
        try file.read(into: buffer)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        CueLabLog.record(
            "\(label) engine bufferFormat=\(buffer.format) frames=\(buffer.frameLength) "
                + "outputFormat=\(engine.outputNode.outputFormat(forBus: 0))"
        )
        try engine.start()
        CueLabLog.record("\(label) engine.start() ok isRunning=\(engine.isRunning)")
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            CueLabLog.record("\(self?.label ?? "engine") node dataPlayedBack")
            self?.stop()
        }
        node.play()
        CueLabLog.record("\(label) node.play() called isPlaying=\(node.isPlaying)")
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}
#endif
