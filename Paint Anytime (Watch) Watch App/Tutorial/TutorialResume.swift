import Foundation

/// Where an unfinished chapter picks up again: the lesson and exercise, the page it
/// begins on and the brush in use. The canvas of that moment is stored beside it.
nonisolated struct TutorialResumePoint: Codable, Equatable, Sendable {
    enum Page: String, Codable, Sendable { case canvas, menu }

    let chapter: Int
    let lessonIndex: Int
    let stepIndex: Int
    /// `TutorialStep.rawValue` of the exercise. A release that reorders the lessons no
    /// longer finds it at the same position, and the point is ignored.
    let step: Int
    var page: Page
    var style: PencilStyle
    /// The blending lesson's demonstrated yellow line, kept by its stroke ID.
    var markerLineStrokeID: UUID?
    /// The tour's own autosave switch, turned on in the advanced course.
    var autosaveEnabled: Bool
    var savedAt: Date
}

extension TutorialResumePoint {
    /// Whether the point still names the same exercise in the current lessons.
    /// On the main actor: the lessons depend on the release's features.
    @MainActor var isValid: Bool {
        guard let chapter = TutorialChapter(rawValue: chapter) else { return false }
        let lessons = chapter.lessons
        guard lessons.indices.contains(lessonIndex) else { return false }
        let steps = lessons[lessonIndex].steps
        return steps.indices.contains(stepIndex) && steps[stepIndex].rawValue == step
    }
}

/// A point with the canvas it was taken on. Handed from the background load to the
/// player once; nothing else holds or mutates the document.
nonisolated struct TutorialResumeSnapshot: @unchecked Sendable {
    let point: TutorialResumePoint
    let document: CanvasDocument
}

/// Resume points per chapter: the point in `UserDefaults`, so the menu can mark an
/// unfinished chapter without reading files, and the canvas as JSON in Application Support.
/// `UserDefaults` and `FileManager` are thread-safe; writes run off the main actor.
/// Chapters are passed by raw value, so nothing here needs the main actor; callers
/// check `TutorialResumePoint.isValid` there.
nonisolated struct TutorialResumeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let root: URL?
    private static let keyPrefix = "tutorial.resume.v1."

    init(defaults: UserDefaults = .standard, root: URL? = nil) {
        self.defaults = defaults
        self.root = root ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("TutorialResume", isDirectory: true) }
    }

    func point(for chapter: Int) -> TutorialResumePoint? {
        guard let data = defaults.data(forKey: Self.keyPrefix + String(chapter)),
              let point = try? JSONDecoder().decode(TutorialResumePoint.self, from: data),
              point.chapter == chapter else { return nil }
        return point
    }

    func load(_ chapter: Int) -> TutorialResumeSnapshot? {
        guard let point = point(for: chapter), let url = documentURL(for: chapter),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(CanvasDocument.self, from: data) else { return nil }
        return TutorialResumeSnapshot(point: point, document: document)
    }

    /// The canvas first, then the point: a point never names a canvas that was not written.
    func save(_ point: TutorialResumePoint, document: CanvasDocument) {
        guard let url = documentURL(for: point.chapter), let root else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            defaults.set(try JSONEncoder().encode(point), forKey: Self.keyPrefix + String(point.chapter))
        } catch {
            // Best effort: without a point the chapter simply starts from the beginning.
        }
    }

    func clear(_ chapter: Int) {
        defaults.removeObject(forKey: Self.keyPrefix + String(chapter))
        if let url = documentURL(for: chapter) { try? FileManager.default.removeItem(at: url) }
    }

    private func documentURL(for chapter: Int) -> URL? {
        root?.appendingPathComponent("chapter-\(chapter).json")
    }
}
