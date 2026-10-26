import SwiftUI

/// First-run welcome: import, displays, and what Lumen does to save power.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0

    private let steps: [(symbol: String, title: String, text: String)] = [
        ("sparkles.tv", "Bring your desktop to life",
         "Lumen plays your videos as a wallpaper behind your icons and windows. Your files stay exactly where they are; Lumen only remembers where to find them."),
        ("display.2", "Made for every display",
         "Give each display its own wallpaper, or span one video across all of them. Lumen remembers your setup when monitors are unplugged and reconnected."),
        ("leaf", "Light on your battery",
         "Wallpapers pause automatically when covered by windows, behind fullscreen apps, on lock, and in Low Power Mode. Fine-tune it all in Performance."),
        ("lock.display", "Your lock screen, too",
         "Pick any frame of a wallpaper for the lock screen and login window. Turn it on in Settings › Lock Screen & Login Window."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            let current = steps[step]
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.35), .clear], center: .center, startRadius: 4, endRadius: 80))
                    .frame(width: 150, height: 150)
                Image(systemName: current.symbol)
                    .font(.system(size: 52, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(spacing: 10) {
                Text(current.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(current.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            .id(step)
            .transition(.opacity)

            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                Button("Skip") { model.completeOnboarding() }
                    .buttonStyle(.borderless)
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                if step < steps.count - 1 {
                    Button("Continue") { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Import Videos…") {
                        model.completeOnboarding()
                        model.isImporterPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: 520)
    }
}
