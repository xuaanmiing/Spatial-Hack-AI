import SwiftUI

struct ReportView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Session report")
                        .font(.largeTitle.bold())

                    Text("Demo metrics only — not a clinical outcome.")
                        .foregroundStyle(.secondary)

                    metricsGrid

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Post-session pain (optional NRS)")
                            .font(.headline)
                        Stepper(value: Bindable(appState).session.postPainNRS, in: 0...10) {
                            Text("After session: \(appState.session.postPainNRS)")
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                    storyCard

                    Button {
                        appState.returnToOnboarding()
                    } label: {
                        Label("New session", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(28)
            }
            .navigationTitle("Report")
        }
    }

    private var metricsGrid: some View {
        let s = appState.session
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("Duration", String(format: "%.0fs", s.durationSeconds))
            metric("Tasks done", "\(s.tasksCompleted)/\(s.totalTasks)")
            metric("Tracking", String(format: "%.0f%%", s.trackingSuccessRate * 100))
            metric("Avg latency", String(format: "%.0f ms", s.averageLatencyMs))
            metric("NRS before", "\(s.prePainNRS)")
            metric("NRS after", "\(s.postPainNRS)")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var storyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you just saw")
                .font(.headline)
            Text("Intact-hand joints from ARKit HandTrackingProvider were reflected across the head sagittal plane into a contralateral phantom hand — classic mirror therapy, zero external sensors, on Vision Pro.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
