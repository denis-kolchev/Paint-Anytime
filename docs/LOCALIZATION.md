# Localization

## Source of truth

The supported languages and their native names are defined in
[`AppLanguage.supported`](../Shared/AppLanguage.swift). Translations live in
[`Shared/Localizable.xcstrings`](../Shared/Localizable.xcstrings) and the
[complication catalog](../Paint%20Anytime%20Complications/Localizable.xcstrings), and project
localizations are registered in the [Xcode project](../Paint%20Anytime.xcodeproj/project.pbxproj).
Use these files for the current language list and translation coverage; this guide
does not duplicate counts that change as the app grows.

The watch-only distribution container (`Paint Anytime (Watch)`) also includes
`Shared/Localizable.xcstrings` in its Resources phase. This produces localized
resources in the outer app bundle as well as the watch app, so the submitted
package exposes the supported languages to the App Store. Keep this reference
pointing to the shared catalog instead of maintaining a separate language list.
The App Store language list comes from the uploaded app's localized resources;
translated store descriptions and screenshots are managed separately in App Store
Connect.

## Language selection

The watch app offers **More → Language** and a language picker during onboarding.
Languages are sorted by their native names using `AppLanguage.displayOrder` and
Foundation's `localizedStandardCompare`. System collation determines the order;
changing the in-app language does not change the sorting rule.

Selection is stored locally on the watch in UserDefaults (`app.language`). On first
launch, the app matches `Locale.preferredLanguages` in preference order, including
regional variants, and falls back to English. A supported manual selection takes
priority on later launches. If a saved language is no longer supported, the app
uses the device’s supported language preferences, falling back to English.

On a fresh watch installation, the language confirmation question and its Yes/No
buttons use that same system-selected language, including Simplified or
Traditional Chinese. The system preferences are those of the Apple Watch; if its
language differs from the paired iPhone, the watch language takes precedence.

Changing language temporarily disables the picker and dismissal while a progress
overlay is shown. Existing views update without resetting the canvas or navigation.
Missing translations fall back to English, then to the readable English key.
System-owned sheets and error descriptions may follow the device language. The
watch preference does not change the iPhone companion app's language.

## Regional variants and layout

- Chinese has separate Simplified (`zh-Hans`) and Traditional (`zh-Hant`) resources.
- Portuguese has separate Portugal (`pt-PT`) and Brazil (`pt-BR`) resources. A saved
  legacy `pt` selection is resolved using the device's Portuguese preferences,
  falling back to `pt-PT`.
- Norwegian uses Bokmål (`nb`), labelled “Norsk”.
- Interface layout stays left-to-right for every language, including Arabic and
  Hebrew. Changing the language updates localization without mirroring controls.

Native language names are displayed verbatim so users can recover from an
accidental selection. The watch root explicitly sets `typesettingLanguage` from
the selected app language, while each native language name uses its own language
for typesetting and locale. This supplies the script context without replacing
system fonts or resetting the drawing session. Missing glyphs in a simulator may
still require investigation of its installed font resources; translated text alone
does not guarantee that the runtime has the fonts to render it.

## Adding or updating translations

1. Add a new language to the project's localizations in Xcode.
2. Translate every translatable entry in `Shared/Localizable.xcstrings` and
   `Paint Anytime Complications/Localizable.xcstrings`. Preserve
   format placeholders and their types; use positional placeholders such as
   `%1$d` and `%2$d` when word order changes. Keep language-neutral entries marked
   as non-translatable.
3. For a new language, add its identifier and native name to `AppLanguage.supported`
   in `Shared/AppLanguage.swift`. The picker uses this registry automatically.
4. Check catalog coverage against the supported registry and verify placeholders.
   Translation presence alone does not establish linguistic quality.
5. Build and review the onboarding, menus, tools, gallery, confirmations, and
   VoiceOver on a watch simulator or device. Check long translations and
   Arabic and Hebrew text, including directional controls and canvas interaction.
   Seek native-speaker review for new or substantially revised translations.

## Using localized strings in code

Use `L10n.text` for interface strings and model/error titles, and `L10n.format` for
formatted values. Use `L10n.percent` with a fractional value (0.5 for fifty percent)
for percentages. In prose, substitute that formatted string through `%@` and
`L10n.format`; do not embed a raw percent sign in translated sentences, where
catalog format parsing may interpret surrounding letters as a conversion specifier.
These helpers are defined in `Shared/AppLanguage.swift`. Add new
English keys and translations to the catalog.

Views resolving strings through these helpers observe `AppLanguage.storageKey`
with `@AppStorage`, so language changes invalidate their body without changing view
identity. Do not use translated display names as identifiers for persisted drawings.

## In-app privacy policy

The complete privacy policy is bundled for offline reading in all 28 supported
languages. `WatchLegalText.privacy` resolves each paragraph through `L10n.text`
using the current app language. The English source remains in `docs/PRIVACY.md`
and `WatchLegalText.privacyKeys`; keep both and every catalog translation in sync
when the policy changes. Preserve contact addresses, URLs, and the revision date.

## Coverage audit

The [11 October 2026 audit](localization-audit-2026-10-11.md) records the previously
missing strings, catalog coverage, and the scope of the CJK typesetting fix.
