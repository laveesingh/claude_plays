import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var router: Router

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !engine.hasAPIKey {
                    missingKeyBanner
                }
                messageList
                if let error = engine.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                inputBar
            }
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var missingKeyBanner: some View {
        Button {
            router.selectedTab = .settings
        } label: {
            Label("Add your Anthropic API key in Settings to activate your coach",
                  systemImage: "key.fill")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.yellow.opacity(0.2))
        }
        .buttonStyle(.plain)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.state.chat.isEmpty && engine.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(store.state.chat) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if !engine.streamingText.isEmpty {
                        MessageBubble(message: ChatMessage(role: "assistant", text: engine.streamingText))
                            .id("streaming")
                    } else if engine.isResponding {
                        HStack {
                            ProgressView()
                            Text("Coach is thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .id("streaming")
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: store.state.chat.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: engine.streamingText) {
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Your coach is on the clock.")
                .font(.headline)
            Text("Start a morning check-in from the Today tab, or just say what's on your mind.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: AnyHashable
        if engine.streamingText.isEmpty && !engine.isResponding, let lastID = store.state.chat.last?.id {
            target = AnyHashable(lastID)
        } else {
            target = AnyHashable("streaming")
        }
        if animated {
            withAnimation { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message your coach", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task {
                    await engine.send(text)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(engine.isResponding || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }
}
