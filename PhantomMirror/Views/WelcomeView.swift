import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // Logo / Icon
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(.teal)
                .symbolEffect(.pulse)
            
            // Title
            VStack(spacing: 16) {
                Text("PhantomMirror")
                    .font(.system(size: 48, design: .rounded).weight(.bold))
                
                Text("Advanced Mirror Therapy for Vision Pro")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Start Button
            Button {
                withAnimation(.easeInOut(duration: 0.5)) {
                    appState.phase = .onboarding
                }
            } label: {
                HStack(spacing: 12) {
                    Text("Get Started")
                        .font(.title3.weight(.bold))
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(Color(red: 0.2, green: 0.55, blue: 0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            
            Spacer()
                .frame(height: 40)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                gradient: Gradient(colors: [Color.teal.opacity(0.15), Color.clear]),
                center: .center,
                startRadius: 50,
                endRadius: 400
            )
        )
    }
}