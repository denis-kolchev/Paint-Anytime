# Localization

## Source of truth

The supported languages and their native names are defined in
[`AppLanguage.supported`](../Shared/AppLanguage.swift). Translations live in
[`Shared/Localizable.xcstrings`](../Shared/Localizable.xcstrings), and project
localizations are registered in the [Xcode project](../Paint%20All%20the%20Time.xcodeproj/project.pbxproj).
Use these files for the current language list and translation coverage; this guide
does not duplicate counts that change as the app grows.

## Language selection

The watch app offers **More → Language** and a language picker during onboarding.
Languages are sorted by their native names using `AppLanguage.displayOrder` and
Foundation's `localizedStandardCompare`. System collation determines the order;
changing the in-app language does not change the sorting rule.

Selection is stored locally on the watch in UserDefaults (`app.language`). On first
launch, the app matches `Locale.preferredLanguages` in preference order, including
regional variants, and falls back to English. A supported manual selection takes
priority on later launches.

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
- Norwegian uses Bokmål (`nb`), labelled “Norsk”. Punjabi uses Gurmukhi (`pa`).
- Layout direction follows the selected language through
  `Locale.Language.characterDirection`, including right-to-left layout for Arabic,
  Urdu, and Hebrew.

Native language names are displayed verbatim so users can recover from an
accidental selection.

## Adding or updating translations

1. Add a new language to the project's localizations in Xcode.
2. Translate every translatable entry in `Shared/Localizable.xcstrings`. Preserve
   format placeholders and their types; use positional placeholders such as
   `%1$d` and `%2$d` when word order changes. Keep language-neutral entries marked
   as non-translatable.
3. For a new language, add its identifier and native name to `AppLanguage.supported`
   in `Shared/AppLanguage.swift`. The picker uses this registry automatically.
4. Check catalog coverage against the supported registry and verify placeholders.
   Translation presence alone does not establish linguistic quality.
5. Build and review the onboarding, menus, tools, gallery, confirmations, and
   VoiceOver on a watch simulator or device. Check long translations and
   right-to-left layouts, including directional controls and canvas interaction.
   Seek native-speaker review for new or substantially revised translations.

## Using localized strings in code

Use `L10n.text` for interface strings and model/error titles, and `L10n.format` for
formatted values. Both helpers are defined in `Shared/AppLanguage.swift`. Add new
English keys and translations to the catalog.

Views resolving strings through these helpers observe `AppLanguage.storageKey`
with `@AppStorage`, so language changes invalidate their body without changing view
identity. Do not use translated display names as identifiers for persisted drawings.
