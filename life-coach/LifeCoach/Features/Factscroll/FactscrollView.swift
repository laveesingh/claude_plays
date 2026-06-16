import SwiftUI

/// The Factscroll tab: a reels/shorts-style vertical snap-scroll feed of
/// AI-generated facts. Each fact is a full-bleed slide — a topic-derived gradient
/// background with the fact text overlaid (large, legible, scrimmed for contrast)
/// and a right-side rail of like / dislike / note / share actions. Infinite: the
/// store tops up the buffer as the visible index advances, and a shimmer slide
/// covers any tail-end generation so the user never lands on an empty slide.
///
/// Paging is the iOS 17 `ScrollView` + `LazyVStack` recipe:
/// `.containerRelativeFrame(.vertical)` per slide, `.scrollTargetLayout()` on the
/// stack, `.scrollTargetBehavior(.paging)` on the scroll view, and
/// `.scrollPosition(id:)` to track which slide is visible (which drives buffering).
struct FactscrollView: View {
    @StateObject private var store: FactscrollStore
    @EnvironmentObject private var router: Router

    /// The id of the slide currently snapped into view. `nil` until the first
    /// slide settles. Drives buffer top-ups.
    @State private var visibleID: FeedSlide.ID?

    /// One-shot guard so we only auto-position the feed once per view lifetime.
    @State private var didInitialPosition = false

    init(store: AppStore) {
        _store = StateObject(wrappedValue: FactscrollStore(store: store))
    }

    /// The feed is the facts plus, while generating, a trailing shimmer slide so
    /// scrolling to the end never reveals emptiness.
    private var slides: [FeedSlide] {
        var result = store.facts.map(FeedSlide.fact)
        if store.isGenerating {
            result.append(.shimmer)
        } else if store.lastLoadFailed {
            result.append(.retry)
        }
        return result
    }

    var body: some View {
        GeometryReader { _ in
            content
        }
        .ignoresSafeArea()
        .background(Color.black)
        // Hide nav chrome for an immersive, full-bleed feel.
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .task {
            // Position BEFORE topping up: if we opened with a backlog of already-
            // seen facts (a returning user), jump straight to the newest one so the
            // very next scroll is fresh content — not a long climb past old facts.
            // A first-ever open (no cache) leaves the feed at the top, where every
            // fact is new.
            if !didInitialPosition {
                didInitialPosition = true
                if let newest = store.facts.last?.id.uuidString {
                    visibleID = newest
                }
            }
            await store.loadInitialIfNeeded()
        }
        // Re-tapping the Factscroll tab takes the user to the newest fact (the
        // bottom of the barrel), repurposing the default "scroll to top".
        .onChange(of: router.factscrollResetToken) { _, _ in
            if let newest = store.facts.last?.id.uuidString {
                visibleID = newest
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if slides.isEmpty {
            FirstLoadView()
        } else {
            feed
        }
    }

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(slides) { slide in
                    slideView(for: slide)
                        .containerRelativeFrame(.vertical)
                        .id(slide.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleID)
        .scrollIndicators(.hidden)
        .onChange(of: visibleID) { _, _ in
            Task { await bufferIfNeeded() }
        }
        .onChange(of: store.facts.count) { oldCount, newCount in
            // The shimmer/retry tail just resolved into real facts. If the user is
            // parked on that tail, re-anchor onto the first new fact (the same
            // on-screen slot the tail occupied) so the scroll doesn't jam on the
            // now-removed tail id.
            guard newCount > oldCount,
                  visibleID == FeedSlide.tailID,
                  oldCount < store.facts.count else { return }
            visibleID = store.facts[oldCount].id.uuidString
        }
    }

    @ViewBuilder
    private func slideView(for slide: FeedSlide) -> some View {
        switch slide {
        case .fact(let fact):
            FactSlide(fact: fact, store: store)
        case .shimmer:
            ShimmerSlide()
        case .retry:
            RetrySlide { Task { await store.retry() } }
        }
    }

    /// Drive the store's buffer policy from the currently-visible fact's index.
    private func bufferIfNeeded() async {
        guard case .fact(let fact)? = slides.first(where: { $0.id == visibleID }),
              let index = store.facts.firstIndex(where: { $0.id == fact.id }) else { return }
        await store.bufferIfNeeded(visibleIndex: index)
    }
}

// MARK: - Feed slide model

/// A renderable slide: either a real fact or the trailing shimmer placeholder.
private enum FeedSlide: Identifiable {
    case fact(Fact)
    case shimmer
    case retry

    /// shimmer and retry share ONE stable tail id, so a loading→failed transition
    /// keeps the same scroll identity and never jams the slide being viewed.
    static let tailID = "feed-tail"

    var id: String {
        switch self {
        case .fact(let fact): return fact.id.uuidString
        case .shimmer, .retry: return Self.tailID
        }
    }
}

// MARK: - Fact slide

/// One full-screen fact: gradient background, scrim, big fact text, topic chip,
/// and the right-side action rail.
private struct FactSlide: View {
    let fact: Fact
    @ObservedObject var store: FactscrollStore

    @State private var image: FactImage?
    @State private var showingNote = false
    @State private var noteDraft = ""

    var body: some View {
        ZStack {
            background
            scrim
            foreground
        }
        .clipped()
        .task(id: fact.id) {
            image = await store.cover(for: fact)
        }
        .sheet(isPresented: $showingNote) {
            NoteSheet(initialText: fact.note ?? "") { text in
                store.addNote(fact, text: text)
            }
        }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        if let image {
            ZStack {
                // The topic gradient is always present: it's the base, the photo's
                // load placeholder, and the fallback if there's no photo / it fails.
                LinearGradient(
                    colors: [image.startColor.color, image.endColor.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let remote = image.remoteURL {
                    // Real Unsplash photo, full-bleed over the gradient.
                    AsyncImage(url: remote) { phase in
                        switch phase {
                        case .success(let photo):
                            photo.resizable().scaledToFill()
                        case .empty, .failure:
                            symbolMotif(image.symbol)
                        @unknown default:
                            symbolMotif(image.symbol)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // No network image — the faint SF Symbol motif is the texture.
                    symbolMotif(image.symbol)
                }
            }
        } else {
            Color.black
        }
    }

    /// The faint, oversized SF Symbol drawn as texture when there's no photo.
    @ViewBuilder
    private func symbolMotif(_ symbol: String?) -> some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 280))
                .foregroundStyle(.white.opacity(0.08))
                .rotationEffect(.degrees(-12))
                .offset(x: 90, y: -120)
        }
    }

    /// A bottom-weighted scrim so white text stays legible over any gradient.
    private var scrim: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.55)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    // MARK: Foreground

    private var foreground: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)
                TopicChip(topic: fact.topic)
                Text(fact.text)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.6)   // shrink an unusually long fact instead of clipping it
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)   // pin width to the slide, never overflow
                if let note = fact.note, !note.isEmpty {
                    Label(note, systemImage: "note.text")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ActionRail(
                reaction: fact.reaction,
                hasNote: (fact.note?.isEmpty == false),
                shareText: fact.text,
                onLike: { store.react(fact, .like) },
                onDislike: { store.react(fact, .dislike) },
                onNote: {
                    noteDraft = fact.note ?? ""
                    showingNote = true
                }
            )
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 90)
        .padding(.top, 70)
    }
}

