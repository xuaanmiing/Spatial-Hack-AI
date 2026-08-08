import SwiftUI

struct TrainingHUD: View {
    @Environment(AppState.self) private var appState
    @Environment(TaskManager.self) private var tasks
    @Environment(AudioFeedback.self) private var audio

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let taskCount = TaskManager.TaskKind.allCases.count
            let lastTaskIndex = max(0, taskCount - 1)
            let progress = Double(appState.currentTaskIndex) / Double(taskCount)

            // Header Section
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                        Text("Task \(appState.currentTaskIndex + 1) of \(taskCount)")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.teal.opacity(0.15), in: Capsule())
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Button {
                            audio.isEnabled.toggle()
                            if !audio.isEnabled { audio.stopAmbient() } else { audio.startAmbient() }
                        } label: {
                            Image(systemName: audio.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(audio.isEnabled ? .teal : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Divider().frame(height: 12)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(String(format: "%.0f ms", appState.handUpdateIntervalMs))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(appState.handUpdateIntervalMs > 33 ? .orange : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.tertiary.opacity(0.3))
                            .frame(height: 6)
                        
                        Capsule()
                            .fill(.teal)
                            .frame(width: max(0, geometry.size.width * progress), height: 6)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
                    }
                }
                .frame(height: 6)
            }

            Divider()

            // Task Content Section
            VStack(alignment: .leading, spacing: 8) {
                Text(tasks.current.title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                
                Text(appState.taskInstruction.isEmpty ? tasks.current.instruction : appState.taskInstruction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }

            // Status Section
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: tasks.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.title2)
                        .foregroundStyle(tasks.isComplete ? .green : .teal)
                        .symbolEffect(.bounce, value: tasks.isComplete)
                    
                    Text(tasks.progressText)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(tasks.isComplete ? .green : .primary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    tasks.isComplete ? Color.green.opacity(0.1) : Color.teal.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(appState.trackingStatus)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            // Controls Section
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    appState.session.tasksCompleted = appState.currentTaskIndex + (tasks.isComplete ? 1 : 0)
                    tasks.clearSceneProps()
                    appState.finishTraining()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.8, green: 0.3, blue: 0.3)) // Softer, less saturated red
                
                Button("Skip") {
                    if tasks.advanceIfPossible() {
                        appState.currentTaskIndex = tasks.current.rawValue
                        appState.taskInstruction = tasks.current.instruction
                        audio.play(.taskAdvance)
                    } else {
                        appState.session.tasksCompleted = taskCount
                        tasks.clearSceneProps()
                        appState.finishTraining()
                    }
                }
                .buttonStyle(.bordered)
                .font(.title3.weight(.semibold))
                .padding(.vertical, 4)

                Spacer()

                Button {
                    if tasks.isComplete {
                        appState.session.tasksCompleted += 1
                    }
                    if appState.currentTaskIndex >= lastTaskIndex && tasks.isComplete {
                        tasks.clearSceneProps()
                        appState.finishTraining()
                    } else if tasks.advanceIfPossible() {
                        appState.currentTaskIndex = tasks.current.rawValue
                        appState.taskInstruction = tasks.current.instruction
                        audio.play(.taskAdvance)
                    } else {
                        tasks.clearSceneProps()
                        appState.finishTraining()
                    }
                } label: {
                    HStack {
                        Text(tasks.isComplete && appState.currentTaskIndex >= lastTaskIndex ? "Complete Session" : "Next Task")
                        Image(systemName: tasks.isComplete && appState.currentTaskIndex >= lastTaskIndex ? "flag.checkered" : "arrow.right")
                    }
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.2, green: 0.55, blue: 0.55)) // Softer, less saturated teal
                .disabled(!tasks.isComplete)
                .contextMenu {
                    Button("Force next (demo skip)") {
                        _ = tasks.advanceIfPossible()
                        appState.currentTaskIndex = tasks.current.rawValue
                        appState.taskInstruction = tasks.current.instruction
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Subtle border for definition
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
    }
}
