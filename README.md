<p align="center">
  <img
    src="images/Paint-Anytime-watchOS-Default-1088@1x.png"
    width="220"
    alt="Paint Anytime app icon"
  >
</p>

<h1 align="center">Paint Anytime</h1>

<p align="center">
  A drawing app made specifically for Apple Watch.
</p>

<p align="center">
  Sketch an idea, doodle while you're waiting, or create a tiny piece of art right from your wrist.
</p>

<p align="center">
  <a href="https://github.com/denis-kolchev/Paint-Anytime/releases/latest">
    <strong>Latest Release</strong>
  </a>
</p>

## Screenshots

<table>
  <tr>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-7F7B719D-E511-4B7B-95E0-23666C91AE0F.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 1"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-F1A50180-A7B1-4820-B40F-1DF043406D16.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 2"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-E29FF2EF-6C44-45CF-AB06-3BDD8D0C92C4.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 3"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-BBA58A1F-EEBA-4819-BE4A-009C6A1472A1.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 4"
      >
    </td>
  </tr>

  <tr>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-36D76474-D3BA-49F0-A2A4-A0A93C0558F2.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 5"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-3076C3F4-61B7-4788-BDD8-2914F3D8640A.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 6"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-185C263D-45DF-4083-A93E-5BB0CED69B8F.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 7"
      >
    </td>
    <td align="center">
      <img
        src="https://github.com/denis-kolchev/Paint-Anytime/blob/main/images/app%20previews/incoming-D327A1E5-91DC-4D89-80A2-A2DD989374AF.PNG?raw=true"
        width="180"
        alt="Paint Anytime screenshot 8"
      >
    </td>
  </tr>
</table>

## Features

### Brushes and Colors

- 6 brushes with distinct drawing behaviors: Monoline, Pen, Fountain Pen, Reed Pen, Marker, and Watercolor.
- Adjustable stroke width, opacity, and brush-specific settings.
- Customizable color palette with support for adding, deleting, and reordering colors.
- RGB color editor for precise color selection.
- Common colors are recognized by name instead of showing only their HEX value.
- 14 color blending modes for different ways to mix and layer paint.

### Canvas and Drawing

- Zoom and move the canvas for precise drawing.
- Start strokes outside the canvas and draw inward, making edges easier to reach.
- Shape recognition with live resizing and rotation.
- Morphing controls free up more canvas space while drawing.
- Regular eraser and object eraser.
- Undo and Redo.
- Clear the entire canvas with one tap.

### Shape Recognition

Draw a shape in one gesture and briefly hold your finger to snap it into a clean geometric form.

Paint Anytime can recognize common shapes including lines, circles, ellipses, rectangles, triangles, polygons, arrows, stars, hearts, clouds, and speech bubbles.

After recognition, keep moving your finger to resize or rotate the shape before releasing it.

### Learning

- Compact interactive tutorial designed specifically for the Apple Watch screen.
- Faster progression without unnecessary **Next** buttons.
- Animated hints for Digital Crown interactions.
- More freedom to explore the canvas while completing lessons.

### Save and Share

- Save drawings to your personal gallery.
- Continue editing saved drawings later.
- Share drawings through iMessage or email.
- Send saved drawings from Apple Watch to Photos on iPhone.

## What's New in 1.1.0

### New Features

- **Watercolor brush** — a new painting tool with natural color buildup.
- **Brush opacity** — adjust the transparency of every brush.
- **14 blending modes** — expanded from the original blending system with 13 additional modes.
- **White default color** — white is now part of the starting palette.
- **Custom color palettes** — add, delete, and rearrange colors.
- **RGB color editor** — enter precise RGB values when creating or editing colors.
- **Named colors** — recognized colors can display their familiar names instead of only HEX values.
- **Shape recognition** — draw and hold to turn freehand strokes into clean geometric shapes.
- **Live shape adjustment** — resize and rotate recognized shapes before releasing your finger.
- **More usable canvas space** — morphing controls can collapse while drawing.
- **Draw from outside the canvas** — strokes can begin beyond the canvas boundary and continue inward.
- **Redesigned tutorial** — more compact, flexible, and faster to complete.
- **Digital Crown guidance** — animated hints show when Crown interaction is expected.

### Bug Fixes & Improvements

- Reduced lag while drawing with Marker and other brushes.
- Improved Marker stroke direction and corner behavior.
- Improved drawing performance as the number of strokes increases.
- Improved zooming and panning performance on complex drawings.
- Fixed visual and layout issues on watchOS 10.
- Improved compatibility across supported watchOS versions.
- Keeps the system clock positioned consistently while drawing.
- Fixed a crash that could occur while saving a drawing to Photos.
- Improved tutorial responsiveness and removed lag from tutorial interactions.
- Improved rendering and persistence reliability for more complex drawings.

## Requirements

- watchOS 10.0 or later
- iOS 17 or later
- Xcode with watchOS development support for building from source

## Build from Source

Clone the repository:

```bash
git clone https://github.com/denis-kolchev/Paint-Anytime.git
```

Open the project in Xcode, select your Apple Developer Team under **Signing & Capabilities**, select an Apple Watch or watchOS Simulator as the destination, and build the project.

Depending on your signing configuration, you may need to use your own Bundle Identifier.

## Releases

Release builds and source archives are available on GitHub:

[View Paint Anytime releases →](https://github.com/denis-kolchev/Paint-Anytime/releases)

Source archives for each release are generated automatically by GitHub.

## Documentation

- [Privacy Policy](docs/PRIVACY.md) — local data, sharing, Photos, and support
- [Localization](docs/LOCALIZATION.md) — language selection and translation workflow
- [Contributing](docs/CONTRIBUTING.md) — pull requests and contributor agreement
- [Licensing](docs/LICENSING.md) — source code and official App Store builds
- [Blend Modes](docs/BLEND_MODES.md) — blending behavior and implementation details
- [Shape Recognition](docs/shape-recognition.md) — supported shapes and recognition behavior

## License

Copyright © 2026 Denis Kolchev.

The source code of Paint Anytime is open source and licensed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`), unless explicitly stated otherwise. See [LICENSE](LICENSE) for the full terms.

Official builds distributed by Denis Kolchev through the Apple App Store are licensed separately under the [Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).

Third-party components retain their applicable licenses.

See [LICENSING.md](docs/LICENSING.md) for additional licensing information.
