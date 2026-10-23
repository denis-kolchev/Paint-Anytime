# Tutorial Crown hint placement

watchOS `WKInterfaceDevice.crownOrientation` supplies the side, not the physical
Crown's coordinates. The tutorial uses a screen-size calibration table, with no
runtime dependency on private APIs or simulator files.

Calibration source: installed Apple DeviceKit profiles under
`/Library/Developer/DeviceKit/Chrome/watch*.devicechrome/Contents/Resources/`.
Device-type `profile.plist` files in `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/`
map watch families to these chrome identifiers.

The right-side Crown center, in screen points from the screen's top, is:

`inputs[digital-crown].offsets.normal.y + DigitalCrown.pdf MediaBox height / 2 - images.sizing.topHeight`

| Screen (points) | Chrome | Offset | Crown height | Top border | Center Y |
| --- | --- | --- | --- | --- | --- |
| 162 × 197 | watch2 | 54 | 46 | 28 | 49 |
| 184 × 224 | watch2b | 62 | 46 | 28 | 57 |
| 176 × 215 | watch3s | 55 | 46 | 22 | 56 |
| 198 × 242 | watch3b | 65 | 46 | 22 | 66 |
| 187 × 223 | watch5s | 55 | 46 | 22 | 56 |
| 208 × 248 | watch5b | 65 | 46 | 22 | 66 |
| 205 × 251 | watch4 | 81 | 67 | 31 | 83.5 |
| 211 × 257 | watch6 | 84 | 65 | 31 | 85.5 |

These centers agree approximately with the four supplied simulator screenshots
(40 mm SE, 44 mm SE, 42 mm Series 10, 46 mm Series 12). Simulator artwork is a
calibration reference, not a guarantee of hardware measurements.

Left-side orientation mirrors both axes because the case is rotated 180 degrees.
Screen coordinates are converted into the overlay's local coordinates so safe-area
or container offsets do not shift the hint. Unknown screen sizes use a 26%-height
fallback; new hardware with a different Crown position needs calibration.
