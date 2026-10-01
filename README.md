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
  <a href="https://github.com/denis-kolchev/Paint-Anytime/releases">
    <strong>Releases</strong>
  </a>
</p>

**Release version: 1.0.1 · Build: 2 · Requires watchOS 10.0 or later**

## Screenshots

<table>
  <tr>
    <td align="center">
      <img
        src="images/app%20previews/incoming-7F7B719D-E511-4B7B-95E0-23666C91AE0F.PNG"
        width="180"
        alt="Paint Anytime screenshot 1"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-F1A50180-A7B1-4820-B40F-1DF043406D16.PNG"
        width="180"
        alt="Paint Anytime screenshot 2"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-E29FF2EF-6C44-45CF-AB06-3BDD8D0C92C4.PNG"
        width="180"
        alt="Paint Anytime screenshot 3"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-BBA58A1F-EEBA-4819-BE4A-009C6A1472A1.PNG"
        width="180"
        alt="Paint Anytime screenshot 4"
      >
    </td>
  </tr>

  <tr>
    <td align="center">
      <img
        src="images/app%20previews/incoming-36D76474-D3BA-49F0-A2A4-A0A93C0558F2.PNG"
        width="180"
        alt="Paint Anytime screenshot 5"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-3076C3F4-61B7-4788-BDD8-2914F3D8640A.PNG"
        width="180"
        alt="Paint Anytime screenshot 6"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-185C263D-45DF-4083-A93E-5BB0CED69B8F.PNG"
        width="180"
        alt="Paint Anytime screenshot 7"
      >
    </td>
    <td align="center">
      <img
        src="images/app%20previews/incoming-D327A1E5-91DC-4D89-80A2-A2DD989374AF.PNG"
        width="180"
        alt="Paint Anytime screenshot 8"
      >
    </td>
  </tr>
</table>

## Features

- Draw with Monoline, Pen, Marker, Fountain pen, and Reed pen.
- Adjust color and stroke width, set the reed nib angle, and choose pixel or object erasing.
- Share width and color settings across tools, or keep them independent.
- Undo and redo, zoom with the Digital Crown, and move around the canvas.
- Save drawings to the watch gallery, reopen them for editing, and share through the options available on your watch.
- Learn the controls with an interactive tutorial that uses a separate practice canvas and gallery.
- Choose an interface language during onboarding or in **More → Language**.
- Read the privacy policy offline in the app. No account is required.

## Version 1.0.1

This release updates the Apple Watch app icon and refreshes the project documentation. See the [changelog](CHANGELOG.md) and [release notes](docs/RELEASE_NOTES.md).

Feature availability is controlled by [`AppReleaseFeatures`](Shared/AppReleaseFeatures.swift). Pencil, Crayon, Watercolor, white ink, and photo-transfer controls are currently reserved for version 2.0 and later. They are not advertised as features of 1.0.1.

## Build and run

1. Open `Paint All the Time.xcodeproj` in Xcode with the watchOS SDK installed. Use an Xcode version that supports this project's format and `.icon` assets.
2. Select the **Paint All the Time (Watch) Watch App** scheme and a compatible Apple Watch simulator or device.
3. For a physical device, select your development team in Signing & Capabilities for the watch app and its container.
4. Build and run. For a release archive, use the same watch scheme and a device destination.

The repository also contains a macOS drawing target (`Paint All the Time`) and iPhone photo-transfer source (`Paint Anytime iPhone`). The current watch container does not compile the iPhone companion sources; the watch scheme is the release entry point.

Existing bitmap renderer checks can be run on macOS with the Swift toolchain:

```sh
bash Tests/check-watch-bitmap.sh
```

## Documentation

- [Changelog](CHANGELOG.md): version history.
- [Release notes](docs/RELEASE_NOTES.md): 1.0.1 update text and release checks.
- [Marketing](docs/MARKETING.md): app description.
- [Support](docs/SUPPORT.md): help and troubleshooting.
- [Privacy Policy](docs/PRIVACY.md): local data, sharing, Photos, and support.
- [Localization](docs/LOCALIZATION.md): language selection and translation workflow.
- [Contributing](docs/CONTRIBUTING.md): pull requests and contributor agreement.
- [Licensing](docs/LICENSING.md): source code and official App Store builds.
- [First-stroke rendering investigation](FIRST_STROKE_DELAY_FIX.md): technical background (Russian).

## License

Copyright (c) 2026 Denis Kolchev.

The source code of Paint Anytime is open source and licensed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`), unless explicitly stated otherwise. See [LICENSE](LICENSE) for the full terms.

Official builds distributed by Denis Kolchev through the Apple App Store are licensed separately under the [Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/). Third-party components retain their applicable licenses.

See [LICENSING.md](docs/LICENSING.md) for details and [CONTRIBUTING.md](docs/CONTRIBUTING.md) for contribution requirements.
