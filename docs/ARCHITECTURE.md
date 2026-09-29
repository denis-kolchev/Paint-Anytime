# Architecture

The app uses MVC responsibilities with SwiftUI observation and bindings.

- **Models:** `CanvasDocument`, `Stroke`, `PencilStyle`, and `CanvasExport` describe drawing data.
- **Drawing:** `CanvasController` owns stroke editing and undo/redo. `ToolSettings` owns tool selection and synchronization; `ToolPreferencesStore` reads and writes the existing preference keys. CanvasController forwards tool change notifications so existing SwiftUI bindings continue to update.
- **Drawing session:** `DrawingSessionController` coordinates saving, transfer to iPhone, opening documents, and confirmation before discarding changes. `ContentView` owns presentation, layout, and resets its navigation state when a new canvas session opens.
- **Gallery:** `GalleryController` loads the list, deletes drawings, and restores editable documents. `SavedDrawingsView` owns selection, scrolling, gesture state, and transitions.
- **Export and storage:** `CanvasExporter` renders artwork and encodes PNG metadata. `CanvasExportStore` writes the PNG/JSON pair, lists drawings, loads documents, and deletes files. The PNG/JSON pairing and naming convention remain unchanged; stroke JSON now also stores stable IDs.
- **Views:** `SavedDrawingView` presents a saved image. Shared tutorial scrolling modifiers live in `TutorialScrollActivity.swift`.

## Tutorial

- `TutorialProgress` is the model for exercise completion, tool restrictions, and named `TutorialStep` values. It has no timers or UI dependencies and returns effects for the session to perform.
- `TutorialSession` publishes progress and runs reminder, zoom-idle, and result-delay tasks. It gates events while instruction cards or results are visible, and cancels or resumes delayed transitions.
- `TutorialWorkspace` prepares and removes disposable gallery copies. Its cleanup method only accepts immediate children of the workspace root.
- `OnboardingController` handles preparation state, completion preferences, and tutorial cleanup. `WatchWelcomeView` keeps the regular editor mounted while presenting the tutorial.
- `TutorialPlayerController` owns the isolated canvas, page transitions, save errors, and confirmed clearing. It forwards changes from the canvas and tutorial session to its view. `TutorialPlayerView` retains layout, toolbar frames, focus-related presentation, and camera state; `TutorialLessonView` displays lesson cards.

The tutorial canvas disables preference persistence. Exports go into the temporary gallery and are never queued for transfer to the iPhone.

## Tool settings UI

`WatchToolSettingsView` owns the selected page, a single Digital Crown focus target, tutorial restrictions, and tool-change actions. Presentation components in `ToolSettings/` receive values and action closures: `ToolColorPicker`, `ToolInstrumentPicker`, `ToolDirectionControl`, `ToolEraserModePicker`, `ToolStrokePreview`, and `ToolSettingCarousel`. Width continues to use the shared stroke preview and Crown control. `ToolInformationView`, `ToolSetting`, and `InkPreset` are separate reusable types. The picker panels remain mounted during page transitions, preserving their scrolling and animation behavior.

## iPhone photo inbox

- `IncomingDrawingStore` owns the persistent incoming PNG queue and its file operations.
- `WatchDrawingReceiver` owns WatchConnectivity. It moves incoming files into the store synchronously before the delegate callback returns, then notifies the inbox on the main actor.
- `PhotoLibraryWriter` owns add-only photo permission and writes to the photo library.
- `WatchPhotoInbox` coordinates permission state and sequential queue processing. Failed writes leave their files queued; cleanup failures stop processing and surface the existing error. Services are injected so queue behavior can be tested without a device or actual photo-library writes.
- `PhoneHomeView` displays the state and opens Settings when the writer reports that permission must be changed there.

The iPhone source folder is not currently attached to a build target. Its sources can be type-checked against the iOS simulator SDK independently of the watch build.

## Checks

