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
        VStack(alignment: .leading, spacing: 20) {
            header
            stepPicker

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(CalibrationData.JointGroup.allCases) { group in
                        groupSection(group)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 340)

            selectedJointEditor

            dumpSection
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bone Calibration")
                .font(.headline)
            Text("Select a bone and adjust its local X/Y/Z offset. A glowing marker shows the selected joint.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }

    // MARK: - Step size

    private var stepPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adjustment Step")
                .font(.subheadline.weight(.medium))
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

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .font(.body)
                    .foregroundStyle(isSelectedGroup ? .teal : .secondary)
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if tuned > 0 {
                    Text("\(tuned) tuned")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                    Button {
                        appState.resetOffsets(in: group)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.orange)
                    .help("Reset every offset in \(group.displayName)")
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(group.joints, id: \.self) { joint in
                    jointChip(joint)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelectedGroup ? Color.teal.opacity(0.05) : Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelectedGroup ? Color.teal.opacity(0.3) : Color.clear,
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
                    .fill(hasOffset ? Color.orange : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(CalibrationData.friendlyName(for: joint))
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.teal.opacity(0.15) : Color.black.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.teal : Color.clear,
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

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(CalibrationData.friendlyName(for: joint))
                        .font(.subheadline.weight(.semibold))
                }
                Text("Parent-local translation (meters)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 12) {
                axisRow("X", label: "left ⇄ right", value: value.x, axis: 0)
                axisRow("Y", label: "down ⇅ up", value: value.y, axis: 1)
                axisRow("Z", label: "back ⇄ forward", value: value.z, axis: 2)
            }

            Text(String(format: "Offset: %.4f, %.4f, %.4f m", value.x, value.y, value.z))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func axisRow(_ title: String, label: String, value: Float, axis: Int) -> some View {
        let step = appState.jointOffsetStep
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            Button {
                appState.nudgeSelectedJoint(axis: axis, delta: -step)
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)

            Text(String(format: "%+.4f", value))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .frame(minWidth: 80, alignment: .center)

            Button {
                appState.nudgeSelectedJoint(axis: axis, delta: step)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
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
                .padding(12)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } label: {
            HStack {
                Image(systemName: "doc.on.doc")
                Text("Export tuned offsets")
            }
            .font(.caption.weight(.medium))
        }
        .tint(.teal)
    }
}
