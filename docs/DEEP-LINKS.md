# Paint Anytime deep links

The iPhone companion and watch app register `paintanytime`. The standalone Metal
app and WidgetKit extension are not URL handlers.

| URL | Apple Watch | iPhone companion |
| --- | --- | --- |
| `paintanytime://canvas` | Return to the current canvas | Show instructions for opening the watch canvas |
| `paintanytime://gallery` | Open gallery | Return to gallery, closing drawing detail |
| `paintanytime://new` | Request a blank document, with the existing unsaved-work confirmation | Show instructions for starting a drawing on the watch |
| `paintanytime://settings` | Open the existing settings/menu | Show instructions for opening watch settings |

URLs opened on iPhone do not launch or navigate the paired watch. No remote
command is queued. Delivery on watch depends on the calling surface's support for
opening custom URLs; registration does not make every watch app a URL launcher.

Legacy `paintanytime://app` (preserve current screen), `paintanytime://new-canvas`,
and `paintanytime://gallery?artwork=filename.png` remain supported on watch.
Unknown destinations and malformed paths are ignored. File URLs on iPhone still
use the existing project importer. Query parameters do not change the destination.

Watch requests wait until welcome/tutorial finishes. Each delivery has a new
identity, so repeated links work. New requests cancel an older pending transition.
The existing editor instance and history are retained when navigating; creating a
new document uses the existing document replacement and confirmation flow.

## Verification

Run `bash Tests/check-deep-links.sh` for URL parsing and legacy compatibility.
Build the `Paint Anytime iPhone` scheme (includes the embedded watch app).

On paired devices or simulators, exercise every URL with the app terminated and
already running. On watch, also try links from gallery, settings, layers, palette,
a discard confirmation, welcome, and tutorial. Check that canceling New retains
artwork and Undo/Redo, confirming creates a blank canvas, and a second link wins
during an ongoing transition. On iPhone check drawing detail, wide split layout,
file import, and repeated links. Verify project files still import normally.
