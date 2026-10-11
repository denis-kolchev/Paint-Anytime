# Аудит локализации — 11 октября 2026

Снимок относится к состоянию проекта перед запросом о 74% переводов, уже после предыдущих правок названий слоёв.

## Результат

| Каталог | Переводимые строки | Языки | Заполнение |
| --- | ---: | ---: | ---: |
| `Shared/Localizable.xcstrings` | 318 | 28 | 100% |
| `Paint Anytime Complications/Localizable.xcstrings` | 7 | 28 | 100% |

Всего 9100 заполненных пар «строка — язык». Это покрытие каталогов, а не подтверждение отображения на устройстве или независимая лингвистическая экспертиза. Сборка, тесты проекта и запуск симулятора не выполнялись по просьбе пользователя. Выполнена только сверка структуры каталогов, наличия переводов, статусов и форматных параметров.

## Что отсутствовало

- В основном каталоге было 324 записи. Для 26 языков, кроме английского и русского, были заполнены 239 записей: 239 / 324 ≈ 73,8%, что соответствует показанным 74%.
- 77 текстов имели только английский и русский варианты: добавлены 2002 перевода.
- Ключи `Close` и `Cancel` отсутствовали в каталоге целиком, хотя использовались через `L10n.text`: добавлены 56 переводов. `Close` — закрытие окна размера холста (`WatchCanvasSizeView.swift`); `Cancel` — отмена действий с палитрами (`ToolSettings/InkPaletteLibrary.swift`).
- В каталоге расширения циферблата семь строк имели только русский вариант. Английский использовался из исходных ключей, остальные языки отсутствовали. Добавлены явные английские варианты и 26 остальных языков: 189 записей.
- Шесть дополнительных записей содержали только числовые форматы и символы. Они отмечены как не требующие перевода: `%lld / %lld`, `%lld %@`, `%lld × %lld px`, `%lld%%`, `−`, `✓`. Уже существовавшие исключения `%lld/%lld` и название `Paint All the Time` сохранены. Английские слова не использованы как замена недостающим переводам.

Названия `Layer %d`, `Layers`, `Canvas`, `Add layer` на момент этого аудита уже были переведены на 28 языков предыдущей правкой.

## Полный список 77 строк, имевших только английский и русский перевод

### Справка о смешивании цветов — 23

- About color blending
- Add darker accents without lightening existing dark details. Each RGB channel keeps the darker value. Useful for reinforcing linework or shading; repeated identical opaque passes stop changing the result.
- Add light accents while protecting brighter details. Each RGB channel keeps the lighter value. Useful for highlights on dark paint; it cannot leave a visible mark over white.
- Add light for sparks, neon, and bright glow. RGB values add together and clip at white, so highlights can lose detail quickly. Best over dark paint with low opacity.
- Blend chart: yellow passes increase to the right; blue passes increase downward.
- Block in flat colors, paint over mistakes, and add crisp details. Opaque strokes replace the color below. Lower opacity lets you build transitions gradually without extra darkening.
- Blue over yellow
- Build soft highlights, haze, and reflected light over darker paint. Repeated passes brighten the image. Black has no effect, and Screen cannot add visible color over white.
- Build up color for painterly shading. Like Multiply, repeated strokes deepen shadows, but retain more of the brush color instead of quickly turning black. The default for marker and watercolor.
- Combines darkening with the new color. Overlaps keep more of the new color than Multiply. A balanced choice for layered strokes.
- Create intense glow, hot highlights, and luminous edges over existing color. Bright brush colors quickly push highlights toward white. Use low opacity; the effect is invisible over white.
- Create softer inverted colors and muted graphic effects. Similar to Difference with gentler contrast. Black has no effect; white inverts the image. Try it for stylized color shifts.
- Deepen rich colored shadows and add gritty contrast. Dark brush colors can quickly crush detail to black. Use low opacity over existing paint; pure white stays white.
- Each example shows blue watercolor over yellow at full opacity.
- Explore inverted colors and graphic effects. Similar colors turn dark; white inverts the underlying color, while black leaves it unchanged. Useful for experimental palettes rather than natural shading.
- Gently warm or cool existing paint and adjust its lighting. Softer than Overlay, useful for subtle shading and atmosphere. Neutral 50% gray has no effect; work over midtones.
- Multiplies the new color with the color underneath. Overlaps become darker: blue over yellow turns green. Useful for shadows and glazing.
- Paint colored shadows, deepen folds, or tint a sketch while keeping dark lines visible. Each pass darkens the underlying colors. White has no effect; many passes can make shadows muddy.
- Paint dramatic light and strong colored shadows. Light brush colors brighten; dark brush colors deepen the image. Useful for bold lighting accents; lower opacity for more control.
- Places the new color over the old one without extra darkening. Opaque watercolor covers the color underneath; translucent strokes let it show through.
- The first stroke colors empty canvas. Blending changes how later strokes overlap existing paint. The white canvas backing is not white paint.
- Tint existing shading while boosting contrast: shadows deepen and light areas brighten. Useful for color accents on a modeled form. Pure black and white stay unchanged; start over midtones.
- Yellow → · Blue ↓ / 0–10 passes, 80% opacity. Yellow first, then blue. Watercolor example; marker builds up more gently.

