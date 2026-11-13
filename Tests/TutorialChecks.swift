import Foundation
import CoreGraphics
import Combine

@main
struct TutorialChecks {
    @MainActor static func main() async throws {
        checkCrownPlacement()
        checkProgress()
        checkStrokeOverlap()
        try await checkSession()
        try await checkWorkspaceAndOnboarding()
        print("PASS: tutorial rules, exploration, observation, workspace isolation, onboarding persistence")
    }

    static func checkCrownPlacement() {
        let screens: [(CGFloat, CGFloat, CGFloat)] = [
            (162, 197, 49), (184, 224, 57), (176, 215, 56), (198, 242, 66),
            (187, 223, 56), (208, 248, 66), (205, 251, 83.5), (211, 257, 85.5)
        ]
        for (width, height, expectedY) in screens {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let right = TutorialCrownPlacement.position(screenBounds: bounds, overlayFrame: bounds, crownOnLeft: false)
            let left = TutorialCrownPlacement.position(screenBounds: bounds, overlayFrame: bounds, crownOnLeft: true)
            precondition(right == CGPoint(x: width - 15, y: expectedY))
            precondition(left == CGPoint(x: 15, y: height - expectedY))
            let insetFrame = CGRect(x: 6, y: 28, width: width - 12, height: height - 44)
            let inset = TutorialCrownPlacement.position(screenBounds: bounds, overlayFrame: insetFrame, crownOnLeft: false)
            precondition(inset.x + insetFrame.minX == right.x && inset.y + insetFrame.minY == right.y,
                         "Safe areas must not shift the Crown hint away from the physical Crown")
        }
        precondition(TutorialCrownPlacement.rightCrownY(screenSize: CGSize(width: 220, height: 280)) == 72.8)
    }

