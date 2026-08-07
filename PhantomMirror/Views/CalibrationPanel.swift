import SwiftUI

struct CalibrationPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate phantom hand")
                .font(.title2.bold())
            Text("Move the virtual phantom until it sits where you feel the missing limb. Use this for telescoping (shortened phantom) compensation.")
                .font(.callout)
                .foregroundStyle(.secondary)

            offsetControls
            scaleControls
            yawControls

            Text(appState.trackingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset") {
                    appState.calibration = CalibrationData()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Start training") {
                    appState.beginTraining()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 360, maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var offsetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position offset (m)").font(.headline)
            axisRow("X (left/right)") {
                appState.calibration.phantomOffset.x -= CalibrationData.offsetStep
            } plus: {
                appState.calibration.phantomOffset.x += CalibrationData.offsetStep
            } value: {
                appState.calibration.phantomOffset.x
            }
            axisRow("Y (up/down)") {
                appState.calibration.phantomOffset.y -= CalibrationData.offsetStep
            } plus: {
                appState.calibration.phantomOffset.y += CalibrationData.offsetStep
            } value: {
                appState.calibration.phantomOffset.y
            }
            axisRow("Z (forward/back)") {
                appState.calibration.phantomOffset.z -= CalibrationData.offsetStep
            } plus: {
                appState.calibration.phantomOffset.z += CalibrationData.offsetStep
            } value: {
                appState.calibration.phantomOffset.z
            }
        }
    }

    private var scaleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phantom scale").font(.headline)
            HStack {
                Button("-") {
                    appState.calibration.phantomScale = max(0.5, appState.calibration.phantomScale - CalibrationData.scaleStep)
                }
                Text(String(format: "%.2f×", appState.calibration.phantomScale))
                    .monospacedDigit()
                    .frame(minWidth: 60)
                Button("+") {
                    appState.calibration.phantomScale = min(1.5, appState.calibration.phantomScale + CalibrationData.scaleStep)
                }
            }
        }
    }

    private var yawControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yaw").font(.headline)
            Slider(
                value: Binding(
                    get: { appState.calibration.phantomYawRadians },
                    set: { appState.calibration.phantomYawRadians = $0 }
                ),
                in: -0.6...0.6
            )
            Text(String(format: "%.0f°", appState.calibration.phantomYawRadians * 180 / Float.pi))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func axisRow(
        _ title: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void,
        value: @escaping () -> Float
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("-", action: minus)
            Text(String(format: "%+.2f", value()))
                .monospacedDigit()
                .frame(minWidth: 56)
            Button("+", action: plus)
        }
        .font(.callout)
    }
}
