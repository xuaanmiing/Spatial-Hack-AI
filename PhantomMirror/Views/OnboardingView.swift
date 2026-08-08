import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    mechanismCard
                    sidePicker
                    painSlider
                    options
                    startButtons
                    disclaimer
                }
                .padding(28)
            }
            .navigationTitle("PhantomMirror")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mirror therapy demo")
                .font(.largeTitle.bold())
            Text("Track your intact hand, mirror it into a virtual phantom hand, and practice simple motor tasks. Creative prototype — not a medical device.")
                .foregroundStyle(.secondary)
        }
    }

    private var mechanismCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How it works", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("1. Wear Vision Pro and grant Hand Tracking\n2. Calibrate phantom hand position (telescoping)\n3. Open/close, touch orbs, then bimanual matching")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var sidePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which hand is missing?")
                .font(.headline)
            Picker("Missing side", selection: Bindable(appState).missingSide) {
                ForEach(AppState.MissingSide.allCases) { side in
                    Text(side.title).tag(side)
                }
            }
            .pickerStyle(.segmented)

            Text("We track: \(appState.missingSide.intactSideTitle)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var painSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional baseline pain (NRS 0–10)")
                .font(.headline)
            Stepper(value: Bindable(appState).session.prePainNRS, in: 0...10) {
                Text("Before session: \(appState.session.prePainNRS)")
            }
            Text("Demo metric only — not a clinical assessment.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Also show virtual intact hand", isOn: Bindable(appState).showVirtualIntactHand)
            Text("Off by default — only the phantom (missing) arm is shown.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Toggle("Hide real upper limbs", isOn: Bindable(appState).hideRealUpperLimbs)
        }
    }

    private var startButtons: some View {
        VStack(spacing: 12) {
            Button {
                appState.beginCalibration()
            } label: {
                Label("Calibrate phantom hand", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                appState.beginTraining()
            } label: {
                Label("Skip to training", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var disclaimer: some View {
        Text("For demonstration and research exploration. Not intended to diagnose, treat, cure, or prevent any disease.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }
}
