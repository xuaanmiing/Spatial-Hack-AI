import SwiftUI

/// Post-session clinical intake — presented as a sheet immediately after
/// training completes. All fields are optional; the user can skip any step
/// and the report renders whatever data was captured.
struct PostSessionIntakeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 0

    // Local mirrored state — committed back to `appState.session` on finish
    // so that mid-form edits don't perturb the report while the user is
    // still deciding.
    @State private var currentPain: Double = 0
    @State private var worst24h: Double = 0
    @State private var average24h: Double = 0
    @State private var stumpPain: Double = 0
    @State private var ppi: Double = 0

    @State private var sfMPQItems: [String: SFMPQItem.Intensity] = [:]

    @State private var dn4: [Bool] = [false, false, false, false]

    @State private var telescoping = false
    @State private var kinetic = false
    @State private var kinesthetic = false
    @State private var exteroceptive = false

    @State private var controllability: Double = 5
    @State private var vividness: Double = 3
    @State private var notes: String = ""

    private let stepCount = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch step {
                        case 0: painIntensityStep
                        case 1: sfMPQStep
                        case 2: dn4Step
                        case 3: phantomPhenomenaStep
                        default: subjectiveStep
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }

                footer
            }
            .navigationTitle("Clinical Intake")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: seedFromExistingSession)
        }
    }

    // MARK: - Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(step + 1) of \(stepCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip all", role: .cancel) { commitAndFinish() }
                    .font(.caption)
            }
            ProgressView(value: Double(step + 1), total: Double(stepCount))
                .tint(.teal)
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Step 1: Pain intensity

    private var painIntensityStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                title: "Pain Intensity",
                subtitle: "Numeric Rating Scale (NRS) 0-10 and Present Pain Intensity (PPI)."
            )

            nrsSlider(
                label: "Current phantom limb pain",
                value: $currentPain
            )
            nrsSlider(
                label: "Worst PLP in the last 24 hours",
                value: $worst24h
            )
            nrsSlider(
                label: "Average PLP in the last 24 hours",
                value: $average24h
            )
            nrsSlider(
                label: "Residual limb (stump) pain",
                value: $stumpPain
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Present Pain Intensity")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(ClinicalScales.ppiLabel(for: Int(ppi)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.teal)
                }
                Slider(value: $ppi, in: 0...5, step: 1).tint(.teal)
                HStack {
                    ForEach(0..<ClinicalScales.ppiAnchors.count, id: \.self) { i in
                        Text("\(i)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func nrsSlider(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(value.wrappedValue)) / 10")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.teal)
            }
            Slider(value: value, in: 0...10, step: 1).tint(.teal)
            HStack {
                Text("No pain").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Worst pain").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Step 2: SF-MPQ

    private var sfMPQStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                title: "Pain Quality — SF-MPQ",
                subtitle: "Short-Form McGill Pain Questionnaire. Rate each descriptor that applies."
            )

            descriptorGroup(
                heading: "Sensory (0-33)",
                descriptors: ClinicalScales.sfMPQSensoryDescriptors
            )
            descriptorGroup(
                heading: "Affective (0-12)",
                descriptors: ClinicalScales.sfMPQAffectiveDescriptors
            )
        }
    }

    private func descriptorGroup(heading: String, descriptors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)
            ForEach(descriptors, id: \.self) { descriptor in
                descriptorRow(descriptor)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func descriptorRow(_ descriptor: String) -> some View {
        let current = sfMPQItems[descriptor] ?? .none
        return HStack {
            Text(descriptor)
                .font(.subheadline)
            Spacer()
            Picker("", selection: Binding<SFMPQItem.Intensity>(
                get: { current },
                set: { sfMPQItems[descriptor] = $0 }
            )) {
                ForEach(SFMPQItem.Intensity.allCases) { intensity in
                    Text(intensity.label).tag(intensity)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    // MARK: - Step 3: DN4

    private var dn4Step: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                title: "Neuropathic Screen — DN4",
                subtitle: "Score ≥ 4 / 4 suggests a neuropathic pain pattern."
            )

            VStack(spacing: 12) {
                ForEach(0..<ClinicalScales.dn4Questions.count, id: \.self) { i in
                    Toggle(isOn: $dn4[i]) {
                        Text(ClinicalScales.dn4Questions[i])
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                    .tint(.teal)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text("Current DN4 score")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(dn4.filter { $0 }.count) / 4")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(dn4.filter { $0 }.count >= ClinicalScales.dn4PositiveThreshold ? .red : .secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Step 4: Phantom phenomena

    private var phantomPhenomenaStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                title: "Phantom Phenomena",
                subtitle: "Non-painful sensations. Multiple selections are common."
            )

            VStack(spacing: 12) {
                Toggle("Telescoping (limb feels shorter over time)", isOn: $telescoping)
                Toggle("Kinetic sensations (perceived movement)", isOn: $kinetic)
                Toggle("Kinesthetic (perceived position / posture)", isOn: $kinesthetic)
                Toggle("Exteroceptive (touch, temperature, itch)", isOn: $exteroceptive)
            }
            .tint(.teal)
            .toggleStyle(.switch)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Step 5: Subjective experience

    private var subjectiveStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                title: "Session Experience",
                subtitle: "Your subjective control and vividness ratings."
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Phantom limb controllability")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(controllability)) / 10")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.teal)
                }
                Slider(value: $controllability, in: 0...10, step: 1).tint(.teal)
                Text("How much you felt the phantom moved as intended.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mirror-illusion vividness")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(vividness)) / 5")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.teal)
                }
                Slider(value: $vividness, in: 0...5, step: 1).tint(.teal)
                Text("How real the phantom hand felt (KVIQ-style, 0-5).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("Additional notes (optional)")
                    .font(.subheadline.weight(.medium))
                TextField("Anything else worth recording", text: $notes, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if step < stepCount - 1 {
                Button("Next") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            } else {
                Button("Finish") {
                    commitAndFinish()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .background(.thinMaterial)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Persistence

    private func seedFromExistingSession() {
        let s = appState.session
        currentPain = Double(s.postPainNRS > 0 ? s.postPainNRS : s.prePainNRS)
        worst24h = Double(s.postPainWorst24h)
        average24h = Double(s.postPainAverage24h)
        stumpPain = Double(s.residualLimbPainNRS)
        ppi = Double(s.postPainPPI)
        for item in s.sfMPQItems {
            sfMPQItems[item.descriptor] = item.intensity
        }
        if s.dn4Answers.count == 4 { dn4 = s.dn4Answers }
        telescoping = s.telescopingPresent
        kinetic = s.kineticSensations
        kinesthetic = s.kinestheticSensations
        exteroceptive = s.exteroceptiveSensations
        controllability = Double(s.phantomControllability)
        vividness = Double(s.mirrorVividness)
        notes = s.subjectiveNotes
    }

    private func commitAndFinish() {
        appState.session.postPainNRS = Int(currentPain)
        appState.session.postPainWorst24h = Int(worst24h)
        appState.session.postPainAverage24h = Int(average24h)
        appState.session.residualLimbPainNRS = Int(stumpPain)
        appState.session.postPainPPI = Int(ppi)

        let items: [SFMPQItem] = sfMPQItems.compactMap { (descriptor, intensity) in
            guard intensity != .none else { return nil }
            return SFMPQItem(descriptor: descriptor, intensity: intensity)
        }
        appState.session.sfMPQItems = items

        appState.session.dn4Answers = dn4
        appState.session.telescopingPresent = telescoping
        appState.session.kineticSensations = kinetic
        appState.session.kinestheticSensations = kinesthetic
        appState.session.exteroceptiveSensations = exteroceptive
        appState.session.phantomControllability = Int(controllability)
        appState.session.mirrorVividness = Int(vividness)
        appState.session.subjectiveNotes = notes
        appState.session.intakeCompleted = true

        appState.submitPostSessionIntake()
        dismiss()
    }
}
