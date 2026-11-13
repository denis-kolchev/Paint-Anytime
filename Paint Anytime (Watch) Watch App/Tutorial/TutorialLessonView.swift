import SwiftUI
import WatchKit

/// A floating coach card that leaves the exercise's layout unchanged.
struct TutorialLessonView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    var maximumCardHeight: CGFloat? = nil
    @Binding var confirmsFinish: Bool
    /// Set while a chapter result will grow into the continuation question: the result
    /// shows a checkmark instead of Next, and tapping it asks at once.
    var onShowContinuation: (() -> Void)? = nil
    /// Set while the card fills the screen and asks whether to continue the tour.
    var continuation: TutorialContinuationActions? = nil
    @State private var completionProgress: CGFloat = 0
    @State private var revealsResultAction = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var instructionFontSize: CGFloat = 11

    var body: some View {
        ZStack {
            if let continuation {
                // Inserted without a fade: the copy and buttons fade in on their own once the card has grown.
                TutorialContinuationContent(actions: continuation)
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .opacity.animation(.easeInOut(duration: 0.15))))
            } else {
                // Returning from the question, the next hint waits until the card has nearly
                // finished shrinking; leaving for it, the result fades out at once.
                compactCard
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25)
                            .delay(reduceMotion ? 0 : 0.32)),
                        removal: .opacity.animation(.easeInOut(duration: 0.15))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: continuation == nil ? nil : .infinity)
        .background(.regularMaterial, in: cardShape)
        .overlay {
            cardShape.stroke(.white.opacity(0.16), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: displayedInstruction)
        // The expanded card reaches the display edges; its rounded corners lie beyond the screen's.
        .padding(continuation == nil ? edgeGap : 0)
        .task(id: tutorial.step) {
            await animateCompletion()
        }
        .onChange(of: action) { _, action in
            if action != .exit {
                WKInterfaceDevice.current().play(.success)
            }
        }
    }

    /// Before and during the continuation question the result only says it is done;
    /// the question itself asks about the rest.
    private var displayedInstruction: String {
        tutorial.step == .chapterComplete && (onShowContinuation != nil || continuation != nil)
            ? L10n.text("Chapter complete!") : tutorial.instruction
    }

    private var compactCard: some View {
        TutorialHintLayout(maximumHeight: min(screenHeight * 0.32, maximumCardHeight ?? .infinity)) {
            // Keep one layout child while the old and new copy crossfade.
            // The independent measurement below sizes the card for the new copy.
            ZStack {
                TutorialInstructionText(
                    text: displayedInstruction,
                    isPaused: confirmsFinish,
                    fontSize: instructionFontSize
                )
                .id(displayedInstruction)
                .transition(.opacity)
            }

            Button(role: action == .exit ? .destructive : nil) {
                switch action {
                case .exit:
                    tutorial.pauseReminders()
                    confirmsFinish = true
                case .next:
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                        tutorial.continueToNext()
                    }
                case .done:
                    if let onShowContinuation, tutorial.step == .chapterComplete {
                        onShowContinuation()
                    } else {
                        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                            onFinish()
                        }
                    }
                }
            } label: {
                ZStack {
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                        .opacity(action == .exit ? 1 : 0)
                        .scaleEffect(action != .exit && !reduceMotion ? 0.6 : 1)
                    // Results use the neutral tint of the other toolbar controls.
                    Image(systemName: "arrow.forward")
                        .foregroundStyle(.white)
                        .opacity(action == .next ? 1 : 0)
                        .scaleEffect(action == .next || reduceMotion ? 1 : 0.6)
                        .tutorialHint(tutorial, steps: [.chapterComplete], isSuggested: action == .next)
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .opacity(action == .done ? 1 : 0)
                        .scaleEffect(action == .done || reduceMotion ? 1 : 0.6)
                        // Before the continuation question it also blinks, inviting a tap.
                        .modifier(TutorialResultBlink(isActive: action == .done && onShowContinuation != nil))
                        .tutorialHint(tutorial, steps: [.chapterComplete, .finished], isSuggested: action == .done)
                }
                .font(.system(size: 11, weight: .semibold))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: action)
            }
            .tint(action == .exit ? .red : .white)
            .buttonStyle(TutorialOverlayButtonStyle(diameter: 24, hitDiameter: 32))
            .overlay {
                TutorialProgressRing(progress: tutorial.chapterProgress, completionProgress: completionProgress)
                    .frame(width: 32, height: 32)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(L10n.text(action == .exit ? "Finish tutorial" : action == .next ? "Next chapter" : "Done"))
            .accessibilityValue(L10n.format("%d of %d lessons completed",
                                            tutorial.completedLessonCount, tutorial.lessonCount))

            // Measure the full copy independently of the scroll viewport.
            Text(displayedInstruction)
                .font(.system(size: instructionFontSize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @MainActor
    private func animateCompletion() async {
        // A chapter first fills its ring, then offers Next or Done.
        guard tutorial.step == .chapterComplete || tutorial.step == .finished else {
            completionProgress = 0
            revealsResultAction = false
            return
        }
        guard !revealsResultAction else { return }
        if reduceMotion {
            completionProgress = 1
            revealsResultAction = true
            return
        }
        do {
            withAnimation(.linear(duration: 0.7)) {
                completionProgress = 1
            }
            // Keep the completed green ring visible before revealing Next or Done.
            try await Task.sleep(for: .milliseconds(800))
            try Task.checkCancellation()
            withAnimation(.easeInOut(duration: 0.2)) {
                revealsResultAction = true
            }
        } catch {
            // Leaving the card or changing lessons cancels the sequence.
        }
    }

    private enum Action { case exit, next, done }

    private var action: Action {
        switch tutorial.step {
        case .chapterComplete where revealsResultAction: onShowContinuation == nil ? .next : .done
        case .finished where revealsResultAction: .done
        default: .exit
        }
    }

    private let edgeGap: CGFloat = 10

    private var cardShape: TutorialHintShape {
        TutorialHintShape(expandedRadius: screenWidth * 0.09)
    }
}

private struct TutorialProgressRing: View {
    let progress: Double
    let completionProgress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(Color(white: 0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
            Circle()
                .trim(from: 0, to: completionProgress)
                .stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}

/// Dims and restores the result checkmark in step with the bounce of `tutorialHint`.
private struct TutorialResultBlink: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimmed = false

    func body(content: Content) -> some View {
        let blinks = isActive && !reduceMotion && scenePhase == .active
        content
            .opacity(blinks && dimmed ? 0.35 : 1)
            .task(id: blinks) {
                dimmed = false
                guard blinks else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeInOut(duration: 0.3)) { dimmed = true }
                        try await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeInOut(duration: 0.3)) { dimmed = false }
                    }
                } catch {
                    dimmed = false
                }
            }
    }
}

