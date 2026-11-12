//
//  CueLab+LiveKit.swift
//  Conduit
//
//  Cue Lab candidate 7 and the ducking toggles, over LiveKit's `SoundPlayer` and
//  `AudioManager` (client-sdk-swift 2.19.0). Playback is local-only, so nothing
//  reaches the remote party, and it refuses to run unless the LiveKit transport has
//  turned automatic audio-session configuration off: `SoundPlayer.prepare` acquires
//  a session requirement that would otherwise reconfigure the session.
//

#if DEBUG
import Foundation
#if canImport(LiveKit)
import LiveKit
#endif

extension CueLab {
    func playViaLiveKit(file url: URL, label: String) async throws {
        #if canImport(LiveKit)
        guard isLiveKitCall else {
            throw CueError.message("skipped: the active call is not on LiveKit")
        }
        let automatic = AudioManager.shared.audioSession.isAutomaticConfigurationEnabled
        CueLabLog.record("\(label) LiveKit isAutomaticConfigurationEnabled=\(automatic) destination=local (remote off)")
        guard !automatic else {
            throw CueError.message("refused: LiveKit automatic audio-session configuration is on")
        }
        let handle = try await SoundPlayer.shared.prepare(fileURL: url, named: "cuelab")
        CueLabLog.record("\(label) SoundPlayer.prepare ok")
        try await handle.play(options: SoundPlaybackOptions(mode: .replace, destination: .local))
        CueLabLog.record("\(label) SoundPlayer.play started")
        Task {
            let started = ContinuousClock.now
            while await handle.isPlaying(destination: .local), ContinuousClock.now - started < .seconds(20) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            CueLabLog.record("\(label) SoundPlayer finished after \(ContinuousClock.now - started)")
            await handle.release()
        }
        #else
        throw CueError.message("skipped: the LiveKit module is not importable from the app target")
        #endif
    }

    /// Reads the SDK's current ducking settings. Only done on a LiveKit call, since
    /// the getters reach into the shared WebRTC audio device.
    func refreshDucking() {
        #if canImport(LiveKit)
        guard isLiveKitCall else { return }
        duckingAppleDefault = AudioManager.shared.duckingLevel == .default
        advancedDucking = AudioManager.shared.isAdvancedDuckingEnabled
        CueLabLog.record("ducking read level=\(AudioManager.shared.duckingLevel) advanced=\(advancedDucking)")
        #endif
    }

    func applyDucking() {
        #if canImport(LiveKit)
        guard isLiveKitCall else { return }
        let desiredLevel: AudioDuckingLevel = duckingAppleDefault ? .default : .min
        guard AudioManager.shared.duckingLevel != desiredLevel
            || AudioManager.shared.isAdvancedDuckingEnabled != advancedDucking
        else { return }
        AudioManager.shared.duckingLevel = desiredLevel
        AudioManager.shared.isAdvancedDuckingEnabled = advancedDucking
        CueLabLog.record(
            "ducking set level=\(duckingAppleDefault ? "default" : "min") advanced=\(advancedDucking) "
                + "readback level=\(AudioManager.shared.duckingLevel) advanced=\(AudioManager.shared.isAdvancedDuckingEnabled)"
        )
        lastResult = "Ducking applied, see log."
        #endif
    }
}
#endif
