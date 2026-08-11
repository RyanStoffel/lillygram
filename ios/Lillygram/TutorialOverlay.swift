import SwiftUI

/// One step of an interactive coach-mark walkthrough: a title/message shown
/// beside whichever view was tagged `.tutorialTarget(id)` with a matching id.
struct TutorialStep: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
}

/// Publishes the frame of every view tagged `.tutorialTarget(_:)`, keyed by
/// id, so one overlay elsewhere in the tree can spotlight the right one.
private struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a spotlight target for the tutorial step with the
    /// matching `id` — see `tutorialOverlay(steps:isActive:onFinish:)`.
    func tutorialTarget(_ id: String) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// Cuts `mask`'s shape out of `self` — the inverse of `.mask`.
    @ViewBuilder
    fileprivate func reverseMask(@ViewBuilder _ mask: () -> some View) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }

    /// Drives an interactive, blurred-spotlight walkthrough over whichever
    /// descendant views are tagged `.tutorialTarget(_:)`. Only draws while
    /// `isActive` is true; advances on tap or the callout's controls; flips
    /// `isActive` back to false and calls `onFinish` once the last step is
    /// dismissed (Next on the last step, or Skip at any point).
    func tutorialOverlay(
        steps: [TutorialStep],
        isActive: Binding<Bool>,
        onFinish: @escaping () -> Void = {}
    ) -> some View {
        modifier(TutorialOverlayModifier(steps: steps, isActive: isActive, onFinish: onFinish))
    }
}

private struct TutorialOverlayModifier: ViewModifier {
    let steps: [TutorialStep]
    @Binding var isActive: Bool
    let onFinish: () -> Void

    @State private var index = 0

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if isActive, steps.indices.contains(index), let anchor = anchors[steps[index].id] {
                    TutorialSpotlight(
                        step: steps[index],
                        stepIndex: index,
                        stepCount: steps.count,
                        targetRect: proxy[anchor],
                        containerSize: proxy.size,
                        onAdvance: advance,
                        onSkip: finish
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: index)
            .ignoresSafeArea()
        }
    }

    private func advance() {
        if index >= steps.count - 1 {
            finish()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            index += 1
        }
    }

    private func finish() {
        index = 0
        isActive = false
        onFinish()
    }
}

/// One frame of the walkthrough: a dimmed/blurred scrim with a rounded-rect
/// hole cut around `targetRect`, a glowing outline on the hole, and a callout
/// card with progress dots plus Skip/Next controls.
private struct TutorialSpotlight: View {
    let step: TutorialStep
    let stepIndex: Int
    let stepCount: Int
    let targetRect: CGRect
    let containerSize: CGSize
    let onAdvance: () -> Void
    let onSkip: () -> Void

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        let hole = targetRect.insetBy(dx: -10, dy: -8)
        let calloutAbovehole = hole.midY > containerSize.height * 0.6

        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .reverseMask {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                }
                .onTapGesture(perform: onAdvance)

            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.pink, lineWidth: 3)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
                .shadow(color: .pink.opacity(0.6), radius: 10)
                .allowsHitTesting(false)

            callout
                .frame(width: min(containerSize.width - 48, 340))
                .position(
                    x: containerSize.width / 2,
                    y: calloutAbovehole
                        ? max(hole.minY - 96, 110)
                        : min(hole.maxY + 110, containerSize.height - 110)
                )
        }
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == stepIndex ? Color.pink : Color.secondary.opacity(0.3))
                        .frame(width: i == stepIndex ? 16 : 6, height: 6)
                }
            }
            Text(step.title)
                .font(.headline)
            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(stepIndex == stepCount - 1 ? "Done" : "Next", action: onAdvance)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }
}