/// Later and Continue on the expanded first-chapter result.
struct TutorialContinuationActions {
    /// The course just finished; its row gets the checkmark.
    let completedChapter: TutorialChapter?
    let onLater: () -> Void
    let onContinue: () -> Void
}

/// The lesson card grown to the whole screen after the first chapter of the first-launch
/// tour: the question fades in, then the choice below it. The compact card's green ring
/// and checkmark have already shown the success, so nothing travels between the two.
/// A ScrollView is safe here: the card covers the canvas, so nothing else wants the Crown.
private struct TutorialContinuationContent: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    let actions: TutorialContinuationActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var showsTitle = false
    @State private var showsCompletion = false
    @State private var showsChoices = false
    @State private var isLeaving = false
    /// Later replaces the choice with the same notice the initial decline shows,
    /// instead of leaving immediately.
    @State private var showsLaterNotice = false

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 12) {
                    if showsLaterNotice {
                        laterNotice
                    } else {
                        Text(L10n.text("Continue the tour?"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(showsTitle ? 1 : 0)
                        // Both courses and their length; the finished one is checked off a moment later.
                        VStack(spacing: 6) {
                            ForEach(TutorialChapter.allCases) { chapter in
                                TutorialCourseRow(chapter: chapter,
                                                  isCompleted: showsCompletion && chapter == actions.completedChapter)
                            }
                        }
                        .opacity(showsTitle ? 1 : 0)
                        ConfirmationButtonsLayout(layoutDirection: layoutDirection) {
                            // Measures both labels: the longer one gets the width the other spares.
                            Button(action: tapLater) {
                                Text(L10n.text("Later"))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .watchActionButtonStyle()
                            // Green like the completed ring: the chapter went well, go on.
                            Button(action: continueTour) {
                                Text(L10n.text("Continue"))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .watchProminentActionButtonStyle()
                            .tint(.green)
                        }
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .opacity(showsChoices ? 1 : 0)
                        .offset(y: showsChoices || reduceMotion ? 0 : 6)
                        .allowsHitTesting(showsChoices)
                        .accessibilityHidden(!showsChoices)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                // Centered on a large display; scrolls from the top when the copy is longer.
                .frame(minHeight: viewport.size.height)
            }
        }
        .task { await reveal() }
    }

    /// Replaces the choice with the same notice the initial decline shows, then
    /// finishes the tutorial once the user acknowledges it.
    private var laterNotice: some View {
        VStack(spacing: 10) {
            Text(L10n.text("You can start the tutorial anytime: tap the three dots, then Tutorial."))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("OK")) {
                guard !isLeaving else { return }
                isLeaving = true
                // The iris covers the screen, so nothing needs to fade first.
                actions.onLater()
            }
            .watchActionButtonStyle()
        }
        .transition(.opacity)
    }

    /// The question fades out on the full-size card first; only then does the notice
    /// fade in, so the two never overlap.
    private func tapLater() {
        guard !isLeaving, !showsLaterNotice else { return }
        guard !reduceMotion else {
            showsLaterNotice = true
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            showsTitle = false
            showsCompletion = false
            showsChoices = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeIn(duration: 0.2)) { showsLaterNotice = true }
        }
    }

    /// The question fades out on the full-size card first; only then does the card shrink
    /// onto the next hint, so the two texts never overlap.
    private func continueTour() {
        guard !isLeaving else { return }
        isLeaving = true
        guard !reduceMotion else {
            actions.onContinue()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            showsTitle = false
            showsCompletion = false
            showsChoices = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            actions.onContinue()
        }
    }

    /// Lets the card finish growing, shows the question and the courses, checks off the
    /// finished course a second later, then shows the choice.
    @MainActor
    private func reveal() async {
        guard !reduceMotion else {
            showsTitle = true
            showsCompletion = true
            showsChoices = true
            return
        }
        withAnimation(.easeInOut(duration: 0.25).delay(0.2)) { showsTitle = true }
        do {
            try await Task.sleep(for: .milliseconds(1450))
            withAnimation(.spring(duration: 0.4, bounce: 0.4)) { showsCompletion = true }
            try await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeOut(duration: 0.3)) { showsChoices = true }
        } catch {
            // Leaving the question cancels the sequence.
        }
    }
}

