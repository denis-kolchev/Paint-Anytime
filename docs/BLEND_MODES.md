# Brush blend modes

Marker and watercolor strokes store their blend mode in `PencilStyle`. Changing the
setting affects subsequent strokes; existing strokes retain their saved mode.
Old documents and unknown mode identifiers fall back to Hybrid.

The shared `ColorBlendingMode.blend` function implements Normal, Multiply, Screen,
Overlay, Soft Light, Hard Light, Darken, Lighten, Color Dodge, Color Burn, Add,
Difference, and Exclusion. Hybrid retains the existing mix of Normal and Multiply
(80% Multiply for marker, 85% for watercolor). Add means clamped RGB addition,
also called Linear Dodge; it does not add alpha. Soft Light uses the W3C variant.

References:
- https://en.wikipedia.org/wiki/Blend_modes
- https://www.w3.org/TR/compositing-1/#blending

Blend functions operate on straight RGB; source-over compositing then accounts
for both source and backdrop alpha and returns premultiplied RGBA. Empty pixels
retain the source color rather than blending it with black. Normal, Multiply,
and Hybrid retain the accelerated rendering path. Other modes reuse the same
coverage masks, so a self-crossing gesture does not accumulate extra paint.

## Help illustrations

The information button opens help for the currently selected mode. Charts are
rendered at display resolution from the shared compositing function. Each cell
receives 0–10 yellow passes along the horizontal axis, then 0–10 blue passes
along the vertical axis, at 80% watercolor opacity. The zero row/column isolates
each color. Marker uses its own lower coverage opacity, as explained in the caption.

The 11 additional modes begin with transparent ink, exactly like an empty drawing.
The accumulated premultiplied ink is composited over the white display backing
only after all passes. An opaque white fill would incorrectly suppress Screen
and other modes before any paint existed. There is no gray-background toggle.
The original Hybrid, Multiply, and Normal examples are preserved unchanged.

Regression checks compare 25 reference cells per additional mode with actual
watercolor strokes rendered on empty canvas, and preserve all 121 cells of each
of the original three charts.

A contact sheet is available in `images/blending-modes.png`.

## Validation

`Tests/check-watch-bitmap.sh` checks independent numeric fixtures for every mode,
transparent and partially transparent backdrops, endpoint finiteness, saved mode
round trips, and rendered marker/watercolor pixels. Existing rendering regressions
also cover erasing, replay, caching, and stroke coverage.

## Naming and localization

The picker leads with a short description of the effect (for example, “Soft
brightening”), followed by the localized editor term and its English reference
name (“Экран · Screen”). Help repeats both so users can match tutorials. English
reference names are isolated bidirectionally inside Arabic and Hebrew text.
The 14 effect labels and 14 reference titles have entries in all 28 supported
languages. These short effect labels are app wording, not claims of an industry
standard. Full help paragraphs are currently available in English and Russian.

Terminology was checked against Adobe's localized documentation, including:
- [Russian](https://helpx.adobe.com/ru/photoshop/desktop/repair-retouch/adjust-light-tone/blending-mode-descriptions.html)
- [French](https://helpx.adobe.com/fr/photoshop/desktop/repair-retouch/adjust-light-tone/blending-mode-descriptions.html)
- [German](https://www.adobe.com/de/learn/photoshop/web/composite-image-with-blend-modes)
- [Japanese](https://helpx.adobe.com/jp/photoshop/desktop/repair-retouch/adjust-light-tone/blending-mode-descriptions.html)
- [Dutch](https://helpx.adobe.com/be_nl/photoshop-elements/using/keys-using-blending-modes.html)
- [Norwegian](https://helpx.adobe.com/no/photoshop/desktop/repair-retouch/adjust-light-tone/blending-mode-descriptions.html)
- [Finnish](https://www.adobe.com/fi/products/photoshop/blend-colors.html)

Names vary between editors and even documentation editions. In particular,
Russian Darken/Lighten are “Замена тёмным/Замена светлым”; “Темнее/Светлее”
would suggest the different whole-color Darker Color/Lighter Color operations.
New translations have not had native-speaker review in every language.
