# Paint Anytime

<img src="images/Paint-Anytime-watchOS-Default-1088@1x.png" alt="Paint Anytime app icon" width="160">

A drawing app for Apple Watch, built with SwiftUI. Sketch on your wrist, explore different drawing tools, and keep your artwork in a local gallery.

**Release version: 1.0.1 · Build: 2 · Requires watchOS 10.0 or later**

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