### Палитры и группы цветов — 14

- Add color
- Basic colors
- Black & white
- Blues
- Browns
- Create color
- Greens
- Light blues
- New palette
- Oranges
- Palettes
- Purples
- Reds
- Yellows

### Размер, обрезка и поворот холста — 20

- Adjust size
- Apply
- Canvas size
- Choose dimensions from 1 to 1024 pixels.
- Crop
- Crop area
- Height
- Horizontal
- Keep
- Keep drawing at original size
- Move left
- Move right
- Resample image
- Resolution
- Rotate
- Rotation
- Scale drawing with canvas
- Scale proportionally
- Trim canvas edges. Hidden strokes remain editable.
- Vertical

### Слои, фон и общие действия — 17

- Edit
- All layers
- Canvas actions
- Canvas color
- Close drawing controls
- Gray background
- Lock transparency
- Move down
- Move up
- Not selected
- Only this layer
- Open drawing controls
- Selected
- Settings
- Show all layers
- Show only this layer
- Visible

### Пипетка и заливка — 3

- Eyedropper
- Fill
- Tap to fill a connected area with the selected color and opacity.

## Расширение циферблата: семь строк

- New canvas
- Gallery
- Open a fresh canvas in Paint Anytime.
- Open your saved drawings in Paint Anytime.
- Open Paint Anytime
- Open App
- Open Paint Anytime without changing your canvas.

## Квадраты вместо корейских и китайских символов

В каталоге есть корректные Unicode-строки, включая `图层`, `圖層` и `레이어`; названия языков также записаны корректно. В приложении используются системные шрифты, пользовательских шрифтов и принудительной латинской гарнитуры не найдено. Отсутствующий перевод дал бы английскую подпись из fallback, а не квадраты на месте имеющихся символов.

Внесены две правки:

1. Корень приложения часов явно задаёт `typesettingLanguage` из выбранного языка вместе с `locale`.
2. Каждый пункт списка языков задаёт собственные `typesettingLanguage` и `locale`, чтобы его самоназвание набиралось на соответствующем языке, независимо от языка интерфейса.

Китайские варианты — упрощённый (`zh-Hans`) и традиционный (`zh-Hant`), а не два традиционных. По количеству символов на снимке третий проблемный пункт похож на корейский (`한국어`); без просмотра выбранного кода это не установлено окончательно.

Правка устраняет неоднозначность языкового контекста набора. Она не устанавливает отсутствующие системные шрифты. Причина квадратов на конкретном симуляторе и результат исправления остаются неподтверждёнными, поскольку приложение не запускалось. Если после сборки квадраты сохранятся, нужно сравнить те же строки в другом runtime и на физических часах, а также проверить отображение этих языков в системных экранах симулятора.

Справочные материалы Apple:

- [TypesettingLanguage](https://developer.apple.com/documentation/swiftui/typesettinglanguage) — явный выбор языка набора текста.
- [Build multilingual-ready apps, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10185/) — многоязычный набор и выбор языкового контекста.
- [Сообщение о проблемах Unicode в симуляторе Xcode](https://developer.apple.com/forums/thread/817957) — похожая проблема описана для iOS; это не подтверждение того же дефекта в watchOS 26.
