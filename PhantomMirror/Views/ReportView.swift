import SwiftUI

struct ReportView: View {
    @Environment(AppState.self) private var appState
    @State private var isGeneratingClinicalNote = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    
                    metricsGrid
                    
                    painAssessmentSection
                    
                    storyCard
                    
                    Button {
                        appState.returnToOnboarding()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Start New Session")
                        }
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.2, green: 0.55, blue: 0.55))
                    .controlSize(.large)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
            }
            .navigationTitle("Session Report")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: clinicalNoteInputID) {
            // Let slider changes settle so a post-session pain adjustment causes
            // one regeneration rather than one request per intermediate value.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let report = appState.session
            isGeneratingClinicalNote = true
            let result = await ClinicalNoteGenerator.generate(from: report)
            guard !Task.isCancelled else { return }
            appState.session.clinicalNote = result.text
            appState.session.clinicalNoteUsesOnDeviceModel = result.usedOnDeviceModel
            isGeneratingClinicalNote = false
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Complete")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("Review your therapy metrics below. These are demo metrics and not a clinical outcome.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var metricsGrid: some View {
        let s = appState.session
        return VStack(alignment: .leading, spacing: 16) {
            Text("Performance Metrics")
                .font(.title3.weight(.semibold))
                
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metricCard(
                    title: "Duration",
                    value: String(format: "%.0f", s.durationSeconds),
                    unit: "sec",
                    icon: "timer",
                    color: .blue
                )
                metricCard(
                    title: "Tasks Completed",
                    value: "\(s.tasksCompleted)",
                    unit: "/ \(s.totalTasks)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
                metricCard(
                    title: "Tracking Quality",
                    value: String(format: "%.0f", s.trackingSuccessRate * 100),
                    unit: "%",
                    icon: "hand.point.up.left.fill",
                    color: .purple
                )
                metricCard(
                    title: "System Latency",
                    value: String(format: "%.0f", s.averageHandUpdateIntervalMs),
                    unit: "ms",
                    icon: "bolt.horizontal.fill",
                    color: .orange
                )
            }
        }
    }

    private func metricCard(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.title3)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(.title, design: .rounded).weight(.bold))
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private var painAssessmentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Post-Session Assessment")
                .font(.title3.weight(.semibold))
            
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pre-Session Pain")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("\(appState.session.prePainNRS) / 10")
                            .font(.title3.weight(.semibold))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Post-Session Pain")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("\(appState.session.postPainNRS) / 10")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.teal)
                    }
                }
                .padding(.horizontal, 8)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Update Post-Session Pain (NRS)")
                        .font(.subheadline.weight(.medium))
                    
                    Slider(value: Binding(
                        get: { Double(appState.session.postPainNRS) },
                        set: { appState.session.postPainNRS = Int($0) }
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
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var storyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.teal)
                Text("Clinical Note")
                    .font(.headline)
            }
            if isGeneratingClinicalNote && appState.session.clinicalNote.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Generating session summary…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } else {
                Text(appState.session.clinicalNote.isEmpty
                     ? ClinicalNoteGenerator.fallbackText(for: appState.session)
                     : appState.session.clinicalNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            Text(appState.session.clinicalNoteUsesOnDeviceModel
                 ? "Generated on device from session measurements. Descriptive only; not a clinical assessment."
                 : "Generated locally from session measurements. Descriptive only; not a clinical assessment.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var clinicalNoteInputID: String {
        let session = appState.session
        return [
            String(session.startedAt?.timeIntervalSinceReferenceDate ?? 0),
            String(session.endedAt?.timeIntervalSinceReferenceDate ?? 0),
            String(session.tasksCompleted),
            String(session.framesTracked),
            String(session.framesLost),
            String(session.prePainNRS),
            String(session.postPainNRS)
        ].joined(separator: "|")
    }
}
