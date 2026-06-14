import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var engine: CoachEngine
    @EnvironmentObject private var router: Router

    @StateObject private var voice = VoiceController()
    @StateObject private var synth = SpeechSynth()

    @State private var draft = ""
    @State private var showVoice = false
    @State private var voiceCompletion: ((String) -> Void)?
    @FocusState private var inputFocused: Bool

    private func presentVoice(_ completion: @escaping (String) -> Void) {
        voiceCompletion = completion
        showVoice = true
    }

    var body: some View {
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
        .sheet(isPresented: $showVoice) {
            VoiceInputView(voice: voice) { finalText in
                showVoice = false
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { voiceCompletion?(trimmed) }
                voiceCompletion = nil
            } onCancel: {
                showVoice = false
                voiceCompletion = nil
            }
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
    }

    private var missingKeyBanner: some View {
        Button {
            router.showSettings = true
        } label: {
            Label("Add your \(store.state.ai.provider.keyLabel) in Settings to activate your coach",
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
                        VStack(alignment: .leading, spacing: 8) {
                            MessageBubble(message: message,
                                          isSpeaking: synth.speakingMessageID == message.id,
                                          onSpeak: message.role == "assistant" ? { synth.toggle(message) } : nil)
                            if let request = message.inputRequest,
                               message.role == "assistant",
                               message.id == store.state.chat.last?.id,
                               !engine.isResponding {
                                StructuredInputView(request: request,
                                                    disabled: engine.isResponding,
                                                    presentVoice: presentVoice) { summary in
                                    inputFocused = false
                                    submit(summary)
                                }
                            }
                        }
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
            .scrollDismissesKeyboard(.interactively)
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
                inputFocused = false
                presentVoice { transcript in
                    draft = draft.isEmpty ? transcript : draft + " " + transcript
                    inputFocused = true
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak")
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                submit(text)
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

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await engine.send(trimmed) }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var isSpeaking: Bool = false
    var onSpeak: (() -> Void)? = nil

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !isUser, !message.text.isEmpty, let onSpeak {
                    Button(action: onSpeak) {
                        Label(isSpeaking ? "Stop" : "Listen",
                              systemImage: isSpeaking ? "stop.circle" : "speaker.wave.2")
                            .labelStyle(.iconOnly)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }
}
