import SwiftUI
import ARKit
import simd

/// Per-joint local translation tuner for diagnosing mirrored hand retargeting.
///
/// UI is grouped by anatomy (wrist → forearm → thumb → four fingers) so testers
/// can find "the tip of the middle finger" without knowing the underlying enum
/// name. Selecting a joint here also highlights it in the immersive scene via
/// `AppState.selectedJoint`.
struct JointDebugPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stepPicker

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CalibrationData.JointGroup.allCases) { group in
                        groupSection(group)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 340)

            selectedJointEditor

            dumpSection

            HStack {
                Button("Reset selected") {
                    appState.resetSelectedJointOffset()
                }
                .buttonStyle(.bordered)

                Button("Reset all joints") {
                    appState.resetAllJointOffsets()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bone calibration")
                .font(.title3.bold())
            Text("Pick a bone from any group below, then nudge it in X / Y / Z. A glowing marker will appear on the phantom hand so you can see exactly what you are moving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step size

    private var stepPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step size").font(.subheadline.weight(.semibold))
            Picker("Step", selection: Bindable(appState).jointOffsetStep) {
                Text("1 mm").tag(Float(0.001))
                Text("2 mm").tag(Float(0.002))
                Text("5 mm").tag(Float(0.005))
                Text("1 cm").tag(Float(0.01))
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Group section

    @ViewBuilder
    private func groupSection(_ group: CalibrationData.JointGroup) -> some View {
        let tuned = appState.calibration.tunedCount(in: group)
        let isSelectedGroup = CalibrationData.group(for: appState.selectedJoint) == group

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .font(.callout)
                    .foregroundStyle(isSelectedGroup ? Color.accentColor : .secondary)
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if tuned > 0 {
                    Text("\(tuned) tuned")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.18))
                        )
                        .foregroundStyle(.orange)
                    Button {
                        appState.resetOffsets(in: group)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset every offset in \(group.displayName)")
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(group.joints, id: \.self) { joint in
                    jointChip(joint)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelectedGroup ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelectedGroup ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Joint chip (big touch target, human name)

    private func jointChip(_ joint: HandSkeleton.JointName) -> some View {
        let offset = appState.calibration.offset(for: joint)
        let hasOffset = simd_length_squared(offset) > 1e-12
        let isSelected = appState.selectedJoint == joint

        return Button {
            appState.selectedJoint = joint
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(hasOffset ? Color.orange : Color.gray.opacity(0.35))
                    .frame(width: 8, height: 8)
                Text(CalibrationData.friendlyName(for: joint))
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editor for the selected joint

    private var selectedJointEditor: some View {
        let joint = appState.selectedJoint
        let group = CalibrationData.group(for: joint)
        let value = appState.calibration.offset(for: joint)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("›")
                    .foregroundStyle(.tertiary)
                Text(CalibrationData.friendlyName(for: joint))
                    .font(.headline)
            }
            Text("Parent-local translation, in meters. X = across body, Y = up/down, Z = forward/back.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            axisRow("X", label: "left ⇄ right", value: value.x, axis: 0)
            axisRow("Y", label: "down ⇅ up", value: value.y, axis: 1)
            axisRow("Z", label: "back ⇄ forward", value: value.z, axis: 2)

            Text(String(format: "Current offset: %.4f, %.4f, %.4f m", value.x, value.y, value.z))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func axisRow(_ title: String, label: String, value: Float, axis: Int) -> some View {
        let step = appState.jointOffsetStep
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.bold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            Button {
                appState.nudgeSelectedJoint(axis: axis, delta: -step)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)

            Text(String(format: "%+.4f", value))
                .font(.body.monospacedDigit())
                .frame(minWidth: 92)

            Button {
                appState.nudgeSelectedJoint(axis: axis, delta: step)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Debug dump

    private var dumpSection: some View {
        DisclosureGroup {
            Text(appState.calibration.jointOffsetsDebugDump)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Text("Tuned offsets · copy to code")
                .font(.caption.weight(.semibold))
        }
    }
}
