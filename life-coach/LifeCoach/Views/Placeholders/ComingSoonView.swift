import SwiftUI

/// Placeholder shown for not-yet-built features (Inbox, News, Factscroll).
/// Centered icon + "Coming soon" + a one-line teaser. No logic.
struct ComingSoonView: View {
    let feature: AppFeature

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("Coming soon")
                    .font(.title3.weight(.semibold))
                Text(feature.teaser)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(feature.title)
        }
    }
}
