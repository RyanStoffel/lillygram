import SwiftUI

let appVersionString: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
}()

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
                    Text("Describe what happened and how to reproduce it. Credentials and session data are never attached.")
                }

                Section("System Information") {
                    LabeledContent("App Version", value: appVersionString)
                    LabeledContent("iOS Version", value: UIDevice.current.systemVersion)
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
                        Button("Send") { Task { await sendReport() } }
                            .disabled(!canSend)
                    }
                }
            }
            .alert("Report Sent", isPresented: $didSend) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you for helping improve Lillygram.")
            }
            .alert("Could Not Send Report", isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )) {
                Button("OK") { sendError = nil }
            } message: {
                Text(sendError ?? "Unknown error")
            }
        }
    }

    private func sendReport() async {
        let name = reporterName.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(name, forKey: "biBugReporterName")
        isSending = true
        defer { isSending = false }

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

        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(BugReportConfig.repo)/issues")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(BugReportConfig.issuesToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(issue)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else {
                throw APIClientError.invalidResponse
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            didSend = true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            sendError = error.localizedDescription
        }
    }
}
