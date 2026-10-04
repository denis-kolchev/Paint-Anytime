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
  <a href="https://github.com/denis-kolchev/Paint-Anytime/releases/tag/v1.0.0">
    <strong>Latest Release — v1.0.0</strong>
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

### Brushes and color

- 6 brushes with distinct drawing behaviors: Monoline, Pen, Fountain Pen, Reed Pen, Marker, and Watercolor.
- 12 starting colors, including white. Mix and layer them on the canvas to create many more colors and shades.
- 14 color blending modes to control how new strokes interact with existing paint.
- Adjustable stroke width and opacity for every brush, plus a tip angle setting for Reed Pen.

### Canvas and editing

- Zoom and move the canvas for more precise drawing.
- Start strokes outside the canvas and paint inward for easier work along the edges.
- Pixel and object erasers, Undo and Redo, and one-tap canvas clearing.

### Learning

- A compact, interactive tutorial with hints at the bottom of the screen.
- Animated guidance for using the Digital Crown.

### Save and share

- Save drawings to your personal gallery and continue editing them later.
- Share your drawings through iMessage or email.

## What's New in 1.1

### Brushes, colors, and blending

- **New Watercolor brush**, bringing the total to 6 brushes.
- **Opacity controls for every brush**, making it easier to build up color gradually.
- **White joins the palette**, bringing it to 12 starting colors that can be mixed into many more shades.
- **14 color blending modes** for different ways to layer paint.
- **Improved default color blending**, combining the strengths of Multiply and Normal for richer color buildup.
- **Improved Marker strokes**, with more natural line direction and better corners.

### Smoother drawing and canvas navigation

- Optimized canvas rendering to keep new strokes, zooming, and panning responsive as drawings accumulate more strokes.
- Strokes can now begin outside the canvas, making it easier to reach details along its edges.
- The system clock stays centered at the top of the screen while drawing, reducing distracting movement.

### Faster, simpler learning

- A redesigned tutorial lives in a small panel at the bottom of the screen and progresses without a **Next** button.
- Completing the tutorial takes about two-thirds of the previous time, with more freedom to explore instead of following rigid instructions.
- A new animation shows when to turn the Digital Crown.

### Compatibility and reliability

- Optimized for watchOS 10.
- Fixed a crash when saving a photo.

## Requirements

- Apple Watch
- watchOS 10.0 or later
- Xcode with watchOS development support for building from source

## Build from Source

Clone the repository:

```bash
git clone https://github.com/denis-kolchev/Paint-Anytime.git
```

Open the project in Xcode, select your Apple Developer Team under **Signing & Capabilities**, select an Apple Watch or watchOS Simulator as the destination, and build the project.

Depending on your signing configuration, you may need to use your own Bundle Identifier.

## Releases

The first public release is **Paint Anytime 1.0.0**.

[View Paint Anytime v1.0.0 →](https://github.com/denis-kolchev/Paint-Anytime/releases/tag/v1.0.0)

Source archives for each release are generated automatically by GitHub.

## Documentation

- [Privacy Policy](docs/PRIVACY.md) — local data, sharing, Photos, and support
- [Localization](docs/LOCALIZATION.md) — language selection and translation workflow
- [Contributing](docs/CONTRIBUTING.md) — pull requests and contributor agreement
- [Licensing](docs/LICENSING.md) — source code and official App Store builds

## License

Copyright © 2026 Denis Kolchev.

The source code of Paint Anytime is open source and licensed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`), unless explicitly stated otherwise. See [LICENSE](LICENSE) for the full terms.

Official builds distributed by Denis Kolchev through the Apple App Store are licensed separately under the [Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).

Third-party components retain their applicable licenses.

See [LICENSING.md](docs/LICENSING.md) for additional licensing information.
