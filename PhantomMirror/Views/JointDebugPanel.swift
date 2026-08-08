import SwiftUI
import ARKit
import simd

/// Per-joint local translation tuner for diagnosing mirrored hand retargeting.
struct JointDebugPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Joint offsets")
                .font(.title3.bold())
            Text("Nudge any phantom joint in parent-local space (meters). Use this to fix spacing after mirroring.")
                .font(.caption)
                .foregroundStyle(.secondary)

            stepPicker

            HStack(alignment: .top, spacing: 12) {
                jointList
                    .frame(minWidth: 160, maxWidth: 200, maxHeight: 280)
                offsetEditor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

    private var stepPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step").font(.subheadline.weight(.semibold))
            Picker("Step", selection: Bindable(appState).jointOffsetStep) {
                Text("1 mm").tag(Float(0.001))
                Text("2 mm").tag(Float(0.002))
                Text("5 mm").tag(Float(0.005))
                Text("1 cm").tag(Float(0.01))
            }
            .pickerStyle(.segmented)
        }
    }

    private var jointList: some View {
        List(CalibrationData.adjustableJoints, id: \.self) { joint in
            let offset = appState.calibration.offset(for: joint)
            let hasOffset = simd_length_squared(offset) > 1e-12
            Button {
                appState.selectedJoint = joint
            } label: {
                HStack {
                    Text(CalibrationData.jointKey(joint))
                        .font(.caption.monospaced())
                        .foregroundStyle(appState.selectedJoint == joint ? .primary : .secondary)
                    Spacer()
                    if hasOffset {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .listRowBackground(
                appState.selectedJoint == joint
                    ? Color.accentColor.opacity(0.22)
                    : Color.clear
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var offsetEditor: some View {
        let joint = appState.selectedJoint
        let value = appState.calibration.offset(for: joint)
        return VStack(alignment: .leading, spacing: 10) {
            Text(CalibrationData.jointKey(joint))
                .font(.headline.monospaced())
            Text("Local translation relative to parent bone")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            axisRow("X", value: value.x, axis: 0)
            axisRow("Y", value: value.y, axis: 1)
            axisRow("Z", value: value.z, axis: 2)

            Text(String(format: "Current: (%.4f, %.4f, %.4f) m", value.x, value.y, value.z))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func axisRow(_ title: String, value: Float, axis: Int) -> some View {
        let step = appState.jointOffsetStep
        return HStack {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 20, alignment: .leading)
            Button("−") {
                appState.nudgeSelectedJoint(axis: axis, delta: -step)
            }
            .buttonStyle(.bordered)
            Text(String(format: "%+.4f", value))
                .font(.body.monospacedDigit())
                .frame(minWidth: 88)
            Button("+") {
                appState.nudgeSelectedJoint(axis: axis, delta: step)
            }
            .buttonStyle(.bordered)
        }
    }

    private var dumpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tuned offsets")
                .font(.caption.weight(.semibold))
            Text(appState.calibration.jointOffsetsDebugDump)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
