//
//  CueLabView.swift
//  Conduit
//
//  DEBUG-only panel: one button per cue-playback candidate. Press them one after
//  another during a live call and report which were heard, by number.
//

#if DEBUG
import SwiftUI

struct CueLabView: View {
    let lab: CueLab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var lab = lab

        NavigationStack {
            List {
                Section {
                    Text(lab.contextDescription)
                        .accessibilityIdentifier(AccessibilityID.CueLab.contextLabel)
                    Text(lab.lastResult)
                        .accessibilityIdentifier(AccessibilityID.CueLab.resultLabel)
                } footer: {
                    Text("Each press logs to conduit-call-trace.log in Documents. Say which numbers you heard, and from where (phone speaker, AirPods, car).")
                }

                Section("Candidates") {
                    ForEach(CueCandidate.allCases) { candidate in
                        Button(candidate.label) {
                            lab.press(candidate)
                        }
                        .disabled(candidate.requiresLiveKit && !lab.isLiveKitCall)
                        .accessibilityIdentifier(AccessibilityID.CueLab.candidateButton(candidate))
                    }
                }

                Section {
                    Toggle("Ducking: Apple default (off = SDK min)", isOn: $lab.duckingAppleDefault)
                        .accessibilityIdentifier(AccessibilityID.CueLab.duckingDefaultToggle)
                    Toggle("Advanced ducking", isOn: $lab.advancedDucking)
                        .accessibilityIdentifier(AccessibilityID.CueLab.advancedDuckingToggle)
                } header: {
                    Text("LiveKit ducking")
                } footer: {
                    Text("LiveKit calls only. Applied as soon as it is switched; the SDK may only honor it when its audio engine next starts.")
                }
                .disabled(!lab.isLiveKitCall)
                .onChange(of: lab.duckingAppleDefault) { lab.applyDucking() }
                .onChange(of: lab.advancedDucking) { lab.applyDucking() }

                Section {
                    Button("Log session now") {
                        lab.logSessionNow()
                    }
                    .accessibilityIdentifier(AccessibilityID.CueLab.logSessionButton)
                }
            }
            .navigationTitle("Cue Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.CueLab.doneButton)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.CueLab.screen)
        .task {
            lab.refreshDucking()
            await lab.prepareSpeechFile()
        }
    }
}
#endif
