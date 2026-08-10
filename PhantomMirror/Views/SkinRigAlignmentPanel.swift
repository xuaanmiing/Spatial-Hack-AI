import SwiftUI
import ARKit
import simd

struct SkinRigAlignmentPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(HandSceneController.self) private var scene

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                visibilityControl
                translationControls
                rotationControls
                scaleControl
                confirmationControls
                mappingSummary
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 610)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.pink)
                Text("Skin Rig Alignment")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            Text("Align the palm only. On confirmation, the wrist stays locked while the forearm bends toward the two forearm points.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
            Text(scene.skinRig.statusText)
                .font(.caption2)
                .foregroundStyle(scene.skinRig.isLoaded ? Color.secondary : Color.orange)
        }
    }

    private var statusBadge: some View {
        Label(
            appState.calibration.skinAlignmentConfirmed ? "Mapped" : "Aligning",
            systemImage: appState.calibration.skinAlignmentConfirmed ? "checkmark.circle.fill" : "scope"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(appState.calibration.skinAlignmentConfirmed ? .green : .orange)
    }

    private var visibilityControl: some View {
        Toggle(isOn: Binding(
            get: { appState.calibration.showSkinRig },
            set: { value in
                var next = appState.calibration
                next.showSkinRig = value
                appState.calibration = next
            }
        )) {
            Label("Show translucent skin", systemImage: "eye")
                .font(.subheadline.weight(.medium))
        }
        .disabled(!scene.skinRig.isLoaded)
    }

    private var translationControls: some View {
        controlGroup(title: "Translation", icon: "move.3d") {
            stepPicker(
                title: "Move step",
                value: Bindable(appState).skinTranslationStep,
                values: [("10 cm", 0.10), ("5 cm", 0.05), ("1 cm", 0.01)]
            )
            axisSlider("X", value: appState.calibration.skinOffset.x, range: -1...1,
                       step: appState.skinTranslationStep, unit: "m", tint: .red) {
                setTranslation(axis: 0, value: $0)
            }
            axisSlider("Y", value: appState.calibration.skinOffset.y, range: -1...1,
                       step: appState.skinTranslationStep, unit: "m", tint: .green) {
                setTranslation(axis: 1, value: $0)
            }
            axisSlider("Z", value: appState.calibration.skinOffset.z, range: -1...1,
                       step: appState.skinTranslationStep, unit: "m", tint: .blue) {
                setTranslation(axis: 2, value: $0)
            }
        }
    }

    private var rotationControls: some View {
        controlGroup(title: "Rotation", icon: "rotate.3d") {
            stepPicker(
                title: "Rotate step",
                value: Bindable(appState).skinRotationStepDegrees,
                values: [("1°", 1), ("2°", 2), ("5°", 5), ("10°", 10)]
            )
            axisSlider("X", value: appState.calibration.skinRotationDegrees.x, range: -180...180,
                       step: appState.skinRotationStepDegrees, unit: "°", tint: .red, decimals: 0) {
                setRotation(axis: 0, value: $0)
            }
            axisSlider("Y", value: appState.calibration.skinRotationDegrees.y, range: -180...180,
                       step: appState.skinRotationStepDegrees, unit: "°", tint: .green, decimals: 0) {
                setRotation(axis: 1, value: $0)
            }
            axisSlider("Z", value: appState.calibration.skinRotationDegrees.z, range: -180...180,
                       step: appState.skinRotationStepDegrees, unit: "°", tint: .blue, decimals: 0) {
                setRotation(axis: 2, value: $0)
            }
        }
    }

    private var scaleControl: some View {
        controlGroup(title: "Scale", icon: "arrow.up.left.and.arrow.down.right") {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { appState.calibration.skinScale },
                        set: { setSkinScale($0) }
                    ),
                    in: 0.02...1.0,
                    step: 0.001
                )
                .tint(.pink)

                Text(String(format: "%.3f×", appState.calibration.skinScale))
                    .font(.caption.monospacedDigit())
                    .frame(width: 66, alignment: .trailing)
            }
        }
    }

    private var confirmationControls: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                appState.resetSkinAlignment()
                scene.skinRig.clearConfirmation(keepingCurrentPose: false)
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                confirmAlignment()
            } label: {
                Label("Confirm & Map", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(
                scene.skinRig.isBound
                    || !scene.skinRig.isLoaded
                    || scene.lastPhantomWorld.isEmpty
            )

            Button(role: .destructive) {
                unlockAlignment()
            } label: {
                Label("Unbind", systemImage: "link.badge.minus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!scene.skinRig.isBound)
        }
    }

    private var mappingSummary: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Manual alignment uses only the palm. After confirmation, the hidden forearm root rotates around the locked wrist to follow the forearm direction.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(scene.skinRig.mappingRows) { row in
                    HStack(spacing: 8) {
                        Text(row.skinJointLabel)
                            .font(.caption2.monospaced())
                            .frame(width: 82, alignment: .leading)
                        Image(systemName: "arrow.left")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(row.arkitJoint.map(CalibrationData.friendlyName(for:)) ?? "Unmapped")
                            .font(.caption2)
                        Spacer()
                    }
                }

                if !scene.skinRig.unmappedARKitJoints.isEmpty {
                    Divider()
                    Text("Tracking points inherited by the skin")
                        .font(.caption.weight(.semibold))
                    Text(scene.skinRig.unmappedARKitJoints.map(CalibrationData.friendlyName(for:)).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("These fingertip and forearm points have no separate deform bone in this asset; their visible motion follows the mapped parent bone.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()
                HStack(spacing: 8) {
                    Text("Wrist root")
                        .font(.caption2.monospaced())
                        .frame(width: 82, alignment: .leading)
                    Image(systemName: "arrow.left")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Forearm wrist + forearm arm")
                        .font(.caption2)
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Label(
                "Controls: \(scene.skinRig.controlPointCount) / 27",
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            )
            .font(.subheadline.weight(.medium))
        }
        .tint(.pink)
    }

    private func controlGroup<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(14)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepPicker(
        title: String,
        value: Binding<Float>,
        values: [(String, Float)]
    ) -> some View {
        Picker(title, selection: value) {
            ForEach(values, id: \.1) { label, value in
                Text(label).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    private func axisSlider(
        _ axis: String,
        value: Float,
        range: ClosedRange<Float>,
        step: Float,
        unit: String,
        tint: Color,
        decimals: Int = 2,
        setValue: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(axis)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Slider(
                value: Binding(get: { value }, set: setValue),
                in: range,
                step: step
            )
            .tint(tint)
            Text(String(format: "%+.*f%@", decimals, value, unit))
                .font(.caption.monospacedDigit())
                .frame(width: 82, alignment: .trailing)
        }
    }

    private func setTranslation(axis: Int, value: Float) {
        var next = appState.calibration
        next.setSkinTranslation(axis: axis, value: value)
        invalidateAlignment(&next)
    }

    private func setRotation(axis: Int, value: Float) {
        var next = appState.calibration
        next.setSkinRotation(axis: axis, degrees: value)
        invalidateAlignment(&next)
    }

    private func setSkinScale(_ value: Float) {
        var next = appState.calibration
        next.skinScale = min(1.0, max(0.02, value))
        invalidateAlignment(&next)
    }

    private func invalidateAlignment(_ next: inout CalibrationData) {
        next.skinAlignmentConfirmed = false
        appState.calibration = next
        scene.skinRig.clearConfirmation()
    }

    private func confirmAlignment() {
        guard scene.skinRig.confirmAlignment(
            referenceWorld: scene.lastPhantomWorld,
            isLiveTracked: scene.isShowingTrackedHand
        ) else { return }
        var next = appState.calibration
        next.skinAlignmentConfirmed = true
        appState.calibration = next
    }

    private func unlockAlignment() {
        var next = appState.calibration
        next.skinAlignmentConfirmed = false
        appState.calibration = next
        scene.skinRig.clearConfirmation()
    }
}
