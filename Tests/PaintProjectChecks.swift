import Foundation

@main
struct PaintProjectChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var style = PencilStyle.initial(for: .watercolor)
        style.opacity = 0.37
        style.blendingMode = .multiply
        var stroke = Stroke(points: [PointerSample(position: SIMD2(12, 23), pressure: 0.8, timestamp: 1)], style: style)
        stroke.fillRects = [SIMD4(1, 2, 3, 4)]
        stroke.transform = StrokeTransform(CGAffineTransform(translationX: 42, y: 17))
        stroke.excludedAreas = [[SIMD2(1, 2), SIMD2(3, 4), SIMD2(5, 6)]]
        stroke.erasures = [Stroke(points: [], style: .initial(for: .eraser))]
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        stroke.raster = StrokeRaster(png: png, bounds: CGRect(x: 1, y: 2, width: 3, height: 4))
        var document = CanvasDocument(strokes: [stroke])
        document.layers.append(CanvasLayer(name: "Hidden", isVisible: false, opacity: 0.4, locksTransparency: true))
        document.canvasSize = CGSize(width: 300, height: 250)
        document.resolution = 144
        document.backgroundIsVisible = false
        let project = PaintProject(document: try JSONEncoder().encode(document), preview: png)
        let url = folder.appendingPathComponent("Drawing.paintanytime")
        try project.write(to: url)
        let read = try PaintProject.read(url)
        let restored = try JSONDecoder().decode(CanvasDocument.self, from: read.document)
        precondition(restored == document, "All editable drawing properties must survive export/import")
        let inbox = IncomingDrawingStore(folder: folder.appendingPathComponent("Inbox"))
        try inbox.receive(url, name: "Copy.paintanytime")
        let images = try inbox.pendingImages()
        precondition(images.count == 1)
        let imported = try PaintProject.read(images[0].deletingPathExtension().appendingPathExtension("paintanytime"))
        precondition(imported.document == project.document && imported.preview == png)
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        future["version"] = 99
        do {
            _ = try PaintProject.decode(JSONSerialization.data(withJSONObject: future))
            preconditionFailure("Future versions must not silently lose data")
        } catch PaintProject.ProjectError.unsupported {}
        do {
            _ = try PaintProject.decode(Data("{}".utf8))
            preconditionFailure("Invalid files must be rejected")
        } catch {}
        let legacyURL = URL(fileURLWithPath: "Paint Anytime (Watch) Watch App/SimulatorGallerySample.paintanytime")
        let legacy = try PaintProject.read(legacyURL)
        let migrated = try JSONDecoder().decode(CanvasDocument.self, from: legacy.document)
        precondition(migrated.canvasSize == CGSize(width: 205, height: 251), "Legacy canvas size must come from PNG metadata")
        let migratedURL = folder.appendingPathComponent("Migrated.paintanytime")
        try legacy.write(to: migratedURL)
        let reopened = try PaintProject.read(migratedURL)
        let reopenedDocument = try JSONDecoder().decode(CanvasDocument.self, from: reopened.document)
        precondition(reopenedDocument == migrated, "Recovered size must persist")
        var resized = migrated
        resized.canvasSize = CGSize(width: 100, height: 120)
        let explicitSize = PaintProject(document: try JSONEncoder().encode(resized), preview: legacy.preview)
        let explicitDocument = try JSONDecoder().decode(CanvasDocument.self, from: explicitSize.document)
        precondition(explicitDocument == resized, "Existing canvas size must take precedence over preview metadata")
        let rawLegacy = try JSONDecoder().decode(PaintProject.self, from: Data(contentsOf: legacyURL))
        precondition(PaintProject.restoringCanvasSize(in: rawLegacy.document, preview: png) == rawLegacy.document,
                     "Missing metadata must not invent a canvas size")
        print("PASS: canvas size recovery, persistence, explicit size precedence, missing metadata;")
        print("PASS: editable project round trip, phone import, preview, invalid and future version rejection")
    }
}
