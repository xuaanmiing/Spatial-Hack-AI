import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioFeedback.self) private var audio

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    
                    VStack(spacing: 24) {
                        mechanismCard
                        configurationSection
                        painAssessmentSection
                        preferencesSection
                    }
                    
                    startButtons
                        .padding(.top, 16)
                    
                    disclaimer
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
            }
            .navigationTitle("PhantomMirror")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.teal)
                        Text("PhantomMirror")
                            .font(.headline)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mirror Therapy Session")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("Track your intact hand, mirror it into a virtual phantom hand, and practice simple motor tasks. A modern approach to mirror visual feedback.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
    }

    private var mechanismCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.teal)
                    .font(.title3)
                Text("Protocol Overview")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                InstructionRow(step: "1", text: "Wear Vision Pro and grant Hand Tracking")
                InstructionRow(step: "2", text: "Calibrate phantom hand position")
                InstructionRow(step: "3", text: "Complete motor tasks: touch, match, clap, and slice")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Patient Configuration")
                .font(.title3.weight(.semibold))
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Affected Limb")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Picker("Missing side", selection: Bindable(appState).missingSide) {
                    ForEach(AppState.MissingSide.allCases) { side in
                        Text(side.title).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.teal)
                    Text("Tracking source: **\(appState.missingSide.intactSideTitle)**")
                        .font(.footnote)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var painAssessmentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pre-Session Assessment")
                .font(.title3.weight(.semibold))
            
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Baseline Pain (NRS)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(appState.session.prePainNRS) / 10")
                        .font(.headline)
                        .foregroundStyle(.teal)
                }
                
                Slider(value: Binding(
                    get: { Double(appState.session.prePainNRS) },
                    set: { appState.session.prePainNRS = Int($0) }
                ), in: 0...10, step: 1)
                .tint(.teal)
                
                HStack {
                    Text("No pain")
                    Spacer()
                    Text("Worst pain")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Environment Preferences")
                .font(.title3.weight(.semibold))
            
            VStack(spacing: 0) {
                ToggleRow(
                    title: "Show virtual intact hand",
                    subtitle: "Displays a virtual model over your tracked hand",
                    isOn: Bindable(appState).showVirtualIntactHand
                )
                
                Divider().padding(.leading, 16)
                
                ToggleRow(
                    title: "Hide real upper limbs",
                    subtitle: appState.hideRealUpperLimbs ? "Virtual props draw over real hands" : "Real hands stay visible above virtual props",
                    isOn: Bindable(appState).hideRealUpperLimbs
                )
                
                Divider().padding(.leading, 16)
                
                ToggleRow(
                    title: "Audio feedback",
                    subtitle: "Play sound effects and ambient tones",
                    isOn: Bindable(audio).isEnabled
                )
                .onChange(of: audio.isEnabled) { _, enabled in
                    if !enabled { audio.stopAmbient() }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var startButtons: some View {
        VStack(spacing: 16) {
            Button {
                appState.beginCalibration()
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Calibrate System")
                }
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.2, green: 0.55, blue: 0.55))
            .controlSize(.large)

            Button {
                appState.beginTraining()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Session Directly")
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                appState.beginPlayground()
            } label: {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text("Brick Builder Playground")
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("For demonstration and research exploration. Not intended to diagnose, treat, cure, or prevent any disease.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct InstructionRow: View {
    let step: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(step)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.teal))
            
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.top, 2)
        }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Binding<Bool>
    
    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.teal)
        .padding(16)
    }
}
