import SwiftUI

struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    @State private var confirmsFinish = false
    @State private var didConfirmFinish = false

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.format("Lesson %d of 20", tutorial.step.rawValue))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(TutorialLesson.description(for: tutorial.step))
                    Text(L10n.text("When you are ready, tap Next."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            .hideTopScrollEdgeEffectIfAvailable()
            HStack(spacing: 8) {
                Button {
                    tutorial.pauseReminders()
                    confirmsFinish = true
                } label: {
                    Text(L10n.text("Finish"))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchActionButtonStyle()
                .tint(.red)
                .foregroundStyle(.red)

                Button {
                    if tutorial.step == .openTools { TutorialDebug.startNextTrace() }
                    TutorialDebug.trace("next.action.enter", tutorial.debugState)
                    defer { TutorialDebug.trace("next.action.exit", tutorial.debugState) }
                    if tutorial.step == .finished {
                        tutorial.stop()
                        onFinish()
                    } else { tutorial.beginExercise() }
                } label: {
                    Text(L10n.text("Next"))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchActionButtonStyle()
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .vertical)
        .onDisappear { TutorialDebug.trace("lessonCard.disappear", tutorial.debugState) }
        .fullScreenCover(isPresented: $confirmsFinish, onDismiss: {
            if didConfirmFinish {
                didConfirmFinish = false
                tutorial.stop()
                onFinish()
            } else {
                tutorial.resumeReminders()
            }
        }) {
            DestructiveConfirmationView(
                title: L10n.text("Are you sure you want to finish the tutorial?"),
                confirmTitle: L10n.text("Yes")
            ) {
                confirmsFinish = false
            } onConfirm: {
                didConfirmFinish = true
                confirmsFinish = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func hideTopScrollEdgeEffectIfAvailable() -> some View {
        if #available(watchOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