Run `bash Tests/check-architecture.sh` for preference round trips, observation forwarding, tutorial preference isolation, undo/redo, and document storage. Run `bash Tests/check-watch-bitmap.sh` for bitmap rendering checks. Both require an Apple Swift toolchain; select the installed Xcode with `DEVELOPER_DIR` if necessary.

Run `bash Tests/check-tutorial.sh` for the full lesson sequence, exercise prerequisites, delayed-transition cancellation and resumption, workspace isolation, repeated tours, preparation failures, and onboarding persistence.

Run `bash Tests/check-photo-inbox.sh` for incoming file ownership, serial processing, permission handling, retries, and reception, read, and cleanup failures. It uses a temporary inbox and a fake photo-library writer.

## Marker compositing

Live artwork and PNG export both use `WatchBitmapRenderer`. Marker commands isolate coverage in a transparency layer before applying brush opacity and blending, preventing Core Graphics path batches from darkening overlaps within a single long gesture. Separate strokes still build color. The SwiftUI drawing helper is used only for the short settings preview.


## Watch canvas performance (stages 1–2)

Digital Crown updates only the visual `scaleEffect`. After 200 ms without another zoom value,
`WatchRasterArtwork` requests the settled resolution. Screen raster scale is capped at 4 pixels
per canvas point (native sharpness through 2× zoom on a 2× display); export retains its explicit
resolution. The previous image stays visible while the next frame is prepared.

`WatchArtworkRenderer` serializes mutable cache access on its own actor. Rendering models and
geometry helpers are explicitly `nonisolated`; only image publication occurs on the UI actor.
Cancelled queued work is skipped, full replay checks cancellation between strokes, and obsolete
results are not published. An already-running primitive cannot be interrupted mid-rasterization.

Each stroke has a persisted UUID. Legacy JSON without an ID receives one during decoding and
writes it on the next save. IDs survive appending points, completion, undo/redo, and save/load.
A separate transient geometry revision changes on point edits; it is excluded from document
encoding and equality.

The canvas cache stores resolution-independent geometry and its bounds per committed stroke.
Normal brushes retain drawing commands; marker and watercolor retain the exact coverage paths
and watercolor bands produced by the live generator. Bounds include stroke widths, caps, and
joins and exclude the raster antialiasing fringe. Zoom/resize reuse geometry; new or edited
strokes rebuild their entry. Removed entries are released, so undo after deletion regenerates
them. Changing the document owner clears the geometry cache. Bounds are available for future
viewport/tile culling; no tile rendering is introduced here.

Bitmap checks cover cached/full parity for all brushes, coverage dots and intersections,
geometry reuse across resolutions, bounds containment, edits, clear/undo, document ownership,
the scale cap, actor execution, and cancellation. Architecture checks cover ID migration,
persistence, completion, and undo/redo. Device profiling is still needed to measure frame rate
and peak memory for large drawings.


## Incremental committed ink

When a document revision adds strokes to an unchanged prefix, `WatchBitmapRenderer.Cache`
copies its transparent committed ink and rasterizes only the unseen suffix, in document order.
The prefix is validated using stroke IDs and geometry revisions, without point-array comparisons.
This supports several commits arriving between rendered frames. Marker/watercolor still composite
their coverage against the existing ink, and pixel erasers remove alpha before paper is flattened.

Document-owner, resolution, or size changes, edited/reordered prefixes, and removals use full
replay. A redo that only restores a suffix can use the same append path. Successful rendering
updates the ink, image, key, and prefix together; failed/cancelled work cannot advance the prefix.
The active-stroke layer remains separate and is reset after a committed update to avoid double ink.

Bitmap checks compare incremental batches against full replay, including translucent overlap,
pixel erasing, skipped intermediate requests, prefix edits/reordering, and cancellation recovery.
Counters verify that old strokes are not rasterized again on append. Frame copying/flattening
still scales with bitmap size; active coverage is not yet reused when committing a stroke.
