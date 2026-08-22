import AVKit
import SwiftUI

// MARK: - Inbox

/// Instagram's Direct inbox: username header, local-only search, and plain
/// thread rows separated by hairlines.
struct MessagesScreen: View {
    @ObservedObject private var store: AppStore
    @State private var query = ""

    init(store: AppStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.separator)
                searchField
                threadList
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.primaryText)
        .task { await store.loadThreads() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(store.account?.username ?? "")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search", text: $query)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .fieldBackground()
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var threadList: some View {
        let threads = filteredThreads

        if store.isLoadingThreads && store.threads.isEmpty {
            Spacer(minLength: 0)
            ProgressView().tint(Theme.secondaryText)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                if threads.isEmpty {
                    Text(emptyMessage)
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(threads) { thread in
                            NavigationLink {
                                ThreadDetailView(store: store, thread: thread)
                            } label: {
                                ThreadRow(thread: thread)
                            }
                            .buttonStyle(.plain)

                            if thread.id != threads.last?.id {
                                Divider()
                                    .overlay(Theme.separator)
                                    .padding(.leading, Theme.gutter * 2 + Theme.avatarThread)
                            }
                        }
                    }
                }
            }
            .refreshable { await store.loadThreads(reset: true) }
        }
    }

    private var emptyMessage: String {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No conversations yet."
            : "No conversations match that search."
    }

    /// Filters the already-loaded threads. Direct search never hits the API.
    private var filteredThreads: [DirectThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.threads }
        return store.threads.filter { thread in
            thread.title.lowercased().contains(needle)
                || thread.users.contains { $0.username.lowercased().contains(needle) }
        }
    }
}

private struct ThreadRow: View {
    let thread: DirectThread

    var body: some View {
        HStack(spacing: Theme.gutter) {
            Avatar(
                url: thread.users.first?.avatar,
                initial: thread.users.first?.username ?? thread.title,
                size: Theme.avatarThread
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(preview)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let stamp = thread.messages.first?.timestamp {
                Text(relativeStamp(stamp))
                    .font(Theme.timestamp)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(Theme.background)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let latest = thread.messages.first else { return "" }
        if latest.text.isEmpty && latest.media != nil { return "Sent an attachment" }
        return latest.text
    }
}

// MARK: - Thread detail

private struct ThreadDetailView: View {
    @ObservedObject var store: AppStore
    let thread: DirectThread

    @State private var messages: [DirectMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var loadError: String?
    @State private var selectedReel: InstagramMedia?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if isLoading {
                    ProgressView()
                        .tint(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await load() }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if messages.isEmpty {
                    Text("No messages in this conversation yet.")
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcript(bubbleWidth: geometry.size.width * 0.72)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Avatar(
                        url: thread.users.first?.avatar,
                        initial: thread.users.first?.username ?? thread.title,
                        size: 28
                    )
                    Text(thread.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
            }
        }
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            MessageComposer(text: $draft, isSending: isSending, onSend: send)
        }
        .task { await load() }
        .alert(
            "Message not sent",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $selectedReel) { SharedReelPlayer(media: $0) }
    }

    private func transcript(bubbleWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            maxWidth: bubbleWidth,
                            sender: sender(for: message),
                            onOpenReel: { selectedReel = $0 }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 10)
            }
            // Short conversations rest on the composer, as Instagram's do.
            .defaultScrollAnchor(.bottom)
            // Fires once when the transcript loads and once per successful send.
            .onChange(of: messages.count) { _, _ in
                proxy.scrollTo(messages.last?.id, anchor: .bottom)
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            // The API returns newest-first; the transcript reads oldest-first.
            messages = try await store.messages(threadID: thread.id).reversed()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Group threads show who is speaking; one-to-one threads do not need it.
    private func sender(for message: DirectMessage) -> ProfileSummary? {
        guard !message.sentByViewer, thread.users.count > 1 else { return nil }
        let id = message.senderId.lowercased()
        return thread.users.first { $0.id == id || $0.username.lowercased() == id }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        Task {
            do {
                let sent = try await store.sendMessage(threadID: thread.id, text: trimmed)
                draft = ""
                messages.append(sent)
            } catch {
                // Keep the draft so the typed text survives a failed send.
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}

private struct MessageBubble: View {
    let message: DirectMessage
    let maxWidth: CGFloat
    let sender: ProfileSummary?
    let onOpenReel: (InstagramMedia) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.sentByViewer {
                Spacer(minLength: 0)
            } else if let sender {
                Avatar(profile: sender, size: 20)
            }

            VStack(alignment: message.sentByViewer ? .trailing : .leading, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(background)
                        .clipShape(
                            RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                        )
                }

                if let media = message.media {
                    attachment(media)
                }
            }
            .frame(
                maxWidth: maxWidth,
                alignment: message.sentByViewer ? .trailing : .leading
            )

            if !message.sentByViewer {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func attachment(_ media: InstagramMedia) -> some View {
        if media.kind == .reel {
            // A Reel is playable only when it was explicitly shared into this thread.
            if media.sharedReel {
                Button {
                    onOpenReel(media)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16))
                        Text("Watch shared Reel")
                            .font(Theme.caption)
                    }
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(background)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        } else {
            RemoteImage(url: media.thumbnail ?? media.media)
                .frame(width: maxWidth, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var background: Color {
        message.sentByViewer ? Theme.accent : Theme.surface
    }
}

private struct MessageComposer: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)

            HStack(spacing: 8) {
                TextField("Message...", text: $text)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.primaryText)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .fieldBackground()

                if isSending {
                    ProgressView()
                        .tint(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.accent.opacity(canSend ? 1 : 0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        }
        .background(Theme.background)
    }
}

// MARK: - Shared Reel

/// Plays a Reel that arrived in a direct message. Deliberately a dead end:
/// no next, no previous, no suggestions, no autoplay chain.
struct SharedReelPlayer: View {
    @Environment(\.dismiss) private var dismiss

    private let media: InstagramMedia
    @State private var player: AVPlayer?

    init(media: InstagramMedia) {
        self.media = media
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                Text("This Reel can only be played from the message it was shared in.")
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                // Legibility over arbitrary video frames, not decoration.
                .shadow(color: Theme.background.opacity(0.7), radius: 4, y: 1)
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 10)
        }
        .onAppear {
            guard media.sharedReel, media.kind == .reel, let url = media.media else { return }
            let created = AVPlayer(url: url)
            player = created
            created.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Helpers

/// Instagram's compact inbox stamp: "now", "5m", "2h", "3d", "6w", then a date.
private func relativeStamp(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    switch seconds {
    case ..<60:
        return "now"
    case ..<3600:
        return "\(Int(seconds / 60))m"
    case ..<86_400:
        return "\(Int(seconds / 3600))h"
    case ..<604_800:
        return "\(Int(seconds / 86_400))d"
    case ..<3_024_000:
        return "\(Int(seconds / 604_800))w"
    default:
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
