//
//  CueLabSpeechRenderer.swift
//  Conduit
//
//  Renders a phrase to a CAF file with `AVSpeechSynthesizer.write(_:toBufferCallback:)`
//  so the Cue Lab can play identical speech through players of its choice. Rendering
//  is offline and does not touch the audio session.
//

#if DEBUG
import AVFoundation
import Foundation

@MainActor
final class CueLabSpeechRenderer {
    struct Rendered {
        let url: URL
        let format: AVAudioFormat
        let frames: AVAudioFrameCount
    }

    enum RenderError: Error {
        case timedOut
        case unsupportedBuffer(String)
        case noAudio
    }

    private let synthesizer = AVSpeechSynthesizer()

    func render(phrase: String, to url: URL, timeout: Duration = .seconds(15)) async throws -> Rendered {
        try? FileManager.default.removeItem(at: url)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let sink = Sink(url: url)

        return try await withCheckedThrowingContinuation { continuation in
            sink.continuation = continuation
            synthesizer.write(utterance) { buffer in
                sink.receive(buffer)
            }
            Task {
                try? await Task.sleep(for: timeout)
                sink.finish(.failure(RenderError.timedOut))
            }
        }
    }

    private final class Sink: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var format: AVAudioFormat?
        private var frames: AVAudioFrameCount = 0
        private var isDone = false
        var continuation: CheckedContinuation<Rendered, Error>?

        init(url: URL) {
            self.url = url
        }

        func receive(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finish(.failure(RenderError.unsupportedBuffer(String(describing: type(of: buffer)))))
                return
            }
            if pcm.frameLength == 0 {
                lock.lock()
                let result: Result<Rendered, Error>
                if let format, frames > 0 {
                    file = nil
                    result = .success(Rendered(url: url, format: format, frames: frames))
                } else {
                    result = .failure(RenderError.noAudio)
                }
                lock.unlock()
                finish(result)
                return
            }
            lock.lock()
            defer { lock.unlock() }
            guard !isDone else { return }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                    format = pcm.format
                }
                try file?.write(from: pcm)
                frames += pcm.frameLength
            } catch {
                isDone = true
                file = nil
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }

        func finish(_ result: Result<Rendered, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !isDone else { return }
            isDone = true
            file = nil
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
#endif
