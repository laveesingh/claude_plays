import SwiftUI

/// Claude-style voice capture: live transcript above a pill containing a cancel
/// button, an audio waveform, and a confirm button.
struct VoiceInputView: View {
    @ObservedObject var voice: VoiceController
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Group {
                if let status = voice.statusMessage {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(.title3)
                        .italic()
                        .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                        .animation(.default, value: voice.transcript)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)

            pill
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .background(Color(.systemBackground))
        .task { await voice.start() }
        .onDisappear { Task { await voice.stop() } }
    }

    private var pill: some View {
        HStack(spacing: 12) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }

            Waveform(levels: voice.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 52)

            Button {
                onConfirm(voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Image(systemName: "checkmark")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(voice.transcript.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor,
                               in: Circle())
            }
            .disabled(voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground),
                    in: Capsule())
    }
}

/// A row of bars whose heights follow the recent audio levels.
private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    let h = max(barWidth, level * geo.size.height)
                    Capsule()
                        .fill(level > 0.08 ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.35))
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}