/// A course with its icon and length; a green checkmark appears once it is finished.
private struct TutorialCourseRow: View {
    let chapter: TutorialChapter
    let isCompleted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chapter.systemImage)
                .font(.system(size: 17))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.title)
                    .font(.footnote.weight(.semibold))
                Text(L10n.format("%d min", chapter.estimatedMinutes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            ZStack {
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCompleted ? L10n.text("Completed") : "")
    }
}

private struct TutorialHintShape: Shape {
    let expandedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Blend out of the capsule as the card grows, without a corner jump
        // when an animated height crosses the compact-card threshold.
        let expansion = min(1, max(0, (rect.height - 52) / 20))
        let radius = (rect.height / 2) * (1 - expansion) + expandedRadius * expansion
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// Shrink to the actual text; only overflowing lessons use the full height budget.
private struct TutorialHintLayout: Layout {
    let maximumHeight: CGFloat
    private let leadingInset: CGFloat = 18
    private let trailingInset: CGFloat = 8
    private let verticalInset: CGFloat = 10
    private let buttonDiameter: CGFloat = 32
    private let buttonSpacing: CGFloat = 8

    private func textWidth(_ width: CGFloat) -> CGFloat {
        max(1, width - leadingInset - trailingInset - buttonDiameter - buttonSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 180
        guard subviews.count == 3 else { return CGSize(width: width, height: 0) }
        let textProposal = ProposedViewSize(width: textWidth(width), height: nil)
        let textHeight = subviews[2].sizeThatFits(textProposal).height
        let naturalHeight = max(buttonDiameter + trailingInset * 2,
                                textHeight + verticalInset * 2)
        return CGSize(width: width, height: min(naturalHeight, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = textWidth(bounds.width)
        let textProposal = ProposedViewSize(width: width, height: nil)
        let instructionHeight = min(subviews[2].sizeThatFits(textProposal).height,
                                    max(1, bounds.height - verticalInset * 2))
        let top = bounds.midY - instructionHeight / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + leadingInset, y: top),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: instructionHeight))
        subviews[1].place(at: CGPoint(x: bounds.maxX - trailingInset - buttonDiameter / 2, y: bounds.midY),
                          anchor: .center,
                          proposal: ProposedViewSize(width: buttonDiameter, height: buttonDiameter))
        subviews[2].place(at: bounds.origin, anchor: .topLeading, proposal: textProposal)
    }
}

/// Scroll the copy with offsets, not a native ScrollView. On watchOS 10 a
/// newly inserted ScrollView can become a Crown target even with focusable(false).
/// The lesson card is recreated for every instruction, so it must never compete
/// with the canvas or the tool editor for Crown input.
private struct TutorialInstructionText: View {
    let text: String
    let isPaused: Bool
    let fontSize: CGFloat
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var contentHeight: CGFloat = 0
    @State private var isManualScrolling = false
    @State private var scrollOffset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @GestureState private var isDragging = false