    static func checkProgress() {
        precondition(TutorialChapter.allCases.count == 3)
        for chapter in TutorialChapter.allCases {
            precondition(!chapter.lessons.isEmpty)
            precondition(chapter.lessons.allSatisfy { !$0.steps.isEmpty && !$0.steps.contains(where: \.isResult) })
        }
        // Canvas size arrives in 1.2, so its crop lesson follows the same release gate.
        let teachesCrop: (AppReleaseFeatures) -> Bool = { features in
            TutorialChapter.composition.lessons(features: features).contains { $0.steps.contains(.applyCrop) }
        }
        precondition(teachesCrop(AppReleaseFeatures(version: "1.2")) && !teachesCrop(AppReleaseFeatures(version: "1.1")))
        var progress = TutorialProgress()
        progress.start()
        precondition(progress.chapter == .firstDrawing && progress.step == .firstStrokes)
        precondition(progress.chapterProgress == 0 && progress.completedLessonCount == 0)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.step == .history)
        precondition(progress.record(.history) == .none)
        precondition(progress.record(.history) == .advance)
        progress.advance()
        precondition(progress.step == .zoomCanvas && progress.completedLessonCount == 1,
                     "Lessons within a chapter follow each other without a result")
        precondition(!progress.continueToNext(), "Next only applies to a chapter result")
        precondition(progress.step == .zoomCanvas)
        progress.advance()
        precondition(progress.record(.finishedCamera) == .none)
        precondition(progress.record(.panned) == .advance && progress.hasPanned)
        progress.advance()
        precondition(progress.step == .finishCamera)
        precondition(progress.record(.finishedCamera) == .advance)
        progress.advance()
        precondition(progress.step == .openTools && !progress.hasPanned)
        precondition(progress.record(.openedTools) == .advance)
        progress.advance()
        precondition(progress.step == .pickColor)
        let original = PencilStyle()
        var style = original
        style.color = SIMD4(0.95, 0.18, 0.22, 1)
        precondition(!progress.changedStyle(from: original, to: original, page: 1))
        precondition(!progress.changedStyle(from: original, to: style, page: 0))
        precondition(progress.changedStyle(from: original, to: style, page: 1))
        precondition(progress.visibleToolPages == [0, 1, 2, 3, 4, 5, 6])
        precondition(progress.allowsToolAdjustment(page: 0) && !progress.allowsToolPage(2))
        precondition(progress.allowsToolPage(1) && !progress.allowsToolPage(0))
        progress.advance()
        precondition(progress.completesPageChange(0))
        precondition(progress.allowsToolPage(0) && progress.allowsToolPage(1))
        precondition(!progress.allowsToolPage(5) && !progress.allowsToolPage(2))
        progress.advance()
        style.width = 7
        precondition(progress.changedStyle(from: original, to: style, page: 0))
        progress.advance()
        precondition(progress.step == .openOpacity && progress.completesPageChange(5))
        precondition(progress.allowsToolPage(5) && progress.allowsToolPage(0))
        precondition(!progress.allowsToolPage(2) && !progress.allowsToolPage(4))
        precondition(!progress.completesPageChange(2))
        progress.advance()
        precondition(progress.step == .setOpacity)
        precondition(!progress.changedStyle(from: style, to: style, page: 5))
        let beforeOpacity = style
        style.opacity = 0.5
        precondition(!progress.changedStyle(from: beforeOpacity, to: style, page: 0))
        precondition(progress.changedStyle(from: beforeOpacity, to: style, page: 5))
        var eraser = style
        eraser.instrument = .eraser
        precondition(!progress.changedStyle(from: beforeOpacity, to: eraser, page: 5))
        progress.advance()
        precondition(progress.step == .openTool && progress.completesPageChange(2))
        precondition(progress.allowsToolPage(2) && !progress.allowsToolPage(4))
        progress.advance()
        precondition(progress.step == .selectReed)
        precondition(progress.record(.openedInfo) == .pauseReminders)
        precondition(progress.record(.closedInfo) == .resumeReminders(advance: false))
        precondition(progress.step == .selectReed, "Optional information must not skip tool selection")
        style.instrument = .pen
        precondition(progress.changedStyle(from: original, to: style, page: 2))
        progress.advance()
        precondition(progress.step == .closeTools && progress.record(.closedTools) == .advance)
        progress.advance()
        precondition(progress.step == .reedStrokes && progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.step == .saveDrawing && progress.completedLessonCount == 3)
        for (step, event, effect): (TutorialStep, TutorialProgress.Event, TutorialProgress.Effect) in [
            (.saveDrawing, .saved, .advance),
            (.openMenu, .openedMenu, .advance), (.openGallery, .openedGallery, .advance),
            (.galleryFullscreen, .galleryFullscreen, .advance), (.deleteDrawing, .deleted, .advance),
            (.returnToCanvas, .returnedToCanvas, .advance), (.clearCanvas, .cleared, .showResult)
        ] {
            precondition(progress.step == step && progress.record(event) == effect)
            progress.advance()
        }
        precondition(progress.step == .chapterComplete && progress.chapterProgress == 1)
        precondition(progress.completedLessonCount == TutorialChapter.firstDrawing.lessons.count)

