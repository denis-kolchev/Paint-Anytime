# Paint Anytime project files

Extension: `.paintanytime`  
Uniform type identifier: `com.deniskolchev.paintanytime.project`  
MIME type: `application/vnd.paintanytime.project`

A single UTF-8 JSON file contains a versioned envelope:

- `format`: `Paint Anytime Project`
- `version`: `1`
- `document`: base64-encoded UTF-8 JSON produced by `CanvasDocument`
- `preview`: base64-encoded PNG

The document preserves bottom-to-top layer order, names, visibility, opacity,
transparency locks, stroke samples and styles, fills, transformations, raster
fragments, cutouts, erasures, canvas size, resolution, and background settings.
Undo history and temporary selections are not included.

The phone preserves document bytes without re-encoding the drawing model.
The watch decodes the document into its editor. Importing on the watch assigns
an independent document ID and creates a new gallery entry; it never replaces
an existing drawing. Imports are limited to 64 MiB of encoded file data.
Unknown envelope versions are rejected rather than partially imported.

## User flow

1. Save a drawing on the watch and synchronize the phone gallery.
2. Open the drawing on iPhone and use **Project → Share Project** or
   **Save Project to Files**.
3. Open a received `.paintanytime` file with Paint Anytime, or use
   **Import Project** in the phone gallery.
4. Open the imported drawing and choose **Project → Send to Apple Watch**.
5. After delivery, open the new watch gallery entry for editing.

Transfers are queued with WatchConnectivity and may not arrive immediately.
The watch app must be installed and paired with the phone. Project import
errors reported by the watch are surfaced on the phone.

Other apps can store and forward these files. Editing in another editor
requires that editor to implement this format; it is not a PSD interchange
format. Existing PNG exports remain available independently.
