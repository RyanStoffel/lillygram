import SwiftUI

/// Visual tokens matched to Instagram's iOS dark appearance. Every surface reads
/// from here so spacing, weight, and colour stay consistent across the app.
enum Theme {
    // MARK: Colour

    /// True black, as Instagram uses in dark mode.
    static let background = Color.black
    /// Raised fields, search bars, and incoming message bubbles.
    static let surface = Color(red: 0.15, green: 0.15, blue: 0.15)
    /// Hairline dividers between feed posts and list rows.
    static let separator = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.66, green: 0.66, blue: 0.66)
    /// Instagram's action blue, used for links and the primary button.
    static let accent = Color(red: 0.0, green: 0.58, blue: 0.96)
    static let destructive = Color(red: 0.93, green: 0.24, blue: 0.29)

    /// Instagram's unread-story ring sweep.
    static let storyRing = AngularGradient(
        colors: [
            Color(red: 0.98, green: 0.65, blue: 0.19),
            Color(red: 0.96, green: 0.35, blue: 0.15),
            Color(red: 0.87, green: 0.16, blue: 0.48),
            Color(red: 0.51, green: 0.20, blue: 0.69),
            Color(red: 0.32, green: 0.36, blue: 0.83),
            Color(red: 0.98, green: 0.65, blue: 0.19),
        ],
        center: .center
    )

    // MARK: Type

    /// Usernames in the feed, thread list, and profile header.
    static let username = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 14)
    static let secondary = Font.system(size: 13)
    static let timestamp = Font.system(size: 12)
    static let statValue = Font.system(size: 17, weight: .semibold)
    static let wordmark = Font.system(size: 26, weight: .semibold, design: .serif)

    // MARK: Metrics

    static let avatarFeed: CGFloat = 32
    static let avatarStory: CGFloat = 64
    static let avatarThread: CGFloat = 56
    static let avatarProfile: CGFloat = 88
    static let icon: CGFloat = 24
    static let gutter: CGFloat = 12
    /// Instagram's profile grid uses a 1pt gap, not rounded cards.
    static let gridGap: CGFloat = 1
    static let bubbleRadius: CGFloat = 18
}

/// Circular remote avatar with an optional unread-story ring.
struct Avatar: View {
    let url: URL?
    let initial: String
    var size: CGFloat = Theme.avatarFeed
    var ringed: Bool = false

    init(url: URL?, initial: String, size: CGFloat = Theme.avatarFeed, ringed: Bool = false) {
        self.url = url
        self.initial = initial
        self.size = size
        self.ringed = ringed
    }

    init(profile: ProfileSummary, size: CGFloat = Theme.avatarFeed, ringed: Bool = false) {
        self.init(url: profile.avatar, initial: profile.username, size: size, ringed: ringed)
    }

    var body: some View {
        image
            .frame(width: size, height: size)
            .clipShape(Circle())
            .padding(ringed ? 3 : 0)
            .overlay {
                if ringed {
                    Circle().strokeBorder(Theme.storyRing, lineWidth: 2)
                }
            }
    }

    private var image: some View {
        AsyncImage(url: url) { phase in
            if let loaded = phase.image {
                loaded.resizable().scaledToFill()
            } else {
                Circle()
                    .fill(Theme.surface)
                    .overlay {
                        Text(String(initial.prefix(1)).uppercased())
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
            }
        }
    }
}

/// Square remote image used by feed posts and profile grids.
struct RemoteImage: View {
    let url: URL?
    var aspect: CGFloat? = 1

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            case .failure:
                Theme.surface.overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.secondaryText)
                }
            default:
                // Flat placeholder: no shimmer or looping animation.
                Theme.surface
            }
        }
        .modifier(AspectClip(aspect: aspect))
    }
}

private struct AspectClip: ViewModifier {
    let aspect: CGFloat?

    func body(content: Content) -> some View {
        if let aspect {
            content.aspectRatio(aspect, contentMode: .fill).clipped()
        } else {
            content
        }
    }
}

/// Instagram's full-width blue action button.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Rounded grey field used by search and the message composer.
struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface)
            .clipShape(Capsule())
    }
}

extension View {
    func fieldBackground() -> some View { modifier(FieldBackground()) }
}
