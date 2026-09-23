import SwiftUI
import Combine

/// The inactive instance keeps the normal editor free of tutorial restrictions.
@MainActor
final class TutorialSession: ObservableObject {
    static let inactive = TutorialSession()
    @Published private(set) var step = 0
    @Published var showsInstruction = false
    @Published private(set) var remindersPaused = false
    private var lastActivity = Date()
    private var reminderTask: Task<Void, Never>?
    private var zoomIdleTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var pendingAdvanceStep: Int?
    @Published private(set) var showsResult = false
    private var count = 0
    @Published private var hasPanned = false
    private var hasClosedTools = false
    private var hasOpenedInfo = false

    var isActive: Bool { step > 0 }
    var acceptsActions: Bool { !isActive || (!showsInstruction && !showsResult) }
    var allowsDrawing: Bool { permits([1, 9]) }
    var allowsCanvasZoom: Bool { permits([10]) }
    var allowsCanvasPan: Bool { permits([11]) }
    var allowsGalleryZoom: Bool { permits([16]) }
    var allowsGalleryPaging: Bool { permits([17]) }
    var allowsGalleryDelete: Bool { permits([17]) }
    var allowsGalleryBack: Bool { permits([18]) }
    var allowsToolInfo: Bool { permits([7]) }

    // Raw values of the existing settings pages: width, color, instrument, mode, angle.
    var visibleToolPages: Set<Int> {
        switch step {
        case 3: [1]
        case 4: [1, 0]
        case 5: [0]
        case 6: [0, 2]
        case 7: [2]
        case 8: [2, 4]
        case 9: [4]
        default: [0, 1, 2, 3, 4]
        }
    }

    func permits(_ steps: Set<Int>) -> Bool {
        !isActive || (acceptsActions && steps.contains(step))
    }

    func allowsToolAdjustment(page: Int) -> Bool {
        !isActive || (acceptsActions && [(3, 1), (5, 0), (6, 2), (8, 4)].contains { $0.0 == step && $0.1 == page })
    }

    func allowsToolPage(_ page: Int) -> Bool {
        !isActive || (acceptsActions && [(4, 0), (6, 2), (8, 4)].contains { $0.0 == step && $0.1 == page })
    }

    func start() {
        cancelPendingAdvance()
        count = 0
        hasPanned = false
        hasClosedTools = false
        hasOpenedInfo = false
        remindersPaused = false
        zoomIdleTask?.cancel()
        step = 1
        showsInstruction = true
        lastActivity = Date()
        reminderTask?.cancel()
        reminderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isActive else { return }
                if !self.showsInstruction && !self.remindersPaused && self.pendingAdvanceStep == nil && Date().timeIntervalSince(self.lastActivity) >= 5 {
                    self.showsInstruction = true
                }
            }
        }
    }

    /// Next dismisses a lesson card. It never skips an unfinished exercise.
    func beginExercise() {
        showsInstruction = false
        activity()
    }

    func activity() { if isActive { lastActivity = Date() } }

    func pauseReminders() {
        guard isActive else { return }
        remindersPaused = true
        zoomIdleTask?.cancel()
        advanceTask?.cancel()
    }

    func resumeReminders() {
        guard isActive else { return }
        remindersPaused = false
        activity()
        if pendingAdvanceStep == step {
            advanceAfterResult(lockInput: showsResult)
        }
    }

    enum Event {
        case stroke, openedTools, closedTools, openedInfo, closedInfo
        case panned, finishedCamera, history, saved, closedSave, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
    }

    func record(_ event: Event) {
        guard isActive, acceptsActions else { return }
        activity()
        switch (step, event) {
        case (1, .stroke):
            count += 1
            if count >= 2 { advance() }
        case (2, .openedTools): advanceAfterResult(lockInput: true)
        case (7, .openedInfo):
            hasOpenedInfo = true
            pauseReminders()
        case (7, .closedInfo):
            resumeReminders()
            if hasOpenedInfo { advance() }
        case (9, .closedTools): hasClosedTools = true
        case (9, .stroke):
            if hasClosedTools { count += 1 }
            if count >= 2 { advance() }
        case (11, .panned): hasPanned = true
        case (11, .finishedCamera):
            if hasPanned { advance() }
        case (12, .history):
            count += 1
            if count >= 2 { advance() }
        case (15, .openedGallery), (18, .returnedToCanvas), (19, .cleared):
            advanceAfterResult(lockInput: true)
        case (13, .saved), (14, .closedSave), (16, .galleryFullscreen), (17, .deleted): advance()
        default: break
        }
    }

    var canFinishCamera: Bool { !isActive || hasPanned }

    func changedPage(_ page: Int) {
        guard isActive, acceptsActions else { return }
        activity()
        if step == 4 && page == 0 { advanceAfterResult(lockInput: true) }
    }

    func changedStyle(_ style: PencilStyle) {
        guard isActive, acceptsActions else { return }
        activity()
        let matches: Bool
        switch step {
        case 3: matches = style.color == SIMD4<Float>(0.2, 0.7, 0.35, 1)
        case 5: matches = style.width == 10
        case 6: matches = style.instrument == .reed
        case 8: matches = style.reedAngle == 20
        default: return
        }
        // A brief pass over the target does not finish the lesson. The user
        // can keep adjusting; a different value cancels the pending transition.
        if matches { advanceAfterResult(lockInput: false) }
        else { cancelPendingAdvance() }
    }

    func changedZoom() {
        guard isActive, allowsCanvasZoom else { return }
        activity()
        zoomIdleTask?.cancel()
        zoomIdleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.step == 10, !self.showsInstruction, !self.remindersPaused else { return }
            self.advance()
        }
    }

    /// Leave the result visible long enough for animations and visual feedback.
    private func advanceAfterResult(lockInput: Bool) {
        advanceTask?.cancel()
        pendingAdvanceStep = step
        showsResult = lockInput
        activity()
        guard !remindersPaused else { return }
        let completedStep = step
        advanceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self, !Task.isCancelled, self.step == completedStep,
                  self.pendingAdvanceStep == completedStep,
                  !self.showsInstruction, !self.remindersPaused else { return }
            self.advance()
        }
    }

    private func cancelPendingAdvance() {
        advanceTask?.cancel()
        advanceTask = nil
        pendingAdvanceStep = nil
        showsResult = false
    }

    private func advance() {
        guard step < 20 else { return }
        cancelPendingAdvance()
        zoomIdleTask?.cancel()
        count = 0
        step += 1
        showsInstruction = true
        activity()
    }

    func stop() {
        cancelPendingAdvance()
        reminderTask?.cancel()
        zoomIdleTask?.cancel()
        reminderTask = nil
        zoomIdleTask = nil
        step = 0
        showsInstruction = false
    }
}

/// Only this directory is writable during the lesson. Bundle originals and user drawings are never deleted.
enum TutorialGallery {
    static func prepare() throws -> URL {
        guard let source = Bundle.main.url(forResource: "Preset Photos", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaintAnytimeTutorial", isDirectory: true)
        // Remove only previous disposable tutorial sessions, including those left by an interrupted launch.
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in files {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
