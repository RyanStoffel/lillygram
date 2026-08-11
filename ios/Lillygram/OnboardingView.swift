import SwiftUI

/// "<marketing version> (<build number>)", e.g. "0.1.0 (2)", read from the
/// bundle so Settings/bug reports never show a stale hardcoded string.
let appVersionString: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
}()

/// Favorites picker used in two places: the one-time post-login onboarding
/// (fullscreen, with a Skip option) and the star tab (always available, for
/// editing after onboarding — including after skipping it).
///
/// Defaults to the full list of accounts the user follows so selection is a
/// tap-through; the search field filters that list and also hits Instagram's
/// search for accounts the user doesn't follow. Both requests run through the
/// logged-in webview (see WebViewStore), so this only works with a session.
struct FavoritesPickerView: View {
    enum Mode {
        case onboarding
        case editor
    }

    let mode: Mode
    @ObservedObject var favoritesStore: FavoritesStore
    let loadFollowing: () async -> [FavoriteProfile]
    let search: (String) async -> [FavoriteProfile]
    let onCommit: ([FavoriteProfile]) -> Void
    let onSkip: (() -> Void)?

    @State private var query = ""
    @State private var following: [FavoriteProfile] = []
    @State private var remoteResults: [FavoriteProfile] = []
    @State private var selection: [FavoriteProfile] = []
    @State private var isLoadingFollowing = false
    @State private var isSearching = false
    @State private var didSave = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                if !selection.isEmpty { selectedStrip }
                profileList
                footer
            }
            .toolbar {
                if mode == .editor {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Settings and Support")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView(favoritesStore: favoritesStore)
        }
        // The presenting view tints everything .primary (white in dark mode),
        // which would make the prominent Save button white-on-white.
        .tint(.blue)
        .onAppear {
            selection = favoritesStore.favorites
        }
        .task {
            guard following.isEmpty else { return }
            isLoadingFollowing = true
            following = (await loadFollowing()).sorted {
                $0.username.lowercased() < $1.username.lowercased()
            }
            isLoadingFollowing = false
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                remoteResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            remoteResults = await search(trimmed)
            isSearching = false
        }
    }

    private var displayed: [FavoriteProfile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return following }
        let local = following.filter {
            $0.username.lowercased().contains(q) || $0.fullName.lowercased().contains(q)
        }
        let localIDs = Set(local.map(\.id))
        return local + remoteResults.filter { !localIDs.contains($0.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .onboarding ? "Build your feed" : "Your favorites")
                .font(.largeTitle.bold())
            Text(mode == .onboarding
                 ? "Pick the accounts you actually want to see. Your home feed will only show their posts. This also updates your official Instagram Favorites list."
                 : "Your home feed only shows posts from these accounts. Saving changes also updates your official Instagram Favorites list.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 24)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your following or all of Instagram", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isSearching {
                ProgressView()
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 20)
    }

    private var selectedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selection) { profile in
                    chip(for: profile)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 12)
    }

    private var profileList: some View {
        List(displayed) { profile in
            row(for: profile)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .overlay {
            if isLoadingFollowing && following.isEmpty {
                ProgressView("Loading accounts you follow…")
            } else if displayed.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No accounts found" : "No matches",
                    systemImage: "person.2",
                    description: Text(query.isEmpty
                        ? "Couldn't load your following list. Try searching instead."
                        : "Keep typing to search all of Instagram.")
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCommit(selection)
                didSave = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didSave = false
                }
            } label: {
                Text(saveButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mode == .onboarding && selection.isEmpty)

            if mode == .onboarding, let onSkip {
                Button("Skip for now") {
                    onSkip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if mode == .editor {
                HStack(spacing: 12) {
                    Button("Report a Bug") {
                        showSettings = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text("•")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Link("Privacy", destination: URL(string: "https://ryanstoffel.github.io/lillygram/privacy.html")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Link("Terms", destination: URL(string: "https://ryanstoffel.github.io/lillygram/terms.html")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private var saveButtonTitle: String {
        if didSave { return "Saved ✓" }
        switch mode {
        case .onboarding:
            return selection.isEmpty ? "Done" : "Done — \(selection.count) selected"
        case .editor:
            return selection.isEmpty ? "Save and turn off filter" : "Save — \(selection.count) selected"
        }
    }

    private func isSelected(_ profile: FavoriteProfile) -> Bool {
        selection.contains { $0.id == profile.id }
    }

    private func toggle(_ profile: FavoriteProfile) {
        UISelectionFeedbackGenerator().selectionChanged()
        if let index = selection.firstIndex(where: { $0.id == profile.id }) {
            selection.remove(at: index)
        } else {
            selection.append(profile)
        }
    }

    private func row(for profile: FavoriteProfile) -> some View {
        Button {
            toggle(profile)
        } label: {
            HStack(spacing: 12) {
                avatar(for: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.username)
                        .font(.subheadline.weight(.semibold))
                    if !profile.fullName.isEmpty {
                        Text(profile.fullName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected(profile) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isSelected(profile) ? Color.blue : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func chip(for profile: FavoriteProfile) -> some View {
        Button {
            toggle(profile)
        } label: {
            HStack(spacing: 6) {
                avatar(for: profile, size: 20)
                Text(profile.username)
                    .font(.footnote.weight(.medium))
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func avatar(for profile: FavoriteProfile, size: CGFloat) -> some View {
        AsyncImage(url: profile.avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Settings and support sheet for bug reporting and legal terms.
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var favoritesStore: FavoritesStore
    @State private var showBugReport = false
    @State private var isTutorialActive = false

    private static let tutorialSteps: [TutorialStep] = [
        TutorialStep(
            id: "bug",
            title: "Something broken? Report it.",
            message: "Lillygram is in beta, so rough edges happen. Tap \u{201c}Report a Bug\u{201d} anytime and it goes straight to Ryan\u{2019}s tracker."
        ),
        TutorialStep(
            id: "beta",
            title: "You\u{2019}re running a beta build",
            message: "Instagram changes often, and Lillygram has to keep up. Expect occasional hiccups \u{2014} reporting them here is what keeps it working."
        ),
        TutorialStep(
            id: "tour",
            title: "Come back anytime",
            message: "Forget how this works? Tap \u{201c}Take the Tour\u{201d} here in Settings & Support to see this walkthrough again."
        )
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Support") {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug")
                            .foregroundStyle(.primary)
                    }
                    .tutorialTarget("bug")

                    Button {
                        startTutorial()
                    } label: {
                        Label("Take the Tour", systemImage: "sparkles")
                            .foregroundStyle(.primary)
                    }
                    .tutorialTarget("tour")
                }

                Section("Legal") {
                    Link(destination: URL(string: "https://ryanstoffel.github.io/lillygram/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                            .foregroundStyle(.primary)
                    }
                    Link(destination: URL(string: "https://ryanstoffel.github.io/lillygram/terms.html")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                            .foregroundStyle(.primary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Beta")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.pink, in: .capsule)
                    }
                    .tutorialTarget("beta")
                }
            }
            .navigationTitle("Settings & Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showBugReport) {
                BugReportView()
            }
        }
        .tutorialOverlay(steps: Self.tutorialSteps, isActive: $isTutorialActive) {
            favoritesStore.hasSeenPreferencesTutorial = true
        }
        .onAppear {
            guard !favoritesStore.hasSeenPreferencesTutorial else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startTutorial()
            }
        }
    }

    private func startTutorial() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isTutorialActive = true
    }
}

/// GitHub API config for the in-app bug reporter. `issuesToken` is supplied
/// through the archive's generated Info.plist so the credential is never
/// committed to this public repository. The token is still extractable from
/// the shipped app, so it must remain scoped to Issues access on only the
/// private `RyanStoffel/lillygram-bugs` repo.
private enum BugReportConfig {
    static let repo = "RyanStoffel/lillygram-bugs"
    static var issuesToken: String {
        Bundle.main.object(forInfoDictionaryKey: "BugReportToken") as? String ?? ""
    }
}

private struct GitHubIssueRequest: Encodable {
    let title: String
    let body: String
}

/// Native bug reporting interface. Reports are filed directly as GitHub
/// Issues on the private `lillygram-bugs` repo (see `BugReportConfig`) —
/// visible only to Ryan there, or via that repo's GitHub Pages dashboard.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reporterName = UserDefaults.standard.string(forKey: "biBugReporterName") ?? ""
    @State private var bugDescription = ""
    @State private var isSending = false
    @State private var didSend = false
    @State private var sendError: String?

    private var canSend: Bool {
        !reporterName.trimmingCharacters(in: .whitespaces).isEmpty
            && !bugDescription.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $reporterName)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("So Ryan knows who ran into this.")
                }

                Section {
                    TextEditor(text: $bugDescription)
                        .frame(minHeight: 120)
                } header: {
                    Text("Describe the issue")
                } footer: {
                    Text("Please describe what happened and how to reproduce it.")
                }

                Section("System Information") {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("iOS Version")
                        Spacer()
                        Text(UIDevice.current.systemVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { sendReport() }
                            .disabled(!canSend)
                    }
                }
            }
            .alert("Report Sent", isPresented: $didSend) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you for helping improve Lillygram!")
            }
            .alert("Couldn't Send Report", isPresented: .constant(sendError != nil), presenting: sendError) { _ in
                Button("OK") { sendError = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private func sendReport() {
        let name = reporterName.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(name, forKey: "biBugReporterName")
        isSending = true

        let summary = bugDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(72)
        let issue = GitHubIssueRequest(
            title: "[\(name)] \(summary)",
            body: """
            **Reported by:** \(name)

            **Description**
            \(bugDescription)

            ---
            App Version: \(appVersionString)
            iOS Version: \(UIDevice.current.systemVersion)
            Device: \(UIDevice.current.model)
            """
        )

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(BugReportConfig.repo)/issues")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(BugReportConfig.issuesToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(issue)

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isSending = false
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    didSend = true
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    sendError = error?.localizedDescription
                        ?? "The server rejected the report (\((response as? HTTPURLResponse)?.statusCode ?? -1)). Please try again."
                }
            }
        }.resume()
    }
}
