import SwiftUI

struct CalibrationPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.teal)
                    .font(.title2)
                Text("System Calibration")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
            }
            
            VStack(spacing: 0) {
                Picker("Calibration mode", selection: Bindable(appState).calibrationTab) {
                    ForEach(AppState.CalibrationTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()

                Group {
                    switch appState.calibrationTab {
                    case .pose:
                        VStack(alignment: .leading, spacing: 24) {
                            Text("Adjust the virtual phantom arm to match your perceived limb position. Use scale for telescoping compensation.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                            
                            offsetControls
                            scaleControls
                            yawControls
                            
                            Divider()
                            perBoneWristHint
                        }
                        .padding(20)
                    case .joints:
                        JointDebugPanel()
                            .padding(20)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(appState.trackingStatus)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)

            HStack(spacing: 16) {
                Button(role: .destructive) {
                    if appState.calibrationTab == .joints {
                        appState.resetAllJointOffsets()
                    } else {
                        let joints = appState.calibration.jointOffsets
                        var next = CalibrationData()
                        next.jointOffsets = joints
                        appState.calibration = next
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Reset")
                    }
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.8, green: 0.3, blue: 0.3)) // Softer red

                Spacer()

                Button {
                    appState.beginTraining()
                } label: {
                    HStack {
                        Text("Begin Training")
                        Image(systemName: "play.fill")
                    }
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.2, green: 0.55, blue: 0.55)) // Softer teal
            }
        }
        .padding(32)
        .frame(width: 500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
    }

    private var offsetControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spatial Offset")
                .font(.headline)
            
            VStack(spacing: 12) {
                axisRow("X-Axis (Lateral)", icon: "arrow.left.and.right") {
                    appState.calibration.phantomOffset.x -= CalibrationData.offsetStep
                } plus: {
                    appState.calibration.phantomOffset.x += CalibrationData.offsetStep
                } value: {
                    appState.calibration.phantomOffset.x
                }
                
                axisRow("Y-Axis (Vertical)", icon: "arrow.up.and.down") {
                    appState.calibration.phantomOffset.y -= CalibrationData.offsetStep
                } plus: {
                    appState.calibration.phantomOffset.y += CalibrationData.offsetStep
                } value: {
                    appState.calibration.phantomOffset.y
                }
                
                axisRow("Z-Axis (Depth)", icon: "arrow.up.and.down.and.arrow.left.and.right") {
                    appState.calibration.phantomOffset.z -= CalibrationData.offsetStep
                } plus: {
                    appState.calibration.phantomOffset.z += CalibrationData.offsetStep
                } value: {
                    appState.calibration.phantomOffset.z
                }
            }
        }
    }

    private var perBoneWristHint: some View {
        Button {
            appState.selectedJoint = .wrist
            appState.calibrationTab = .joints
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.title3)
                    .foregroundStyle(.teal)
                    .frame(width: 32, height: 32)
                    .background(.teal.opacity(0.15), in: Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Joint Tuning")
                        .font(.subheadline.weight(.semibold))
                    Text("Switch to Joints tab to adjust individual bones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var scaleControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limb Scale (Telescoping)")
                .font(.headline)
            
            HStack(spacing: 16) {
                Button {
                    appState.calibration.phantomScale = max(0.5, appState.calibration.phantomScale - CalibrationData.scaleStep)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                
                Text(String(format: "%.2f×", appState.calibration.phantomScale))
                    .font(.system(.title3, design: .rounded).weight(.medium).monospacedDigit())
                    .frame(minWidth: 80, alignment: .center)
                    .foregroundStyle(.teal)
                
                Button {
                    appState.calibration.phantomScale = min(1.5, appState.calibration.phantomScale + CalibrationData.scaleStep)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var yawControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rotation (Yaw)")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f°", appState.calibration.phantomYawRadians * 180 / Float.pi))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.teal.opacity(0.15), in: Capsule())
            }
            
            HStack(spacing: 12) {
                Image(systemName: "rotate.left")
                    .foregroundStyle(.secondary)
                
                Slider(
                    value: Binding(
                        get: { appState.calibration.phantomYawRadians },
                        set: { appState.calibration.phantomYawRadians = $0 }
                    ),
                    in: -0.6...0.6
                )
                .tint(.teal)
                
                Image(systemName: "rotate.right")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func axisRow(
        _ title: String,
        icon: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void,
        value: @escaping () -> Float
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            
            Text(title)
                .font(.subheadline)
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: minus) {
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                
                Text(String(format: "%+.2f", value()))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .frame(width: 60, alignment: .trailing)
                
                Button(action: plus) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
        }
    }
}
