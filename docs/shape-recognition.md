# Hold-to-recognize shapes

On the watch canvas, draw a shape in one gesture and hold the finger still for 500 ms. Movement within two screen points is treated as hold jitter, independently of zoom. A successful snap produces a haptic click. Low-confidence or ambiguous strokes remain freehand.

Supported candidates: line, circle, ellipse (including rotated), rectangle, square, triangle, and a simple single-stroke arrow. Draw the arrow as shaft → tip → first wing → tip → second wing. Multi-stroke arrows and arbitrary polygons are outside this initial implementation.

After snapping, moving the finger rotates and uniformly scales the result. Lines and arrows use the shaft start as the anchor; closed shapes use their center. Release commits one ordinary stroke, preserving its ID and tool style. Existing document serialization and Undo/Redo apply without a new file format.

Erasers and canvas panning never invoke recognition. Hold tasks are cancelled on release, gesture cancellation, input disablement, panning, leaving the view, and inactive scene state. Gesture IDs guard against a stale task snapping a later stroke.

Implementation: `Shared/ShapeRecognizer.swift` compares normalized geometric fitting errors. Recognition uses distance-resampled points and conservative closure/convexity/winding guards. `PencilTool` owns the snapped/adjusting state. The watch view owns the hold timer.

Prepared checks:

- `bash Tests/check-shape-recognition.sh`: candidates, rejected paths, style/ID retention, adjustment, jitter and cancellation.
- `bash Tests/check-architecture.sh`: includes one-step undo/redo and save roundtrip for a snapped stroke.

Neither compilation nor these executable checks was run, as requested. Shell syntax and whitespace checks were performed. Device recognition thresholds and gesture timing require validation in Xcode/on watch.