        // The next chapter restarts the ring and needs nothing from the first one.
        precondition(progress.continueToNext())
        precondition(progress.chapter == .tools && progress.step == .holdCircle && progress.chapterProgress == 0)
        precondition(progress.record(.heldCircle) == .advance)
        progress.advance()
        // Perspective: the menu leads to the guides, then a stroke starts on one.
        for (step, event): (TutorialStep, TutorialProgress.Event) in [
            (.openMenu, .openedMenu), (.openCanvasSettings, .openedCanvasSettings),
            (.openPerspective, .openedPerspective)
        ] {
            precondition(progress.step == step && progress.teachesPerspective && progress.record(event) == .advance)
            progress.advance()
        }
        // The chosen guides stay visible briefly before the tour returns to the canvas.
        precondition(progress.step == .choosePerspective && progress.record(.choseVanishingPoints) == .showResult)
        progress.advance()
        precondition(progress.step == .perspectiveStroke && !progress.teachesCrop)
        precondition(progress.record(.stroke) == .none, "A stroke off the guides is a miss")
        precondition(progress.record(.drewAlongGuide) == .advance)
        progress.advance()
        precondition(!progress.teachesPerspective)
        // Fill: the settings open on Tool and stay there until Fill is chosen.
        precondition(progress.step == .openTools && progress.initialToolPage == 1 && !progress.limitsToolsToFill)
        precondition(progress.record(.openedTools) == .advance)
        progress.advance()
        precondition(progress.step == .chooseFill && progress.initialToolPage == 2 && progress.limitsToolsToFill)
        precondition(progress.allowsToolPage(2) && !progress.allowsToolPage(1) && !progress.allowsToolPage(0))
        var fill = PencilStyle()
        fill.instrument = .fill
        var blur = PencilStyle()
        blur.instrument = .blur
        precondition(!progress.changedStyle(from: PencilStyle(), to: blur, page: 2))
        precondition(progress.changedStyle(from: blur, to: fill, page: 2))
        progress.advance()
        precondition(progress.step == .closeTools && !progress.allowsToolPage(1))
        var eraserAfterFill = fill
        eraserAfterFill.instrument = .eraser
        precondition(!progress.changedStyle(from: fill, to: eraserAfterFill, page: 2))
        precondition(progress.step == .chooseFill, "Leaving Fill before closing restores the choice")
        precondition(progress.changedStyle(from: eraserAfterFill, to: fill, page: 2))
        progress.advance()
        precondition(progress.record(.closedTools) == .advance)
        progress.advance()
        precondition(progress.step == .fillCanvas && !progress.limitsToolsToFill)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.filled) == .advance)
        progress.advance()
        precondition(progress.step == .openTools && progress.record(.openedTools) == .advance)
        progress.advance()
        precondition(progress.step == .openCurrentPalette && progress.record(.openedCurrentPalette) == .advance,
                     "The corner button opens the current palette")
        progress.advance()
        precondition(progress.record(.browsedPalettes) == .advance)
        progress.advance()
        precondition(progress.record(.foundNewPalette) == .advance)
        progress.advance()
        precondition(progress.record(.returnedToPalettes) == .none && progress.step == .findNewPalette)
        precondition(progress.record(.foundNewPalette) == .advance)
        progress.advance()
        for event: TutorialProgress.Event in [.createdPalette, .openedColorEditor, .adjustedColor, .savedColor, .closedTools] {
            precondition(progress.record(event) == .advance)
            progress.advance()
        }
        // The palette lesson closes the chapter; it no longer asks for a nib angle.
        precondition(progress.step == .chapterComplete)

        precondition(progress.continueToNext())
        precondition(progress.chapter == .composition && progress.step == .firstStrokes)
        _ = progress.record(.stroke)
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        // Layers: lock transparency, paint inside the strokes, then draw on a new layer.
        for (step, event): (TutorialStep, TutorialProgress.Event) in [
            (.openLayers, .openedLayers), (.openLayerSettings, .openedLayerSettings),
            (.lockTransparency, .lockedTransparency), (.closeLayerSettings, .closedLayerSettings),
            (.closeLayers, .closedLayers), (.openTools, .openedTools)
        ] {
            precondition(progress.step == step && progress.record(event) == .advance)
            progress.advance()
        }
        precondition(progress.step == .pickColor && progress.allowsToolPage(1) && !progress.allowsToolPage(0))
        precondition(progress.locksLessonColor, "Repainting must not return to the strokes' color")
        var recolored = PencilStyle()
        recolored.color = SIMD4(0.1, 0.4, 0.9, 1)
        precondition(progress.changedStyle(from: PencilStyle(), to: recolored, page: 1))
        progress.advance()
        precondition(progress.record(.closedTools) == .advance)
        progress.advance()
        precondition(progress.step == .paintOverStroke && !progress.locksLessonColor)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.paintedOver) == .advance)
        progress.advance()
        for (step, event): (TutorialStep, TutorialProgress.Event) in [
            (.openLayers, .openedLayers), (.addLayer, .addedLayer),
            (.moveLayerDown, .movedLayerDown), (.closeLayers, .closedLayers), (.openTools, .openedTools)
        ] {
            precondition(progress.step == step && progress.record(event) == .advance)
            progress.advance()
        }
        precondition(progress.step == .pickColor && progress.locksLessonColor,
                     "Drawing behind needs a color not yet on the canvas")
        var thirdColor = recolored
        thirdColor.color = SIMD4(0.2, 0.7, 0.35, 1)
        precondition(progress.changedStyle(from: recolored, to: thirdColor, page: 1))
        progress.advance()
        precondition(progress.record(.closedTools) == .advance)
        progress.advance()
        precondition(progress.step == .drawBehindStroke && progress.record(.stroke) == .none,
                     "Only a stroke behind an upper-layer stroke completes the layer-order lesson")
        precondition(progress.record(.drewBehind) == .advance)
        progress.advance()
        precondition(progress.record(.openedLasso) == .advance)
        progress.advance()
        for _ in 0..<3 { precondition(progress.record(.failedLassoSelection) == .none) }
        precondition(progress.step == .openMenu, "Repeated misses end the lasso lesson")
        if AppReleaseFeatures.current.showsCanvasSizeControls {
            for (step, event): (TutorialStep, TutorialProgress.Event) in [
                (.openMenu, .openedMenu), (.openCanvasSettings, .openedCanvasSettings),
                (.openCanvasSize, .openedCanvasSize), (.openCrop, .openedCrop)
            ] {
                precondition(progress.step == step && progress.teachesCrop && progress.record(event) == .advance)
                progress.advance()
            }
            precondition(progress.step == .applyCrop && progress.record(.croppedCanvas) == .showResult)
            progress.advance()
            // Undo restores the cropped edges, redo trims them again.
            precondition(progress.step == .history && progress.record(.history) == .none)
            precondition(progress.record(.history) == .advance)
            progress.advance()
        }
        for (step, event): (TutorialStep, TutorialProgress.Event) in [
            (.openMenu, .openedMenu), (.openGallery, .openedGallery), (.startSelection, .startedSelection)
        ] {
            precondition(progress.step == step && progress.teachesGallerySelection && progress.record(event) == .advance)
            progress.advance()
        }
        precondition(progress.step == .selectDrawings && progress.record(.cancelledSelection) == .none)
        precondition(progress.step == .startSelection, "Leaving selection mode restores its exercise")
        precondition(progress.record(.startedSelection) == .advance)
        progress.advance()
        precondition(progress.record(.deselectedDrawings) == .none && progress.record(.selectedDrawings) == .advance)
        progress.advance()
        precondition(progress.step == .favoriteSelection && progress.record(.deselectedDrawings) == .none)
        precondition(progress.step == .selectDrawings, "Fewer than two pictures restores the selection")
        precondition(progress.record(.selectedDrawings) == .advance)
        progress.advance()
        precondition(progress.record(.favoritedSelection) == .advance)
        progress.advance()
        precondition(progress.step == .returnToCanvas && progress.record(.returnedToCanvas) == .advance)
        progress.advance()
        precondition(progress.step == .finished)
        progress.advance()
        precondition(progress.step == .finished && !progress.continueToNext())

        progress.start(chapters: [.composition])
        precondition(progress.chapter == .composition && progress.step == .firstStrokes)
        progress.stop()
        precondition(progress.chapter == nil)
        progress.start()
        precondition(progress.step == .firstStrokes && !progress.hasPanned && progress.chapter == .firstDrawing)
    }

    static func checkStrokeOverlap() {
        var wide = PencilStyle()
        wide.width = 8
        func stroke(_ points: [SIMD2<Float>]) -> Stroke {
            Stroke(points: points.map { PointerSample(position: $0, pressure: 1, timestamp: 0) }, style: wide)
        }
        let earlier = stroke([SIMD2(0, 0), SIMD2(100, 0)])
        precondition(TutorialStrokeOverlap.paintsOver(stroke([SIMD2(50, 6), SIMD2(50, 40)]), earlier: [earlier]),
                     "Touching the edge of a stroke counts")
        precondition(TutorialStrokeOverlap.paintsOver(stroke([SIMD2(50, -30), SIMD2(50, 30)]), earlier: [earlier]),
                     "A sparse stroke crossing the line counts")
        precondition(!TutorialStrokeOverlap.paintsOver(stroke([SIMD2(0, 20), SIMD2(100, 20)]), earlier: [earlier]))
        precondition(!TutorialStrokeOverlap.paintsOver(stroke([SIMD2(50, 0)]), earlier: []))

        // Stored bottom to top: the moved layer is first, the original layer covers it.
        let crossing = stroke([SIMD2(50, -30), SIMD2(50, 30)])
        var document = CanvasDocument(strokes: [earlier])
        let lower = CanvasLayer(name: "Layer 2", strokes: [crossing])
        document.layers.insert(lower, at: 0)
        precondition(TutorialStrokeOverlap.passesBehind(crossing, on: lower.id, in: document))
        precondition(!TutorialStrokeOverlap.passesBehind(stroke([SIMD2(0, 20), SIMD2(100, 20)]),
                                                         on: lower.id, in: document),
                     "A stroke beside the upper strokes does not pass behind them")
        precondition(!TutorialStrokeOverlap.passesBehind(crossing, on: document.layers[1].id, in: document),
                     "The top layer has nothing above it")
        document.layers[1].strokes = []
        precondition(TutorialStrokeOverlap.passesBehind(crossing, on: lower.id, in: document),
                     "An empty upper layer cannot stall the lesson")
    }

    @MainActor static func checkSession() async throws {
        let session = TutorialSession()
        var notifications = 0
        let subscription = session.objectWillChange.sink { notifications += 1 }
        defer { session.stop(); withExtendedLifetime(subscription) {} }
        precondition(session.allowsDrawing && session.allowsToolPage(4))
        session.start()
        session.record(.stroke)
        session.record(.stroke)
        precondition(session.step == .history && session.chapter == .firstDrawing)
        session.record(.history)
        session.record(.history)
        precondition(session.step == .zoomCanvas && session.completedLessonCount == 1 && session.lessonCount == 4)
        precondition(session.step == .zoomCanvas && !session.canFinishCamera)
        precondition(session.allowsDrawing && session.suggestsCrownRotation)
        precondition(session.showsCrownHint)
        session.usedCrown(in: .zoomCanvas, velocity: 0)
        precondition(session.showsCrownHint, "Focus and idle events must not dismiss the hint")
        session.usedCrown(in: .zoomCanvas, velocity: 0.2)
        session.usedCrown(in: .zoomCanvas, velocity: 0.2)
        precondition(!session.showsCrownHint && session.crownPracticedSteps.count == 1)
        precondition(session.allowsDrawing, "Crown hint must never lock drawing")
        session.record(.stroke)
        precondition(session.step == .zoomCanvas)
        session.changedZoom()
        precondition(session.step == .panCanvas && session.showsPanGuide && session.allowsCanvasZoom)
        session.record(.panned)
        precondition(session.step == .finishCamera && !session.showsPanGuide && session.canFinishCamera)
        session.record(.finishedCamera)
        let revision = session.chapterRevision
        session.continueToNext()
        precondition(session.step == .openTools && session.allowsDrawing && session.chapterRevision == revision)
        session.record(.openedTools)
        precondition(session.step == .pickColor && session.acceptsActions)
        precondition(session.showsCrownHint && session.crownHintIsSubtle)
        session.usedCrown(in: .zoomCanvas, velocity: 0.2)
        precondition(session.showsCrownHint, "An old Crown event must not dismiss the new lesson")
        session.usedCrown(in: .pickColor, velocity: 0.2)
        var style = PencilStyle()
        let old = style
        style.color = SIMD4(0.95, 0.18, 0.22, 1)
        session.changedStyle(from: old, to: style, page: 1)
        precondition(session.step == .openWidth && session.allowsToolAdjustment(page: 1))
        session.changedPage(0)
        precondition(session.step == .setWidth && session.allowsToolPage(1))
        session.usedCrown(in: .setWidth, velocity: 0.2)
        precondition(!session.showsCrownHint && session.crownPracticedSteps.count == 3)
        var wider = style
        wider.width += 2
        session.changedStyle(from: style, to: wider, page: 0)
        precondition(session.step == .openOpacity)
        session.changedPage(5)
        precondition(session.step == .setOpacity && session.suggestsCrownRotation)
        var faded = wider
        faded.opacity = 0.5
        session.changedStyle(from: wider, to: faded, page: 5)
        precondition(session.step == .openTool)
        session.changedPage(2)
        precondition(session.suggestsCrownRotation && !session.showsCrownHint)

        session.stop()
        session.start()
        precondition(session.crownPracticedSteps.isEmpty)
        session.record(.stroke)
        session.record(.stroke)
        session.changedZoom()
        precondition(session.step == .history)
        session.stop()
        try await Task.sleep(for: .milliseconds(650))
        precondition(session.step == .inactive)
        precondition(notifications > 0)
    }

    @MainActor static func checkWorkspaceAndOnboarding() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("originals", isDirectory: true)
        let root = base.appendingPathComponent("practice", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = source.appendingPathComponent("sample.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: original)
        let workspace = TutorialWorkspace(root: root, source: source)
        let first = try workspace.prepare()
        try Data([4]).write(to: first.appendingPathComponent("sample.png"))
        let originalBytes = try Data(contentsOf: original)
        precondition(originalBytes == bytes)
        do {
            try workspace.remove(source)
            preconditionFailure("Must reject deletion outside the workspace")
        } catch { precondition(FileManager.default.fileExists(atPath: original.path)) }
        let second = try workspace.prepare()
        precondition(!FileManager.default.fileExists(atPath: first.path))
        precondition(FileManager.default.fileExists(atPath: second.path))
        try workspace.remove(second)
        precondition(ToolSynchronization().width && ToolSynchronization().color && ToolSynchronization().opacity)
        let suite = "TutorialChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = OnboardingController(defaults: defaults, workspace: workspace)
        precondition(!onboarding.hasCompletedWelcome)
        onboarding.requestTutorial()
        precondition(onboarding.preparesTutorial)
        await onboarding.prepareTutorial()
        precondition(!onboarding.preparesTutorial && !onboarding.tutorialError)
        let folder = onboarding.tutorialFolder!
        onboarding.finishTutorial()
        precondition(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil)
        precondition(!FileManager.default.fileExists(atPath: folder.path))
        precondition(OnboardingController(defaults: defaults, workspace: workspace).hasCompletedWelcome)
        onboarding.requestTutorial(chapters: [.tools])
        precondition(onboarding.tutorialChapters == [.tools])
        await onboarding.prepareTutorial()
        precondition(onboarding.tutorialFolder != nil, "A completed tour can be repeated")
        onboarding.completeChapter(.tools)
        onboarding.finishTutorial()
        precondition(OnboardingController(defaults: defaults, workspace: workspace).completedChapters == [.tools])
        onboarding.requestTutorial()
        precondition(onboarding.tutorialChapters == TutorialChapter.allCases)
        onboarding.finishTutorial()
        let unavailable = OnboardingController(defaults: defaults,
            workspace: TutorialWorkspace(root: root, source: nil))
        unavailable.requestTutorial()
        await unavailable.prepareTutorial()
        precondition(unavailable.tutorialError && unavailable.tutorialFolder == nil && !unavailable.preparesTutorial)
    }
}
