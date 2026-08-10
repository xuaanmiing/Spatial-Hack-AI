import SwiftUI

/// Clinical-grade session report shown after training. Renders whatever
/// intake data was captured plus objective motor metrics derived from the
/// ARKit hand-tracking session.
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
                    painIntensitySection
                    sfMPQSection
                    dn4Section
                    phenomenaSection
                    motorEngagementSection
                    subjectiveSection
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
                    .frame(minWidth: 640, minHeight: 720)
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
                    text: s.intakeCompleted ? "Intake complete" : "Intake pending"
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

    // MARK: - Pain intensity

    private var painIntensitySection: some View {
        let s = appState.session
        return sectionCard(title: "Pain Intensity", subtitle: "Pre vs. post-session (NRS 0-10)") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                painPrePostCard(
                    label: "Current phantom pain",
                    pre: s.prePainNRS,
                    post: s.postPainNRS
                )
                painPrePostCard(
                    label: "Worst PLP (24h)",
                    pre: nil,
                    post: s.postPainWorst24h
                )
                painPrePostCard(
                    label: "Average PLP (24h)",
                    pre: nil,
                    post: s.postPainAverage24h
                )
                painPrePostCard(
                    label: "Residual limb pain",
                    pre: nil,
                    post: s.residualLimbPainNRS
                )
            }

            HStack {
                Text("Present Pain Intensity")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(s.postPainPPI) / 5 · \(ClinicalScales.ppiLabel(for: s.postPainPPI))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
            }
            .padding(.top, 8)

            if s.prePainNRS > 0 {
                HStack {
                    Image(systemName: s.meetsMCID ? "checkmark.seal.fill" : "info.circle")
                        .foregroundStyle(s.meetsMCID ? .green : .secondary)
                    Text(mcidBanner(session: s))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    private func painPrePostCard(label: String, pre: Int?, post: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let pre {
                    Text("\(pre)")
                        .font(.system(.title2, design: .rounded).monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                    Image(systemName: deltaArrow(from: pre, to: post))
                        .font(.caption.bold())
                        .foregroundStyle(deltaColor(from: pre, to: post))
                }
                Text("\(post)")
                    .font(.system(.title, design: .rounded).monospacedDigit().bold())
                    .foregroundStyle(.teal)
                Text("/ 10")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let pre, pre > 0 {
                let deltaPercent = Int(round(Double(post - pre) / Double(pre) * 100))
                Text("\(deltaPercent >= 0 ? "+" : "")\(deltaPercent)% vs. baseline")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(deltaColor(from: pre, to: post))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - SF-MPQ

    private var sfMPQSection: some View {
        let s = appState.session
        let sensory = s.sfMPQSensoryScore
        let affective = s.sfMPQAffectiveScore
        return sectionCard(
            title: "Pain Quality — SF-MPQ",
            subtitle: "Short-Form McGill Pain Questionnaire (Melzack 1987)"
        ) {
            HStack(spacing: 16) {
                scoreDial(
                    label: "Sensory",
                    value: sensory,
                    max: ClinicalScales.sfMPQMaxSensory,
                    color: .indigo
                )
                scoreDial(
                    label: "Affective",
                    value: affective,
                    max: ClinicalScales.sfMPQMaxAffective,
                    color: .pink
                )
                scoreDial(
                    label: "Total",
                    value: s.sfMPQTotalScore,
                    max: ClinicalScales.sfMPQMaxTotal,
                    color: .teal
                )
            }

            if s.sfMPQItems.isEmpty {
                Text("No descriptors selected during intake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected descriptors")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    descriptorChips(items: s.sfMPQItems)
                }
                .padding(.top, 8)
            }
        }
    }

    private func descriptorChips(items: [SFMPQItem]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.descriptor) { item in
                HStack(spacing: 4) {
                    Text(item.descriptor)
                        .font(.caption.weight(.medium))
                    Text(item.intensity.label.prefix(3).uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(intensityTint(item.intensity), in: Capsule())
            }
        }
    }

    private func intensityTint(_ intensity: SFMPQItem.Intensity) -> Color {
        switch intensity {
        case .none: return .gray.opacity(0.15)
        case .mild: return .green.opacity(0.15)
        case .moderate: return .orange.opacity(0.20)
        case .severe: return .red.opacity(0.25)
        }
    }

    private func scoreDial(label: String, value: Int, max: Int, color: Color) -> some View {
        let fraction = max > 0 ? Double(value) / Double(max) : 0
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(value)")
                        .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                    Text("/ \(max)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - DN4

    private var dn4Section: some View {
        let s = appState.session
        return sectionCard(
            title: "Neuropathic Screen — DN4",
            subtitle: "Bouhassira 2005. ≥ 4 / 4 suggests neuropathic pain."
        ) {
            HStack {
                Text("Score")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(s.dn4Score) / 4")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(s.dn4IsNeuropathic ? .red : .teal)
                if s.dn4IsNeuropathic {
                    Text("Neuropathic pattern")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.red.opacity(0.15), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<ClinicalScales.dn4Questions.count, id: \.self) { i in
                    HStack {
                        Image(systemName: (s.dn4Answers.count > i && s.dn4Answers[i])
                                          ? "checkmark.circle.fill"
                                          : "circle")
                            .foregroundStyle((s.dn4Answers.count > i && s.dn4Answers[i]) ? .teal : .secondary)
                        Text(ClinicalScales.dn4Questions[i])
                            .font(.footnote)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Phantom phenomena

    private var phenomenaSection: some View {
        let s = appState.session
        return sectionCard(
            title: "Phantom Phenomena",
            subtitle: "Hsu & Cohen categorization (2013)"
        ) {
            FlowLayout(spacing: 8) {
                phenomenonBadge("Telescoping", present: s.telescopingPresent, color: .purple)
                phenomenonBadge("Kinetic", present: s.kineticSensations, color: .blue)
                phenomenonBadge("Kinesthetic", present: s.kinestheticSensations, color: .indigo)
                phenomenonBadge("Exteroceptive", present: s.exteroceptiveSensations, color: .teal)
            }
        }
    }

    private func phenomenonBadge(_ text: String, present: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: present ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(present ? color : .secondary.opacity(0.4))
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(present ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (present ? color.opacity(0.15) : Color.gray.opacity(0.10)),
            in: Capsule()
        )
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

    // MARK: - Subjective

    private var subjectiveSection: some View {
        let s = appState.session
        return sectionCard(
            title: "Subjective Experience",
            subtitle: "Patient self-report"
        ) {
            HStack(spacing: 16) {
                subjectiveDial(
                    label: "Controllability",
                    value: s.phantomControllability,
                    max: 10,
                    color: .teal
                )
                subjectiveDial(
                    label: "Mirror vividness",
                    value: s.mirrorVividness,
                    max: 5,
                    color: .purple
                )
            }

            if !s.subjectiveNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(s.subjectiveNotes)
                        .font(.footnote)
                }
                .padding(.top, 8)
            }
        }
    }

    private func subjectiveDial(label: String, value: Int, max: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max > 0 ? Double(value) / Double(max) : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(value)")
                    .font(.system(.title3, design: .rounded).monospacedDigit().bold())
            }
            .frame(width: 60, height: 60)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("/ \(max)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Trend

    private var trendSection: some View {
        sectionCard(
            title: "Session Trend",
            subtitle: "Post-session pain intensity across recent sessions"
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
        let maxValue = Double(sessions.map { max($0.prePainNRS, $0.postPainNRS) }.max() ?? 10)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(sessions) { s in
                VStack(spacing: 4) {
                    Text("\(s.postPainNRS)")
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
                                height: max(4, CGFloat(Double(s.postPainNRS) / max(maxValue, 1)) * 90)
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
                Label("Edit intake", systemImage: "square.and.pencil")
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

    private func deltaArrow(from pre: Int, to post: Int) -> String {
        if post < pre { return "arrow.down.right" }
        if post > pre { return "arrow.up.right" }
        return "equal"
    }

    private func deltaColor(from pre: Int, to post: Int) -> Color {
        if post < pre { return .green }
        if post > pre { return .red }
        return .secondary
    }

    private func mcidBanner(session s: SessionReport) -> String {
        if s.meetsMCID {
            let pct = Int(round(-s.nrsDeltaFraction * 100))
            return "Session met the minimum clinically important difference (\(pct)% NRS reduction ≥ 30%)."
        }
        return "Below the 30% NRS-reduction MCID threshold — consider additional sessions."
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
        let vividnessTag: String
        switch s.mirrorVividness {
        case 5: vividnessTag = "highly vivid mirror illusion"
        case 3...4: vividnessTag = "moderate mirror-illusion vividness"
        case 1...2: vividnessTag = "mild mirror-illusion vividness"
        default: vividnessTag = "unrated mirror-illusion vividness"
        }
        return "Patient with \(side) upper-limb amputation and phantom limb pain (ICD-10 \(ClinicalScales.ICD10.phantomWithPain)) completed a VR-mediated mirror-therapy session. Reported \(vividnessTag). \(s.subjectiveNotes.isEmpty ? "" : "Patient notes: \(s.subjectiveNotes)")"
    }

    private func soapObjective() -> String {
        let s = appState.session
        let deltaStr: String
        if s.prePainNRS > 0 {
            let pct = Int(round(s.nrsDeltaFraction * 100))
            deltaStr = "Pre-session NRS \(s.prePainNRS)/10, post-session NRS \(s.postPainNRS)/10 (Δ \(pct >= 0 ? "+" : "")\(pct)%). "
        } else {
            deltaStr = "Post-session NRS \(s.postPainNRS)/10. "
        }
        let sfmpq = "SF-MPQ sensory \(s.sfMPQSensoryScore)/33, affective \(s.sfMPQAffectiveScore)/12. "
        let dn4 = "DN4 = \(s.dn4Score)/4\(s.dn4IsNeuropathic ? " (neuropathic pattern retained)" : ""). "
        let latency = ClinicalScales.latencyCategory(ms: s.averageHandUpdateIntervalMs)
        let engagement = "\(s.tasksCompleted)/\(s.totalTasks) tasks completed. Motor engagement score \(s.motorEngagementScore)/100. Reach volume \(formatReachVolume(s.reachVolumeCm3)) cm³. Sensorimotor coupling \(latency.label.lowercased()) (\(String(format: "%.0f", s.averageHandUpdateIntervalMs)) ms)."
        return deltaStr + sfmpq + dn4 + engagement
    }

    private func soapAssessment() -> String {
        let s = appState.session
        if s.meetsMCID {
            return "Clinically meaningful acute reduction in phantom limb pain (≥30% NRS decrease). Objective motor engagement within therapeutic range."
        } else if s.prePainNRS > 0 {
            return "Acute PLP response below the MCID threshold this session. Motor engagement recorded objectively for longitudinal comparison."
        } else {
            return "Baseline session established; longitudinal trend requires additional sessions for MCID interpretation."
        }
    }

    private func soapPlan() -> String {
        let s = appState.session
        var pieces: [String] = []
        pieces.append("Continue mirror-visual feedback therapy 3× weekly.")
        if s.dn4IsNeuropathic {
            pieces.append("Neuropathic pattern persists — coordinate with pain specialist regarding pharmacologic adjuncts.")
        }
        if s.mirrorVividness <= 2 {
            pieces.append("Consider a graded motor imagery preparation phase to improve embodiment.")
        }
        pieces.append("Re-assess DN4, SF-MPQ, and NRS at 4-week interval.")
        return pieces.joined(separator: " ")
    }
}

// MARK: - Simple wrap layout used by descriptor / phenomena chips.

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                lineWidth = size.width + spacing
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth == .infinity ? lineWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
