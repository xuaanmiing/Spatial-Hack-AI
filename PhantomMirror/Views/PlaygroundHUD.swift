import SwiftUI

struct PlaygroundHUD: View {
    @Environment(AppState.self) private var appState
    @Environment(BrickBuilderPlayground.self) private var bricks

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text("Playground")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.teal.opacity(0.15), in: Capsule())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(String(format: "%.0f ms", appState.handUpdateIntervalMs))
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(appState.handUpdateIntervalMs > 33 ? .orange : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(bricks.title)
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text(bricks.instruction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }

            Text(bricks.progressText)
                .font(.headline)

            Label(
                bricks.isHoldingBrick ? "Holding brick" : "Brick released",
                systemImage: bricks.isHoldingBrick ? "hand.pinch.fill" : "square.and.arrow.down"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(appState.trackingStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button("Reset") {
                    bricks.resetScene()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Exit Playground") {
                    appState.endPlayground()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.2, green: 0.55, blue: 0.55))
            }
        }
        .padding(24)
        .frame(minWidth: 360, maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
