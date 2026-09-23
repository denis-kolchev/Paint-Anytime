# Localization

The watch app offers **More → Language**, with 31 languages sorted by their native names. Selection is stored
in UserDefaults (`app.language`) and updates existing views without resetting the
canvas or navigation. On first launch it uses the closest supported device language,
falling back to English. The default explicitly matches `Locale.preferredLanguages` in preference order,
including regional variants such as `ru-RU` and `en-GB`. A manually selected language
takes priority on later launches. This preference is local to the watch.

Changing language shows an indeterminate progress indicator and temporarily disables
the list and dismissal. The indicator gets a render opportunity before the preference
changes and remains through the initial UI update; the view identity stays intact.

## Adding languages

1. Add the language to the project's localizations in Xcode.
2. Translate every entry in `Shared/Localizable.xcstrings`. Keep format placeholders
   (`%d`) intact; use positional placeholders (`%1$d`, `%2$d`) if word order changes.
3. Add its language identifier and native name to `AppLanguage.supported` in
   `Shared/AppLanguage.swift`. The scrolling selection list updates automatically.
4. Build and check the menu, tools, gallery, confirmations and VoiceOver on a watch
   simulator, especially long translations. Arabic and Urdu use right-to-left layout. Check directional controls and canvas
   interaction when reviewing these languages.

All 77 app-owned interface strings have translations for all 31 supported languages.
The brand name and numeric counters are marked as language-neutral.
There is no hard-coded language limit; additional languages use the same catalog and list. Missing translations fall back to English. Language names are intentionally
shown in their native spelling so users can recover from an accidental selection.

Use `L10n.text` for UI strings and model/error titles, and `L10n.format` for formatted
values. Put new English keys and translations in the catalog. Views that resolve
strings through this helper observe `AppLanguage.storageKey` with `@AppStorage` so
that changing language invalidates their body without changing view identity.
Do not store translated display names as identifiers for persisted drawing data.

System-owned sheets and system error descriptions may follow the device language.
The watch preference does not change the iPhone companion app's language.

## Current language variants

The language list uses `AppLanguage.displayOrder`, sorting native names with Foundation's
`localizedStandardCompare`. The system locale determines collation across scripts;
changing the in-app language does not reorder the list. The underlying `supported`
registry stays separate so display sorting does not affect language negotiation.
Chinese uses separate `zh-Hans` (Simplified) and `zh-Hant` (Traditional) resources.
Norwegian uses Bokmål (`nb`), labelled “Norsk”. Punjabi uses Gurmukhi (`pa`).
Portuguese uses the generic `pt` locale with European Portuguese wording.
Arabic (`ar`) and Urdu (`ur`) update SwiftUI layout direction along with the locale.

The added translations have been checked for completeness and format placeholders.
Builds and on-device review are performed by the project owner. Native-speaker and
watch-layout review of the new translations is still pending.
