import SwiftUI

/// Post-session report. Presents a minimal single-question intake sheet the
/// first time it appears, then renders the objective ARKit-derived motor
/// metrics plus the patient-reported pain relief rating.
struct ReportView: View {
    @Environment(AppState.self) private var appState

    private var history: [SessionReport] {
        SessionHistory.shared.recent(10)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    painReliefSection
                    motorEngagementSection
                    trendSection
                    soapNoteSection
                    referencesSection
                    footerActions
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 32)
            }
            .navigationTitle("Session Report")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Bindable(appState).showingPostSessionIntake) {
                PostSessionIntakeView()
                    .environment(appState)
                    .interactiveDismissDisabled(false)
                    .frame(minWidth: 640, minHeight: 560)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let s = appState.session
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Session Report")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                Spacer()
                Text(ClinicalScales.ICD10.title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }

            HStack(spacing: 16) {
                headerChip(icon: "calendar", text: dateString(s.startedAt ?? Date()))
                headerChip(icon: "timer", text: durationString(s.durationSeconds))
                headerChip(icon: "hand.raised", text: sideLabel())
                headerChip(
                    icon: s.intakeCompleted ? "checkmark.seal.fill" : "hourglass",
                    text: s.intakeCompleted ? "Rated" : "Rating pending"
                )
            }
            .font(.caption.weight(.medium))
        }
    }

    private func headerChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Pain relief

    private var painReliefSection: some View {
        let s = appState.session
        return sectionCard(
            title: "Pain Relief",
            subtitle: "Patient self-report at end of session"
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(s.painReliefRating)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.teal)
                Text("/ 10")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(reliefLabel(s.painReliefRating))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            reliefBar(value: s.painReliefRating)

            if s.prePainNRS > 0 {
                HStack(spacing: 12) {
                    Label("Baseline NRS \(s.prePainNRS)", systemImage: "arrow.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("Estimated post-session NRS \(s.postPainNRS)", systemImage: "arrow.right")
                        .font(.footnote)
                        .foregroundStyle(.teal)
                }
                if s.meetsMCID {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Met the ≥30% NRS-reduction MCID threshold.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reliefBar(value: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.teal.opacity(0.15))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.teal)
                    .frame(width: max(0, geo.size.width * CGFloat(value) / 10))
            }
        }
        .frame(height: 12)
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

    // MARK: - Motor engagement

    private var motorEngagementSection: some View {
        let s = appState.session
        let latency = ClinicalScales.latencyCategory(ms: s.averageHandUpdateIntervalMs)
        return sectionCard(
            title: "Motor Engagement",
            subtitle: "Objective metrics computed from ARKit hand tracking"
        ) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                motorCard(
                    icon: "timer",
                    color: .blue,
                    value: "\(Int(s.durationSeconds))",
                    unit: "s",
                    label: "Session duration"
                )
                motorCard(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    value: "\(s.tasksCompleted)",
                    unit: "/ \(s.totalTasks)",
                    label: "Tasks completed"
                )
                motorCard(
                    icon: "hand.point.up.left.fill",
                    color: .purple,
                    value: String(format: "%.0f", s.trackingSuccessRate * 100),
                    unit: "%",
                    label: "Tracking quality"
                )
                motorCard(
                    icon: latency.isSubPerceptual ? "bolt.horizontal.fill" : "bolt.horizontal",
                    color: latency.isSubPerceptual ? .green : .orange,
                    value: String(format: "%.0f", s.averageHandUpdateIntervalMs),
                    unit: "ms",
                    label: "Sensorimotor coupling · \(latency.label)"
                )
                motorCard(
                    icon: "figure.arms.open",
                    color: .indigo,
                    value: formatReachVolume(s.reachVolumeCm3),
                    unit: "cm³",
                    label: "Phantom reach volume"
                )
                motorCard(
                    icon: "waveform.path.ecg",
                    color: .teal,
                    value: String(format: "%.2f", s.motionSmoothness),
                    unit: "/ 1.0",
                    label: "Motion smoothness"
                )
                motorCard(
                    icon: "gauge.medium",
                    color: .pink,
                    value: "\(s.motorEngagementScore)",
                    unit: "/ 100",
                    label: "Motor engagement score"
                )
                motorCard(
                    icon: "stopwatch",
                    color: .orange,
                    value: String(format: "%.1f", s.averageTaskDurationSeconds),
                    unit: "s",
                    label: "Avg task time"
                )
            }
        }
    }

    private func motorCard(
        icon: String,
        color: Color,
        value: String,
        unit: String,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded).monospacedDigit().bold())
                Text(unit)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Trend

    private var trendSection: some View {
        sectionCard(
            title: "Session Trend",
            subtitle: "Reported pain relief across recent sessions"
        ) {
            if history.count < 2 {
                Text("Not enough prior sessions yet — complete more sessions to build a trend.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                trendChart(sessions: history)
            }
        }
    }

    private func trendChart(sessions: [SessionReport]) -> some View {
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(sessions) { s in
                VStack(spacing: 4) {
                    Text("\(s.painReliefRating)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.teal.opacity(0.15))
                            .frame(width: 24, height: 90)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.teal)
                            .frame(
                                width: 24,
                                height: max(4, CGFloat(Double(s.painReliefRating) / 10.0) * 90)
                            )
                    }
                    Text(shortDate(s.startedAt ?? Date()))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - SOAP Note

    private var soapNoteSection: some View {
        sectionCard(
            title: "Clinical Interpretation",
            subtitle: "Auto-generated SOAP note",
            tint: .teal
        ) {
            VStack(alignment: .leading, spacing: 10) {
                soapLine(letter: "S", text: soapSubjective())
                soapLine(letter: "O", text: soapObjective())
                soapLine(letter: "A", text: soapAssessment())
                soapLine(letter: "P", text: soapPlan())
            }
        }
    }

    private func soapLine(letter: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(letter)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.teal, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - References

    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("References")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ClinicalScales.referencesForReportFooter, id: \.self) { ref in
                Text("• \(ref)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            Button {
                appState.showingPostSessionIntake = true
            } label: {
                Label("Re-rate relief", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                appState.returnToOnboarding()
            } label: {
                Label("New session", systemImage: "arrow.counterclockwise")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint ?? .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }

    private func durationString(_ s: TimeInterval) -> String {
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }

    private func sideLabel() -> String {
        appState.missingSide == .right
            ? "Right upper-limb amputee"
            : "Left upper-limb amputee"
    }

    private func formatReachVolume(_ cm3: Double) -> String {
        if cm3 >= 1000 {
            return String(format: "%.1fk", cm3 / 1000)
        }
        return String(format: "%.0f", cm3)
    }

    // MARK: - SOAP text generation

    private func soapSubjective() -> String {
        let s = appState.session
        let side = appState.missingSide == .right ? "right" : "left"
        return "Patient with \(side) upper-limb amputation and phantom limb pain (ICD-10 \(ClinicalScales.ICD10.phantomWithPain)) completed a VR-mediated mirror-therapy session. Patient reported \(reliefLabel(s.painReliefRating).lowercased()) pain relief (\(s.painReliefRating)/10)."
    }

    private func soapObjective() -> String {
        let s = appState.session
        let latency = ClinicalScales.latencyCategory(ms: s.averageHandUpdateIntervalMs)
        let baselinePart: String
        if s.prePainNRS > 0 {
            baselinePart = "Pre-session NRS \(s.prePainNRS)/10, estimated post-session NRS \(s.postPainNRS)/10. "
        } else {
            baselinePart = ""
        }
        return baselinePart +
            "\(s.tasksCompleted)/\(s.totalTasks) tasks completed. " +
            "Motor engagement score \(s.motorEngagementScore)/100. " +
            "Reach volume \(formatReachVolume(s.reachVolumeCm3)) cm³. " +
            "Motion smoothness \(String(format: "%.2f", s.motionSmoothness))/1.0. " +
            "Sensorimotor coupling \(latency.label.lowercased()) (\(String(format: "%.0f", s.averageHandUpdateIntervalMs)) ms)."
    }

    private func soapAssessment() -> String {
        let s = appState.session
        if s.meetsMCID {
            return "Clinically meaningful pain relief reported (equivalent to ≥30% NRS reduction). Objective motor engagement within therapeutic range."
        } else if s.painReliefRating >= 5 {
            return "Moderate pain relief reported. Objective motor engagement recorded for longitudinal comparison."
        } else if s.painReliefRating > 0 {
            return "Limited pain relief reported this session. Motor engagement recorded objectively."
        } else {
            return "No pain relief reported. Baseline motor engagement recorded for longitudinal comparison."
        }
    }

    private func soapPlan() -> String {
        let s = appState.session
        var pieces: [String] = []
        pieces.append("Continue mirror-visual feedback therapy 3× weekly.")
        if s.painReliefRating < 3 {
            pieces.append("Consider adjusting calibration or session duration next visit.")
        }
        pieces.append("Re-assess pain relief and motor engagement each session.")
        return pieces.joined(separator: " ")
    }
}
