# Paint Anytime 1.0.1

Status: prepared for release; publication is not recorded here.

Version: **1.0.1** · Build: **2** · Minimum watchOS: **10.0**

## What's New — English

Paint Anytime has a refreshed Apple Watch app icon. Keep sketching with your favorite drawing tools, explore the interactive tutorial, and revisit your saved drawings in the gallery.

## Release scope

The changes since the repository's `v1.0.0` baseline are the watch app icon, release metadata, and documentation. Existing drawing, gallery, tutorial, localization, and rendering features are described in the README, but are not new additions in this patch release.

The version gate in `Shared/AppReleaseFeatures.swift` remains unchanged: Pencil, Crayon, Watercolor, white ink, and photo-transfer controls require major version 2 or later. The iPhone companion source is not compiled into the current watch container.

## Before publishing

- Build and archive the **Paint All the Time (Watch) Watch App** scheme with Release configuration.
- Confirm the archived app and watch container both report version **1.0.1** and build **2**. If that build number is already used in App Store Connect, increase it consistently before uploading.
- Check the new icon on supported watchOS versions, including its appearance on the Home Screen and in the App Store preview.
- Run `bash Tests/check-watch-bitmap.sh` and check first launch, tutorial, drawing tools, undo/redo, saving, reopening, sharing, and language changes on a watch.
- Verify an upgrade from 1.0.0 preserves saved drawings and settings.
- Use the What's New text above and confirm the support, marketing, and privacy URLs in App Store Connect.
- After publication, record the release date in `CHANGELOG.md` and tag the released commit `v1.0.1`.
