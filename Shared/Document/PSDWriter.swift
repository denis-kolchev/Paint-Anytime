import CoreGraphics
import Foundation

/// Writes a layered Photoshop document: PSD version 1, 8-bit RGB, PackBits (RLE)
/// channels, layers bottom to top. Pure Core Graphics, so any target can encode;
/// only the watch can render the layers it is given.
///
/// Layers are encoded as they are appended, each cropped to its visible pixels,
/// so only one layer's bitmap needs to exist at a time.
nonisolated struct PSDWriter {
    let width: Int
    let height: Int
    /// Pixels per inch stored in the file.
    let resolution: Double

    private var records: [Data] = []
    private var channelData: [Data] = []

    /// PSD version 1 allows up to 30,000 px per side.
    static let maximumSide = 30_000

    init(width: Int, height: Int, resolution: Double) throws {
        guard width > 0, height > 0, width <= Self.maximumSide, height <= Self.maximumSide else {
            throw PSDError.invalidSize
        }
        self.width = width
        self.height = height
        self.resolution = resolution.isFinite && resolution > 0 ? resolution : 72
    }

    var layerCount: Int { records.count }

    /// Appends a layer from `image`, drawn over the whole canvas. Any pixel format;
    /// it is converted to straight-alpha sRGB RGBA.
    mutating func appendLayer(name: String, image: CGImage?, opacity: Float,
                              isVisible: Bool, locksTransparency: Bool) throws {
        guard let image else {
            append(name: name, rect: .empty, channels: Self.emptyChannels, opacity: opacity,
                   isVisible: isVisible, locksTransparency: locksTransparency)
            return
        }
        let pixels = try Self.straightRGBA(of: image, width: width, height: height)
        guard let rect = Self.opaqueBounds(pixels, width: width, height: height) else {
            append(name: name, rect: .empty, channels: Self.emptyChannels, opacity: opacity,
                   isVisible: isVisible, locksTransparency: locksTransparency)
            return
        }
        // Photoshop channel ids: -1 transparency, then red, green, blue.
        let layout: [(id: Int16, offset: Int)] = [(-1, 3), (0, 0), (1, 1), (2, 2)]
        let channels: [(id: Int16, data: Data)] = layout.map { channel in
            (channel.id, Self.layerChannel(pixels, stride: width * 4, offset: channel.offset, rect: rect))
        }
        append(name: name, rect: rect, channels: channels, opacity: opacity,
               isVisible: isVisible, locksTransparency: locksTransparency)
    }

    /// Appends a layer filled with one straight-alpha sRGB colour (components 0…1),
    /// encoded directly as runs without a bitmap.
    mutating func appendSolidLayer(name: String, color: SIMD4<Float>, isVisible: Bool) {
        let rect = LayerRect(top: 0, left: 0, bottom: height, right: width)
        let components = [color.w, color.x, color.y, color.z].map(Self.byte)
        let channels: [(id: Int16, data: Data)] = zip([-1, 0, 1, 2] as [Int16], components).map { id, value in
            (id, Self.solidChannel(value: value, width: width, height: height))
        }
        append(name: name, rect: rect, channels: channels, opacity: 1, isVisible: isVisible, locksTransparency: false)
    }

    /// The finished file. `composite` is the flattened image other apps show without
    /// reading layers; `isOpaque` stores it as RGB, otherwise with its transparency.
    func data(composite: CGImage, isOpaque: Bool) throws -> Data {
        let pixels = try Self.straightRGBA(of: composite, width: width, height: height)
        let channelCount = isOpaque ? 3 : 4
        var out = BigEndianWriter()
        // File header.
        out.ascii("8BPS")
        out.u16(1)
        out.zeros(6)
        out.u16(UInt16(channelCount))
        out.u32(UInt32(height))
        out.u32(UInt32(width))
        out.u16(8)
        out.u16(3) // RGB
        // Color mode data: none for RGB.
        out.u32(0)
        // Image resources: ResolutionInfo (0x03ED).
        var resources = BigEndianWriter()
        resources.ascii("8BIM")
        resources.u16(0x03ED)
        resources.u16(0) // Empty name, padded to an even length.
        resources.u32(16)
        let fixed = UInt32(clamping: Int((resolution * 65_536).rounded()))
        for _ in 0..<2 {
            resources.u32(fixed)
            resources.u16(1) // Pixels per inch.
            resources.u16(1) // Shown in inches.
        }
        out.u32(UInt32(resources.data.count))
        out.append(resources.data)
        // Layer and mask information.
        var layerInfo = BigEndianWriter()
        // A negative count tells readers the composite's extra channel is its transparency.
        layerInfo.i16(Int16(clamping: isOpaque ? records.count : -records.count))
        records.forEach { layerInfo.append($0) }
        channelData.forEach { layerInfo.append($0) }
        layerInfo.pad(to: 4)
        out.u32(UInt32(4 + layerInfo.data.count + 4))
        out.u32(UInt32(layerInfo.data.count))
        out.append(layerInfo.data)
        out.u32(0) // Global layer mask info.
        // Merged image: one compression mark, every row's length, then the rows.
        let order = isOpaque ? [0, 1, 2] : [0, 1, 2, 3]
        var lengths = BigEndianWriter()
        var rows = Data()
        var row = [UInt8](repeating: 0, count: width)
        var packed: [UInt8] = []
        packed.reserveCapacity(width + width / 64 + 2)
        for offset in order {
            for y in 0..<height {
                let base = y * width * 4 + offset
                for x in 0..<width { row[x] = pixels[base + x * 4] }
                packed.removeAll(keepingCapacity: true)
                Self.packBits(row, into: &packed)
                lengths.u16(UInt16(packed.count))
                rows.append(contentsOf: packed)
            }
        }
        out.u16(1)
        out.append(lengths.data)
        out.append(rows)
        return out.data
    }

    // MARK: Layer records

    struct LayerRect {
        var top = 0, left = 0, bottom = 0, right = 0
        static let empty = LayerRect()
        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    /// Uncompressed, zero-sized channels for a layer without pixels.
    private static let emptyChannels: [(id: Int16, data: Data)] = ([-1, 0, 1, 2] as [Int16]).map { id in
        var raw = BigEndianWriter()
        raw.u16(0)
        return (id, raw.data)
    }

    private mutating func append(name: String, rect: LayerRect, channels: [(id: Int16, data: Data)],
                                 opacity: Float, isVisible: Bool, locksTransparency: Bool) {
        var record = BigEndianWriter()
        record.i32(Int32(rect.top))
        record.i32(Int32(rect.left))
        record.i32(Int32(rect.bottom))
        record.i32(Int32(rect.right))
        record.u16(UInt16(channels.count))
        for channel in channels {
            record.i16(channel.id)
            record.u32(UInt32(channel.data.count))
        }
        record.ascii("8BIM")
        record.ascii("norm")
        record.u8(Self.byte(opacity))
        record.u8(0) // Base clipping.
        // Bit 0: transparency protected; bit 1: hidden.
        record.u8((locksTransparency ? 1 : 0) | (isVisible ? 0 : 2))
        record.u8(0)
        var extra = BigEndianWriter()
        extra.u32(0) // No layer mask.
        extra.u32(0) // No blending ranges.
        extra.append(Self.pascalName(name))
        extra.append(Self.unicodeName(name))
        record.u32(UInt32(extra.data.count))
        record.append(extra.data)
        records.append(record.data)
        var data = Data()
        channels.forEach { data.append($0.data) }
        channelData.append(data)
    }

    /// The legacy name field: ASCII, padded to a multiple of 4 bytes with its length byte.
    private static func pascalName(_ name: String) -> Data {
        let ascii = name.unicodeScalars.prefix(255).map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }
        var out = BigEndianWriter()
        out.u8(UInt8(ascii.count))
        out.append(Data(ascii))
        out.pad(to: 4)
        return out.data
    }

    /// `luni`: the full Unicode name, which Photoshop prefers over the ASCII field.
    private static func unicodeName(_ name: String) -> Data {
        let units = Array(name.utf16.prefix(255))
        var body = BigEndianWriter()
        body.u32(UInt32(units.count))
        units.forEach { body.u16($0) }
        body.pad(to: 4)
        var out = BigEndianWriter()
        out.ascii("8BIM")
        out.ascii("luni")
        out.u32(UInt32(body.data.count))
        out.append(body.data)
        return out.data
    }

    // MARK: Pixels

    private static func byte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    /// `image` drawn over `width` × `height`, as straight-alpha sRGB RGBA bytes.
    private static func straightRGBA(of image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PSDError.pixels }
        // Photoshop stores colour without the alpha already multiplied in.
        var index = 0
        while index < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha != 0 && alpha != 255 {
                for component in index..<index + 3 {
                    pixels[component] = UInt8(min(255, (Int(pixels[component]) * 255 + alpha / 2) / alpha))
                }
            }
            index += 4
        }
        return pixels
    }

    /// The smallest rectangle holding every pixel with any alpha; nil when there is none.
    private static func opaqueBounds(_ pixels: [UInt8], width: Int, height: Int) -> LayerRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            var first = -1, last = -1
            for x in 0..<width where pixels[row + x * 4 + 3] != 0 {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            minX = min(minX, first)
            maxX = max(maxX, last)
            if minY == height { minY = y }
            maxY = y
        }
        guard maxX >= 0 else { return nil }
        return LayerRect(top: minY, left: minX, bottom: maxY + 1, right: maxX + 1)
    }

    /// One channel of a layer record: compression mark, row lengths, packed rows.
    private static func layerChannel(_ pixels: [UInt8], stride: Int, offset: Int, rect: LayerRect) -> Data {
        var lengths = BigEndianWriter()
        lengths.u16(1)
        var rows = Data()
        var row = [UInt8](repeating: 0, count: rect.width)
        var packed: [UInt8] = []
        packed.reserveCapacity(rect.width + rect.width / 64 + 2)
        for y in rect.top..<rect.bottom {
            let base = y * stride + offset
            for x in 0..<rect.width { row[x] = pixels[base + (rect.left + x) * 4] }
            packed.removeAll(keepingCapacity: true)
            packBits(row, into: &packed)
            lengths.u16(UInt16(packed.count))
            rows.append(contentsOf: packed)
        }
        var out = lengths.data
        out.append(rows)
        return out
    }

    private static func solidChannel(value: UInt8, width: Int, height: Int) -> Data {
        var packed: [UInt8] = []
        packBits([UInt8](repeating: value, count: width), into: &packed)
        var out = BigEndianWriter()
        out.u16(1)
        for _ in 0..<height { out.u16(UInt16(packed.count)) }
        let rowData = Data(packed)
        for _ in 0..<height { out.append(rowData) }
        return out.data
    }

    /// PackBits: runs of 3–128 equal bytes as (1 − n, byte), the rest as literals of
    /// up to 128 bytes as (n − 1, bytes…). A row of `n` bytes packs to at most
    /// n + ⌈n / 128⌉ bytes, within the 16-bit row lengths for any allowed width.
    static func packBits(_ row: [UInt8], into out: inout [UInt8]) {
        let count = row.count
        var index = 0
        while index < count {
            var run = 1
            while index + run < count, run < 128, row[index + run] == row[index] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[index])
                index += run
                continue
            }
            let start = index
            index += 1
            while index < count, index - start < 128 {
                if index + 2 < count, row[index] == row[index + 1], row[index] == row[index + 2] { break }
                index += 1
            }
            out.append(UInt8(index - start - 1))
            out.append(contentsOf: row[start..<index])
        }
    }

    enum PSDError: Error {
        case invalidSize, pixels
    }
}

/// Big-endian fields, as every PSD structure stores them.
private nonisolated struct BigEndianWriter {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
                                 UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func ascii(_ text: StaticString) {
        text.withUTF8Buffer { data.append(contentsOf: $0) }
    }
    mutating func zeros(_ count: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: count)) }
    mutating func append(_ other: Data) { data.append(other) }
    mutating func pad(to multiple: Int) {
        let remainder = data.count % multiple
        if remainder != 0 { zeros(multiple - remainder) }
    }
}
