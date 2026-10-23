# Authored pencil and crayon nibs

## Material contract

The active PNGs are the original first two generated masks selected by the user. They supply the material field; no authored image is repeatedly stamped along the path. A continuous swept path reveals the field at each pixel, using a single sample position selected from the local path frame. The image is not used as a repeated footprint or a silhouette stamp.

Each saved gesture ID selects a different source origin. A straight run keeps the same canvas-anchored mapping, independently of input event frequency. When the heading changes beyond a 5-degree dead band, a distance-based filter gradually rotates the sampling frame and shifts the source origin. Tiny positional movement (0.4–1.8 canvas points, depending on width) is ignored. Mirroring the image interior avoids transparent image margins and hard wrap seams.

Graphite and wax use their own original authored source image. No procedural paper noise or generated grain is added. Four subpixel samples antialias the continuous reveal. Already-painted sections retain their saved local frame; subsequent turns do not rotate the entire past stroke.

## Assets and provenance

The active `PencilNib.png` and `CrayonNib.png` are the **first two generated images**, selected by the user. Later refinements are not used. Both were made with the built-in imagegen tool and copied into the app's resource folder.

### Pencil generation prompt

Create a production brush-tip alpha-mask asset, square 1024x1024 transparent PNG. A SINGLE BLACK GRAPHITE CONTACT PATCH centered, about 80% of canvas, shaped like an irregular squat oval blob with clustered lobes. Flat scanned real soft graphite, no lighting, no shadow, no paper background, no text. Dense overlapping graphite deposits, very fine intricate granular structure, small translucent pinholes between clustered deposits; mid-opacity and dark patches. The patch boundary and interior must be made of the SAME graphite clumps, not a clean ellipse with a speckle rim. Ragged blotted ends in every direction, no rectangle, no directional scratches, no spray halo. This is a short nib imprint, NOT a line, NOT a stroke or multiple swatches. Pure black pigment with actual transparency carrying all tonal variation. Reference images provided in conversation show black graphite texture and grey pencil strokes; use those as visual style only. High definition fine grains, densely connected center, irregular lobed edge.

### Crayon generation prompt

Create a production brush-tip alpha-mask asset, square 1024x1024 transparent PNG. ONE BLACK WAX CRAYON CONTACT PATCH centered, width 80% canvas, height 55%, squat irregular broad chisel patch. Not graphite: cohesive oily wax, dense dark body with a few irregular transparent scuffs, tiny paper-tooth gaps and soft short smears. Upper and lower ends have a torn-paper uneven ripped silhouette; side edges are imperfect and slightly rounded. NO long repeated parallel white streaks, NO comb pattern. At most ONE subtle short narrow vertical groove, off-center, fading before reaching ends. Black pigment only, encode variation in alpha on genuinely transparent background. No paper, shadows, objects, text, gradients into big fuzzy halo. A single short nib imprint not an extended stroke. Refer to user's grey crayon texture but REMOVE its many long lines; preserve waxy scuffed material. High resolution intricate fine detail inside cohesive irregular patch.

## Validation status

No application build or compiled renderer checks were run, at the user's request. The existing bitmap test harness has been updated for the authored-mask implementation. Device appearance, replay parity and watch performance still need verification in Xcode.
