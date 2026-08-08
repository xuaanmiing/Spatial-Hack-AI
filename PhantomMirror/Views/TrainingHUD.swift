import SwiftUI

struct TrainingHUD: View {
    @Environment(AppState.self) private var appState
    @Environment(TaskManager.self) private var tasks

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let taskCount = TaskManager.TaskKind.allCases.count
            let lastTaskIndex = max(0, taskCount - 1)

            HStack {
                Text("Task \(appState.currentTaskIndex + 1)/\(taskCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.25), in: Capsule())
                Spacer()
                Text(String(format: "%.0f ms/update", appState.handUpdateIntervalMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(tasks.current.title)
                .font(.title3.bold())
            Text(appState.taskInstruction.isEmpty ? tasks.current.instruction : appState.taskInstruction)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(tasks.progressText)
                .font(.headline)
                .foregroundStyle(tasks.isComplete ? .green : .primary)

            Text(appState.trackingStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Button("End session") {
                    appState.session.tasksCompleted = appState.currentTaskIndex + (tasks.isComplete ? 1 : 0)
                    appState.finishTraining()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(tasks.isComplete && appState.currentTaskIndex >= lastTaskIndex ? "Finish" : "Next task") {
                    if tasks.isComplete {
                        appState.session.tasksCompleted += 1
                    }
                    if appState.currentTaskIndex >= lastTaskIndex && tasks.isComplete {
                        appState.finishTraining()
                    } else if tasks.advanceIfPossible() {
                        appState.currentTaskIndex = tasks.current.rawValue
                        appState.taskInstruction = tasks.current.instruction
                    } else {
                        appState.finishTraining()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tasks.isComplete)
                // Allow skip during demo:
                .contextMenu {
                    Button("Force next (demo skip)") {
                        _ = tasks.advanceIfPossible()
                        appState.currentTaskIndex = tasks.current.rawValue
                        appState.taskInstruction = tasks.current.instruction
                    }
                }
            }

            Button("Skip task (demo)") {
                if tasks.advanceIfPossible() {
                    appState.currentTaskIndex = tasks.current.rawValue
                    appState.taskInstruction = tasks.current.instruction
                } else {
                    appState.session.tasksCompleted = taskCount
                    appState.finishTraining()
                }
            }
            .font(.caption)
        }
        .padding(20)
        .frame(minWidth: 340, maxWidth: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
