# Architecture

The app uses MVC responsibilities with SwiftUI observation and bindings.

- **Models:** `CanvasDocument`, `Stroke`, `PencilStyle`, and `CanvasExport` describe drawing data.
- **Drawing:** `CanvasController` owns stroke editing and undo/redo. `ToolSettings` owns tool selection and synchronization; `ToolPreferencesStore` reads and writes the existing preference keys. CanvasController forwards tool change notifications so existing SwiftUI bindings continue to update.
- **Drawing session:** `DrawingSessionController` coordinates saving, transfer to iPhone, opening documents, and confirmation before discarding changes. `ContentView` owns presentation, layout, and resets its navigation state when a new canvas session opens.
- **Gallery:** `GalleryController` loads the list, deletes drawings, and restores editable documents. `SavedDrawingsView` owns selection, scrolling, gesture state, and transitions.
- **Export and storage:** `CanvasExporter` renders artwork and encodes PNG metadata. `CanvasExportStore` writes the PNG/JSON pair, lists drawings, loads documents, and deletes files. The on-disk format and naming convention remain unchanged.
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
