import SwiftUI

/// Post-session single-question intake sheet.
///
/// The user rates how much their phantom-limb pain was relieved during the
/// session on a 0–10 scale. Everything else on the report is derived from
/// objective ARKit metrics that were already captured passively.
struct PostSessionIntakeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var relief: Double = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Post-Session Rating")
                        .font(.title.bold())
                    Text("One question — you're done.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    Text("How much was your phantom-limb pain relieved during this session?")
                        .font(.title3.weight(.semibold))

                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(relief))")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.teal)
                        Text("/ 10")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(reliefLabel(Int(relief)))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $relief, in: 0...10, step: 1).tint(.teal)

                    HStack {
                        Text("No relief")
                        Spacer()
                        Text("Complete relief")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

                Spacer(minLength: 0)

                HStack {
                    Button("Skip") {
                        submit(save: false)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        submit(save: true)
                    } label: {
                        Label("Save & view report", systemImage: "checkmark")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                relief = Double(appState.session.painReliefRating)
            }
        }
    }

    private func submit(save: Bool) {
        if save {
            let value = Int(relief)
            appState.session.painReliefRating = value
            // Derive a post-session NRS from baseline pain and relief so the
            // report can still show a pain-intensity delta.
            let baseline = appState.session.prePainNRS
            let derivedPost = max(0, baseline - Int(round(Double(baseline) * Double(value) / 10.0)))
            appState.session.postPainNRS = derivedPost
            appState.session.intakeCompleted = true
        }
        appState.submitPostSessionIntake()
        dismiss()
    }

    private func reliefLabel(_ value: Int) -> String {
        switch value {
        case 0: return "No relief"
        case 1...2: return "Minimal"
        case 3...4: return "Slight"
        case 5...6: return "Moderate"
        case 7...8: return "Substantial"
        case 9: return "Near-complete"
        default: return "Complete"
        }
    }
}
