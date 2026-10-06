# Hold-to-recognize shapes

On the watch canvas, draw a shape in one gesture and hold the finger still for 500 ms. Movement within two screen points is treated as hold jitter, independently of zoom. A successful snap produces a haptic click. Low-confidence or ambiguous strokes remain freehand.

Supported candidates:

- Straight line and circular arc.
- Circle and ellipse, including rotated ellipses.
- Square, rectangle, triangle and convex quadrilateral.
- Regular pentagon, hexagon and regular polygons with seven through twelve sides. At watch scale, higher side counts are difficult to distinguish from circles and are not classified separately.
- Closed outline arrow, straight line with an arrowhead and circular arc with an arrowhead. For open arrows, draw shaft → tip → first wing → tip → second wing in one continuous gesture. Multi-stroke arrows are not supported.
- Scalloped cloud, five-point outline star, heart and speech bubble with a tail (rectangular or oval body).

Closed outline templates accept either drawing direction, different starting points, translation, rotation and uniform scale. They cover standard outlines rather than every possible decorative variation. Polygon matching also requires distinct corners to avoid turning circles into many-sided polygons.

After snapping, moving the finger rotates and uniformly scales the result. Lines, arcs and open arrows use the stroke start as the anchor; closed shapes use their center. Release commits one ordinary stroke, preserving its ID and tool style. Existing document serialization and Undo/Redo apply without a new file format.

Erasers and canvas panning never invoke recognition. Hold tasks are cancelled on release, gesture cancellation, input disablement, panning, leaving the view, and inactive scene state. Gesture IDs guard against a stale task snapping a later stroke.

Implementation: `Shared/ShapeRecognizer.swift` compares normalized geometric fitting errors. Recognition uses distance-resampled points, closure/convexity/winding guards and ordered outline matching. `PencilTool` owns the snapped/adjusting state. The watch view owns the hold timer.

Prepared checks:

- `bash Tests/check-shape-recognition.sh`: original and additional candidates, transformed outlines, rejected paths, style/ID retention, adjustment, jitter and cancellation.
- `bash Tests/check-architecture.sh`: includes one-step undo/redo and save roundtrip for a snapped stroke.

The final changes have not been built or checked, as requested. Earlier development checks exposed polygon ambiguity; the final corner-filter correction has not been executed. Recognition thresholds and gesture timing still require device validation.