// MARK: - Topic chip

private struct TopicChip: View {
    let topic: String

    var body: some View {
        Text(topic.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Action rail

/// The right-side vertical rail: like, dislike, note, share.
private struct ActionRail: View {
    let reaction: Reaction
    let hasNote: Bool
    let shareText: String
    let onLike: () -> Void
    let onDislike: () -> Void
    let onNote: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            RailButton(
                systemImage: reaction == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                tint: reaction == .like ? .green : .white,
                action: onLike
            )
            RailButton(
                systemImage: reaction == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tint: reaction == .dislike ? .red : .white,
                action: onDislike
            )
            RailButton(
                systemImage: hasNote ? "note.text" : "square.and.pencil",
                tint: hasNote ? .yellow : .white,
                action: onNote
            )
            // Share the fact text directly via the system share sheet.
            ShareLink(item: shareText) {
                railIcon(systemImage: "square.and.arrow.up", tint: .white)
            }
        }
    }

    private func railIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            .background(.black.opacity(0.22), in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

private struct RailButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.22), in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Note sheet

/// A small sheet with a `TextField` for attaching a note to a fact.
private struct NoteSheet: View {
    let initialText: String
    let onSave: (String) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(initialText: String, onSave: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Why does this land — or not? Notes tune your feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Add a note…", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding()
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(240), .medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Shimmer placeholder slide

/// The trailing slide shown while the next batch generates: an animated shimmer
/// over a neutral gradient so the tail of the feed never goes empty.
private struct ShimmerSlide: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color(white: 0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                shimmerBar(widthFraction: 0.35, height: 22)
                shimmerBar(widthFraction: 0.9, height: 34)
                shimmerBar(widthFraction: 0.75, height: 34)
                shimmerBar(widthFraction: 0.5, height: 34)
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Finding something surprising…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 110)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
    }

    private func shimmerBar(widthFraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.10))
                .frame(width: geo.size.width * widthFraction)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.18), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * widthFraction)
                        .offset(x: phase * geo.size.width * widthFraction)
                        .mask(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .frame(width: geo.size.width * widthFraction)
                        )
                )
        }
        .frame(height: height)
    }
}

// MARK: - First load

/// Shown before the very first batch arrives (feed empty, generating).
private struct FirstLoadView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Loading your feed…")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

// MARK: - Retry slide

/// A stable tail slide shown when a generation attempt failed or came back empty.
/// It shares the shimmer's identity, so a slow/failed load never leaves the feed
/// silently stuck — the user lands on this and can tap to try again.
private struct RetrySlide: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 14) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Couldn't load more")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("The model may be slow or busy. Tap to try again — or switch to a faster model (Kimi) in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
    }
}
