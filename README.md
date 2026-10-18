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
  <a href="https://apps.apple.com/app/paint-anytime/id6816100087?platform=watch">
    <img
      src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83"
      alt="Download on the App Store"
      width="170"
    >
  </a>
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
        src="images/app%20previews/release%201.1/incoming-1AEBBC6E-A272-4BA0-B910-78FCBD1E6DAD.PNG"
        width="180"
        alt="Paint Anytime screenshot 1"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-3130074F-56B5-43F4-B57A-162A5D5F04E0.PNG"
        width="180"
        alt="Paint Anytime screenshot 2"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-4E3E4793-5295-448D-84D5-496EA4E122A2.PNG"
        width="180"
        alt="Paint Anytime screenshot 3"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-6FBC533E-7009-475F-8647-BEFFEFAD1808.PNG"
        width="180"
        alt="Paint Anytime screenshot 4"
      >
    </td>
  </tr>

  <tr>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-8C254FDB-0C45-47C7-A118-73F23427EA86.PNG"
        width="180"
        alt="Paint Anytime screenshot 5"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-6CDF876B-5B5B-406D-AE09-4C4DF3FBD48A.PNG"
        width="180"
        alt="Paint Anytime screenshot 6"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-4D2D5F4B-0080-4027-90C2-0D0496BF7369.PNG"
        width="180"
        alt="Paint Anytime screenshot 7"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/release%201.1/incoming-EE80BF22-304A-4C77-A428-2D7BC9E92237.PNG"
        width="180"
        alt="Paint Anytime screenshot 8"
      >
    </td>
  </tr>
</table>

## Description

Paint Anytime is a drawing app made specifically for Apple Watch. Sketch a quick idea or create a tiny piece of art right from your wrist.

Choose from a variety of brushes, сustomize colors, stroke width, angle, and opacity. Organize your artwork with layers, lock transparency to paint within existing boundaries, and use the Lasso to select, move, and rearrange parts of your drawing. Draw and hold to create cleaner shapes, or use the Fill tool to color larger areas in seconds.

Create custom colors with HSB and RGB sliders, organize them into palettes, and switch between color collections to match your mood. Explore different blending modes and see how colors interact on the canvas.

Save your drawings to your personal gallery and continue editing whenever inspiration returns. Use widgets to display your favorite creations or jump straight back into drawing.

## Features

- Custom colors, stroke width, angle, and opacity;
- Layers with transparency lock;
- Lasso tool for arranging your artwork;
- Shape recognition with draw-and-hold;
- Fill tool for coloring enclosed areas;
- Multiple color blending modes;
- Custom color palettes with RGB and HSB editors;
- Canvas zoom and expandable drawing space;
- Undo, Redo, and two types of erasers;
- Personal gallery with editable saved drawings;
- Apple Watch widgets for artwork and quick access;
- Compact, interactive drawing tutorial;
- Share your creations through iMessage or email.

## What's New in 1.1.0

### New Features

- New UI hides controls to give you more space to draw and view your artwork;
- Layers. Lock transparency to keep your colors within painted boundaries;
- Use the Lasso tool to adjust your composition;
- Draw and hold to turn rough shapes into perfect geometry;
- HSB and RGB sliders give you more ways to create colors for your palette;
- Palette collections make it easy to switch your painting mood;
- Color blending. Yellow plus blue doesn't always equal green anymore;
- Watercolor brush is a great addition to Marker for exploring color blending;
- New Fill tool helps you spend less time covering large areas;
- Widgets to display your favorite artwork, jump back into drawing, and track your streaks;
- Updated tutorial is quicker to complete and comes in a more compact form;
- All brushes and layers now have opacity settings to adjust transparency.

### Bug Fixes

- Reduced lag while drawing with Marker and other brushes.
- Improved Marker stroke direction and corner behavior.
- Improved drawing performance as the number of strokes increases.
- Improved zooming and panning performance on complex drawings.
- Fixed visual and layout issues on watchOS 10.
- Improved compatibility across supported watchOS versions.
- Kept the system clock consistently positioned while drawing.

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
