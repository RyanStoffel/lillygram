import Foundation
import SwiftUI

enum NavTarget: String, CaseIterable {
    case home
    case search
    case direct
    case profile
}

/// Shared state mirrored out of the web pages for the native chrome:
/// whether Instagram's own nav row is currently mounted (so the tab bar can
/// match its show/hide behavior, e.g. hidden inside an open DM thread), the
/// logged-in user's avatar, and the page background color.
final class WebBridge: ObservableObject {
    @Published var isNavVisible: Bool = true
    @Published var avatarURL: URL?
    @Published var pageBackground: Color = Color(.systemBackground)
    @Published var safeAreaBackground: Color = Color(.systemBackground)
    /// Incremented when the injected star button in the web header is tapped;
    /// ContentView reacts by presenting the favorites editor sheet.
    @Published var favoritesEditRequests = 0
}
