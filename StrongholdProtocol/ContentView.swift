import SwiftUI

struct ContentView: View {
    @State private var tapCount = 0

    var body: some View {
        // String literals in Text/Button/Label are localization keys resolved
        // through Localizable.xcstrings automatically. Interpolate variables
        // inside the literal ("Tap count: \(tapCount)") instead of
        // concatenating strings, so the whole phrase stays translatable.
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Airbuild is ready")
                    .font(.title.bold())

                Text("Tap count: \(tapCount)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tap-count")

                Button("Tap me") {
                    tapCount += 1
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("primary-action")
            }
            .padding()
            .navigationTitle("Starter")
        }
    }
}

#Preview {
    ContentView()
}
