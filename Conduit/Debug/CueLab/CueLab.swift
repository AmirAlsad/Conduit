//
//  CueLab.swift
//  Conduit
//
//  DEBUG-only owner of the Cue Lab: plays one short cue through each candidate
//  mechanism during a live call so a tester can hear which paths are audible, and
//  logs everything needed to explain the result to `conduit-call-trace.log`.
//
//  Hard rule: nothing here may call `AVAudioSession.setActive` or change the
//  session category, mode or options, or deactivate anything. CallKit owns the
//  session. The log carries a session snapshot before and shortly after each
//  press so any side effect of a framework would show up.
//

#if DEBUG
import AudioToolbox
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class CueLab {
    enum CueError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    struct CallContext {
        var transport: TransportKind?
        var engineState: String
    }

    static let phrase = "Cue test. Connected."

    var lastResult = "No cue played yet."
    var duckingAppleDefault = false
    var advancedDucking = false

    @ObservationIgnored var contextProvider: (() -> CallContext)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var speechFile: CueLabSpeechRenderer.Rendered?
    @ObservationIgnored private let renderer = CueLabSpeechRenderer()
    @ObservationIgnored private var appSynth: (AVSpeechSynthesizer, CueLabSpeechDelegate)?
    @ObservationIgnored private var ownSynth: (AVSpeechSynthesizer, CueLabSpeechDelegate)?
    @ObservationIgnored private var players: [CueCandidate: (AVAudioPlayer, CueLabPlayerDelegate)] = [:]
    @ObservationIgnored private var enginePlayback: CueLabEnginePlayback?

    var context: CallContext {
        contextProvider?() ?? CallContext(transport: nil, engineState: "unknown")
    }

    var contextDescription: String {
        "transport=\(context.transport?.displayName ?? "none") engine=\(context.engineState)"
    }

    var isLiveKitCall: Bool {
        context.transport == .livekit
    }

    // MARK: - Session notifications

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(Self.describe) ?? "unknown"
                let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription).map(CueLabLog.routeSummary) ?? "none"
                CueLabLog.record(
                    "NOTIFY routeChange reason=\(reason)(\(raw)) previous={\(previous)} "
                        + "now={\(CueLabLog.routeSummary(AVAudioSession.sharedInstance().currentRoute))}"
                )
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                let type = AVAudioSession.InterruptionType(rawValue: typeRaw).map { $0 == .began ? "began" : "ended" } ?? "unknown"
                let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                CueLabLog.record(
                    "NOTIFY interruption type=\(type) reason=\(reasonRaw.map(String.init) ?? "nil") "
                        + "options=\(optionsRaw.map(String.init) ?? "nil")"
                )
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
                CueLabLog.record("NOTIFY mediaServicesWereReset")
            },
            center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: nil) { note in
                let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
                CueLabLog.record("NOTIFY silenceSecondaryAudioHint type=\(raw.map(String.init) ?? "nil")")
            },
        ]
        CueLabLog.record("observing session notifications | \(contextDescription) | \(CueLabLog.sessionSummary())")
    }

    func stopObserving() {
        guard !observers.isEmpty else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        CueLabLog.record("stopped observing session notifications")
    }

    private nonisolated static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "other"
        }
    }

    // MARK: - Pressing a candidate

    func logSessionNow() {
        CueLabLog.record("SNAPSHOT | \(contextDescription) | \(CueLabLog.sessionSummary())")
        lastResult = "Session snapshot logged."
    }

    func press(_ candidate: CueCandidate) {
        CueLabLog.record("PRESS \(candidate.label) | \(contextDescription)")
        CueLabLog.record("session(before) \(CueLabLog.sessionSummary())")
        lastResult = "\(candidate.label): requested"
        Task {
            do {
                try await run(candidate)
                lastResult = "\(candidate.label): started, see log"
            } catch {
                CueLabLog.record("ERROR \(candidate.label): \(error)")
                lastResult = "\(candidate.label): error \(error)"
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            CueLabLog.record("session(+400ms after \(candidate.label)) \(CueLabLog.sessionSummary())")
        }
    }

    private func run(_ candidate: CueCandidate) async throws {
        switch candidate {
        case .synthAppSession:
            speak(usingApplicationSession: true)
        case .synthOwnSession:
            speak(usingApplicationSession: false)
        case .synthFilePlayer:
            try play(file: try await speechFileURL(), as: candidate)
        case .synthEngine:
            let playback = CueLabEnginePlayback(label: candidate.label)
            enginePlayback?.stop()
            enginePlayback = playback
            try playback.start(file: try await speechFileURL())
        case .ringPlayer:
            try play(file: try ringURL(), as: candidate)
        case .ringSystemSound:
            try playSystemSound(alert: false)
        case .ringAlertSound:
            try playSystemSound(alert: true)
        case .liveKitSpeech:
            try await playViaLiveKit(file: try await speechFileURL(), label: candidate.label)
        case .liveKitRing:
            try await playViaLiveKit(file: try ringURL(), label: candidate.label)
        }
    }

    // MARK: - Candidates 1 and 2: AVSpeechSynthesizer

    private func speak(usingApplicationSession: Bool) {
        let label = usingApplicationSession ? CueCandidate.synthAppSession.label : CueCandidate.synthOwnSession.label
        let (synthesizer, delegate) = makeSynthesizer(usingApplicationSession: usingApplicationSession, label: label)
        synthesizer.mixToTelephonyUplink = false
        let utterance = AVSpeechUtterance(string: Self.phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        CueLabLog.record(
            "\(label) usesApplicationAudioSession=\(synthesizer.usesApplicationAudioSession) "
                + "mixToTelephonyUplink=\(synthesizer.mixToTelephonyUplink) (off=\(!synthesizer.mixToTelephonyUplink)) "
                + "isSpeaking(before)=\(synthesizer.isSpeaking)"
        )
        synthesizer.speak(utterance)
        CueLabLog.record("\(label) speak() called isSpeaking=\(synthesizer.isSpeaking)")
        Task {
            try? await Task.sleep(for: .seconds(6))
            CueLabLog.record(
                "\(label) watchdog +6s starts=\(delegate.startCount) finishes=\(delegate.finishCount) "
                    + "cancels=\(delegate.cancelCount) isSpeaking=\(synthesizer.isSpeaking)"
            )
        }
    }

    private func makeSynthesizer(usingApplicationSession: Bool, label: String) -> (AVSpeechSynthesizer, CueLabSpeechDelegate) {
        if let existing = usingApplicationSession ? appSynth : ownSynth { return existing }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = usingApplicationSession
        let delegate = CueLabSpeechDelegate(label: label)
        synthesizer.delegate = delegate
        if usingApplicationSession {
            appSynth = (synthesizer, delegate)
        } else {
            ownSynth = (synthesizer, delegate)
        }
        return (synthesizer, delegate)
    }

    // MARK: - Pre-rendered speech

    func prepareSpeechFile() async {
        do {
            _ = try await speechFileURL()
        } catch {
            CueLabLog.record("ERROR speech render failed: \(error)")
        }
    }

    private func speechFileURL() async throws -> URL {
        if let speechFile { return speechFile.url }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cuelab-speech.caf")
        let started = ContinuousClock.now
        CueLabLog.record("render speech start (write(_:toBufferCallback:)) session(before)=\(CueLabLog.sessionSummary())")
        let rendered = try await renderer.render(phrase: Self.phrase, to: url)
        let elapsed = ContinuousClock.now - started
        let seconds = Double(rendered.frames) / rendered.format.sampleRate
        CueLabLog.record(
            "render speech done in \(elapsed) frames=\(rendered.frames) duration=\(seconds)s "
                + "format=\(rendered.format) file=\(url.lastPathComponent)"
        )
        CueLabLog.record("render speech session(after)=\(CueLabLog.sessionSummary())")
        speechFile = rendered
        return url
    }

    // MARK: - Candidates 3 and 5: AVAudioPlayer

    private func ringURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "phone-ring", withExtension: "caf") else {
            throw CueError.message("phone-ring.caf missing from bundle")
        }
        return url
    }

    private func play(file url: URL, as candidate: CueCandidate) throws {
        players[candidate]?.0.stop()
        let player = try AVAudioPlayer(contentsOf: url)
        let delegate = CueLabPlayerDelegate(label: candidate.label)
        player.delegate = delegate
        players[candidate] = (player, delegate)
        let prepared = player.prepareToPlay()
        let started = player.play()
        CueLabLog.record(
            "\(candidate.label) AVAudioPlayer prepareToPlay=\(prepared) play()=\(started) "
                + "duration=\(player.duration) format=\(player.format) volume=\(player.volume) "
                + "uplink=local-only"
        )
        if !started {
            throw CueError.message("AVAudioPlayer.play() returned false")
        }
    }

    // MARK: - Candidate 6: AudioServices

    private func playSystemSound(alert: Bool) throws {
        let label = alert ? CueCandidate.ringAlertSound.label : CueCandidate.ringSystemSound.label
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(try ringURL() as CFURL, &soundID)
        CueLabLog.record("\(label) AudioServicesCreateSystemSoundID status=\(status) id=\(soundID)")
        guard status == noErr else {
            throw CueError.message("AudioServicesCreateSystemSoundID failed: \(status)")
        }
        let started = ContinuousClock.now
        let createdID = soundID
        let finished: @Sendable () -> Void = {
            CueLabLog.record("\(label) completion after \(ContinuousClock.now - started)")
            AudioServicesDisposeSystemSoundID(createdID)
        }
        if alert {
            AudioServicesPlayAlertSoundWithCompletion(createdID, finished)
        } else {
            AudioServicesPlaySystemSoundWithCompletion(createdID, finished)
        }
        CueLabLog.record("\(label) play requested (void API, no success flag) uplink=local-only")
    }
}
#endif