    private struct Playback: Equatable {
        let overflow: CGFloat
        let isEnabled: Bool
    }

    var body: some View {
        GeometryReader { viewport in
            let overflow = max(0, contentHeight - viewport.size.height)
            let playback = Playback(
                overflow: overflow,
                isEnabled: !isPaused && scenePhase == .active && !reduceMotion
                    && !voiceOverEnabled && !isManualScrolling
            )
            Text(text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: TutorialInstructionHeight.self,
                                               value: content.size.height)
                    }
                }
                .offset(y: -min(overflow, max(0, scrollOffset)))
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .onPreferenceChange(TutorialInstructionHeight.self) { contentHeight = $0 }
                .gesture(DragGesture(minimumDistance: 3)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { value in
                        isManualScrolling = true
                        if dragOrigin == nil { dragOrigin = scrollOffset }
                        scrollOffset = min(overflow, max(0, (dragOrigin ?? 0) - value.translation.height))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .onChange(of: isDragging) { _, dragging in
                    if !dragging { dragOrigin = nil }
                }
                .onChange(of: fontSize) { _, _ in
                    // A new text size changes wrapping. Start at the first line
                    // and let the updated measurement restart overflow playback.
                    scrollOffset = 0
                    dragOrigin = nil
                    isManualScrolling = false
                }
                .task(id: playback) {
                    guard playback.isEnabled, playback.overflow > 1 else { return }
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(1.5))
                            // Small offset updates keep manual dragging aligned
                            // with the visible text if it interrupts playback.
                            while scrollOffset < playback.overflow {
                                try await Task.sleep(for: .milliseconds(50))
                                try Task.checkCancellation()
                                guard !isManualScrolling else { return }
                                scrollOffset = min(playback.overflow, scrollOffset + 0.4)
                            }
                            try await Task.sleep(for: .seconds(1.5))
                            try Task.checkCancellation()
                            guard !isManualScrolling else { return }
                            scrollOffset = 0
                        }
                    } catch {
                        // Disappearance, a new lesson or manual scrolling cancels playback.
                    }
                }
        }
    }
}

private struct TutorialInstructionHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Reserve space for controls without resizing the canvas or its artwork.
private struct TutorialHintReservedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var tutorialHintReservedHeight: CGFloat {
        get { self[TutorialHintReservedHeightKey.self] }
        set { self[TutorialHintReservedHeightKey.self] = newValue }
    }
}
