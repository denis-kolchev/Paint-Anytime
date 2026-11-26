import Compression
import Foundation

/// Reads the layers of a Photoshop document: PSD version 1, RGB or Grayscale,
/// 8 or 16 bits, Raw / PackBits / ZIP channels. The counterpart of `PSDWriter`.
///
/// Parsing keeps only each layer's properties and where its channels are in the file;
/// `pixels(of:)` decodes one layer at a time, so the whole document never has to be
/// in memory as bitmaps. Anything else (PSB, CMYK, Lab, 32-bit, indexed) throws
/// `ReadError.unsupported`, and the caller falls back to the flattened image.
nonisolated struct PSDReader {
    enum ReadError: Error { case invalid, unsupported }

    enum ColorMode: Int { case grayscale = 1, rgb = 3 }

    struct Rect: Equatable {
        var top = 0, left = 0, bottom = 0, right = 0
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
        var isEmpty: Bool { width == 0 || height == 0 }
    }

    struct Channel {
        /// -1 transparency, -2 user mask, -3 real user mask, 0… colour.
        let id: Int16
        /// Offset of the channel's compression word in the file.
        var offset = 0
        let length: Int
    }

    struct Mask {
        var rect: Rect
        /// Mask value outside `rect`.
        var defaultValue: UInt8
        var isDisabled: Bool
        /// Channel holding the mask pixels: -3 when a real user mask exists, else -2.
        var channelID: Int16
    }

    /// Photoshop's "lsct" section types.
    enum Section: Int { case none = 0, openFolder = 1, closedFolder = 2, groupEnd = 3 }

    struct Layer {
        var name = ""
        var rect = Rect()
        var channels: [Channel] = []
        var blendMode = "norm"
        var opacity: UInt8 = 255
        var fillOpacity: UInt8 = 255
        /// Clipped to the nearest unclipped layer below it.
        var isClipped = false
        var isHidden = false
        var locksTransparency = false
        var mask: Mask?
        var section = Section.none
        /// A group's blend mode, stored with its section type ("pass" = pass through).
        var sectionBlendMode: String?
        var hasVectorMask = false
        var hasEffects = false
        /// Adjustment and fill layers: their look is computed, not stored as pixels.
        var isAdjustment = false

        var isFolder: Bool { section == .openFolder || section == .closedFolder }
    }

    let width: Int
    let height: Int
    let depth: Int
    let mode: ColorMode
    /// Pixels per inch; 72 when the file stores none.
    let resolution: Double
    /// Embedded ICC profile (resource 1039), applied to RGB pixels.
    let iccProfile: Data?
    /// Bottom to top, as stored, including group headers and ends.
    let layers: [Layer]

    private let data: Data

    /// `data` should be memory-mapped for large files: channels are read in place.
    init(data: Data) throws {
        // Zero-based indices throughout.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        var cursor = Cursor(data: data)
        guard try cursor.ascii(4) == "8BPS" else { throw ReadError.invalid }
        // Version 2 is PSB (large documents), with 8-byte lengths.
        guard try cursor.u16() == 1 else { throw ReadError.unsupported }
        try cursor.skip(6)
        _ = try cursor.u16() // Channels of the flattened image.
        height = Int(try cursor.u32())
        width = Int(try cursor.u32())
        depth = Int(try cursor.u16())
        let modeValue = Int(try cursor.u16())
        guard width > 0, height > 0, width <= PSDWriter.maximumSide, height <= PSDWriter.maximumSide
        else { throw ReadError.invalid }
        guard let mode = ColorMode(rawValue: modeValue), depth == 8 || depth == 16
        else { throw ReadError.unsupported }
        self.mode = mode

        try cursor.skip(Int(try cursor.u32())) // Colour mode data.

        let resourcesLength = Int(try cursor.u32())
        let resourcesEnd = cursor.offset + resourcesLength
        guard resourcesEnd <= data.count else { throw ReadError.invalid }
        var resolution = 72.0
        var profile: Data?
        while cursor.offset + 12 <= resourcesEnd {
            guard try cursor.ascii(4) == "8BIM" else { break }
            let id = try cursor.u16()
            let nameLength = Int(try cursor.u8())
            // Pascal name, padded so length byte + name is even.
            try cursor.skip(nameLength + (nameLength % 2 == 0 ? 1 : 0))
            let size = Int(try cursor.u32())
            let start = cursor.offset
            guard start + size <= resourcesEnd else { break }
            if id == 1005, size >= 8 {
                // ResolutionInfo: horizontal 16.16 fixed, then unit (1 ppi, 2 ppcm).
                let fixed = Double(try cursor.u32()) / 65_536
                let unit = try cursor.u16()
                let ppi = unit == 2 ? fixed * 2.54 : fixed
                if ppi.isFinite, ppi > 0 { resolution = ppi }
            } else if id == 1039, size > 0 {
                profile = data.subdata(in: start..<(start + size))
            }
            cursor.offset = start + size + size % 2
        }
        self.resolution = resolution
        iccProfile = profile
        cursor.offset = resourcesEnd

        let sectionLength = Int(try cursor.u32())
        let sectionEnd = cursor.offset + sectionLength
        guard sectionEnd <= data.count else { throw ReadError.invalid }
        var layers: [Layer] = []
        if sectionLength >= 4 {
            let infoLength = Int(try cursor.u32())
            let infoEnd = cursor.offset + infoLength
            guard infoEnd <= sectionEnd else { throw ReadError.invalid }
            if infoLength > 0 {
                layers = try Self.layerInfo(data: data, from: cursor.offset, to: infoEnd, depth: depth)
            }
            cursor.offset = infoEnd
            if layers.isEmpty, cursor.offset + 4 <= sectionEnd {
                try cursor.skip(Int(try cursor.u32())) // Global layer mask info.
                // 16-bit documents keep their layers in an "Lr16" block instead.
                layers = try Self.globalLayerBlock(data: data, cursor: &cursor, end: sectionEnd, depth: depth)
            }
        }
        self.layers = layers
    }

    /// The layer's pixels as straight-alpha RGBA, `rect.width × rect.height`, with its
    /// pixel mask applied. Nil for a layer without pixels.
    func pixels(of layer: Layer) throws -> [UInt8]? {
        let rect = layer.rect
        guard !rect.isEmpty else { return nil }
        let count = rect.width * rect.height
        var rgba = [UInt8](repeating: 255, count: count * 4)
        let colorIDs: [Int16] = mode == .rgb ? [0, 1, 2] : [0]
        for channel in layer.channels {
            let target: [Int]
            if channel.id == -1 {
                target = [3]
            } else if let index = colorIDs.firstIndex(of: channel.id) {
                // Grayscale fills red, green and blue with its one channel.
                target = mode == .rgb ? [index] : [0, 1, 2]
            } else {
                continue
            }
            let plane = try self.plane(channel, width: rect.width, height: rect.height)
            for offset in target {
                var destination = offset
                for value in plane {
                    rgba[destination] = value
                    destination += 4
                }
            }
        }
        // A vector mask alone has mask data but no pixel channel; it is not applied.
        if let mask = layer.mask, !mask.isDisabled,
           let maskChannel = layer.channels.first(where: { $0.id == mask.channelID }) {
            let planeRect = mask.rect
            let plane: [UInt8]? = planeRect.isEmpty ? nil
                : try self.plane(maskChannel, width: planeRect.width, height: planeRect.height)
            for y in 0..<rect.height {
                let canvasY = rect.top + y
                for x in 0..<rect.width {
                    let canvasX = rect.left + x
                    var value = mask.defaultValue
                    if let plane, canvasY >= planeRect.top, canvasY < planeRect.bottom,
                       canvasX >= planeRect.left, canvasX < planeRect.right {
                        value = plane[(canvasY - planeRect.top) * planeRect.width + canvasX - planeRect.left]
                    }
                    let index = (y * rect.width + x) * 4 + 3
                    rgba[index] = UInt8((Int(rgba[index]) * Int(value) + 127) / 255)
                }
            }
        }
        return rgba
    }

    // MARK: - Layer records

    private static func layerInfo(data: Data, from start: Int, to end: Int, depth: Int) throws -> [Layer] {
        var cursor = Cursor(data: data, offset: start)
        let count = abs(Int(try cursor.i16()))
        var layers: [Layer] = []
        layers.reserveCapacity(count)
        for _ in 0..<count {
            layers.append(try record(&cursor, end: end))
        }
        // Channel data follows the records, layer by layer, channel by channel.
        var offset = cursor.offset
        for index in layers.indices {
            for channel in layers[index].channels.indices {
                layers[index].channels[channel].offset = offset
                offset += layers[index].channels[channel].length
            }
        }
        guard offset <= end else { throw ReadError.invalid }
        return layers
    }

    private static func record(_ cursor: inout Cursor, end: Int) throws -> Layer {
        var layer = Layer()
        layer.rect = Rect(top: Int(try cursor.i32()), left: Int(try cursor.i32()),
                          bottom: Int(try cursor.i32()), right: Int(try cursor.i32()))
        let channelCount = Int(try cursor.u16())
        guard channelCount <= 56 else { throw ReadError.invalid }
        for _ in 0..<channelCount {
            layer.channels.append(Channel(id: try cursor.i16(), length: Int(try cursor.u32())))
        }
        guard try cursor.ascii(4) == "8BIM" else { throw ReadError.invalid }
        layer.blendMode = try cursor.ascii(4)
        layer.opacity = try cursor.u8()
        layer.isClipped = try cursor.u8() != 0
        let flags = try cursor.u8()
        layer.locksTransparency = flags & 0x01 != 0
        layer.isHidden = flags & 0x02 != 0
        try cursor.skip(1)
        let extraLength = Int(try cursor.u32())
        let extraEnd = cursor.offset + extraLength
        guard extraEnd <= end else { throw ReadError.invalid }

        let maskLength = Int(try cursor.u32())
        let maskStart = cursor.offset
        guard maskStart + maskLength <= extraEnd else { throw ReadError.invalid }
        if maskLength >= 18 {
            layer.mask = try mask(cursor: cursor, length: maskLength, hasRealMask: layer.channels.contains { $0.id == -3 })
        }
        cursor.offset = maskStart + maskLength
        try cursor.skip(Int(try cursor.u32())) // Blending ranges.

        let nameLength = Int(try cursor.u8())
        let nameStart = cursor.offset
        guard nameStart + nameLength <= extraEnd else { throw ReadError.invalid }
        layer.name = String(decoding: cursor.data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
        // Length byte + name, padded to a multiple of 4.
        cursor.offset = nameStart - 1 + (nameLength + 1 + 3) / 4 * 4

        while let block = try nextBlock(&cursor, end: extraEnd) {
            var body = Cursor(data: cursor.data, offset: block.start)
            switch block.key {
            case "luni" where block.length >= 4:
                let units = Int(try body.u32())
                if units > 0, units * 2 + 4 <= block.length {
                    var characters: [UInt16] = []
                    for _ in 0..<units { characters.append(try body.u16()) }
                    let name = String(decoding: characters, as: UTF16.self)
                    layer.name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                }
            case "lsct", "lsdk":
                if block.length >= 4 {
                    layer.section = Section(rawValue: Int(try body.u32())) ?? .none
                }
                if block.length >= 12 {
                    try body.skip(4)
                    layer.sectionBlendMode = try body.ascii(4)
                }
            case "iOpa" where block.length >= 1:
                layer.fillOpacity = try body.u8()
            case "lfx2", "lrFX", "lmfx":
                layer.hasEffects = true
            case "vmsk", "vsms":
                layer.hasVectorMask = true
            case _ where Self.adjustmentKeys.contains(block.key):
                layer.isAdjustment = true
            default:
                break
            }
            cursor.offset = block.start + block.length
        }
        cursor.offset = extraEnd
        return layer
    }

    private static func mask(cursor: Cursor, length: Int, hasRealMask: Bool) throws -> Mask {
        var body = cursor
        let rect = Rect(top: Int(try body.i32()), left: Int(try body.i32()),
                        bottom: Int(try body.i32()), right: Int(try body.i32()))
        let defaultValue = try body.u8()
        let flags = try body.u8()
        var mask = Mask(rect: rect, defaultValue: defaultValue, isDisabled: flags & 0x02 != 0, channelID: -2)
        guard hasRealMask, length >= 36 else { return mask }
        // With both a vector and a pixel mask, the pixel mask is the "real" one. Writers
        // disagree on whether mask parameters come before the real fields; take the
        // reading whose rectangle makes sense.
        var parameters = 0
        if flags & 0x10 != 0 {
            var probe = body
            let present = try probe.u8()
            parameters = 1 + (present & 0x01 != 0 ? 1 : 0) + (present & 0x02 != 0 ? 8 : 0)
                + (present & 0x04 != 0 ? 1 : 0) + (present & 0x08 != 0 ? 8 : 0)
        }
        let maskStart = cursor.offset
        for skip in (parameters == 0 ? [0] : [parameters, 0]) where 18 + skip + 18 <= length {
            var real = Cursor(data: cursor.data, offset: maskStart + 18 + skip)
            let realFlags = try real.u8()
            let realDefault = try real.u8()
            let realRect = Rect(top: Int(try real.i32()), left: Int(try real.i32()),
                                bottom: Int(try real.i32()), right: Int(try real.i32()))
            guard realRect.bottom >= realRect.top, realRect.right >= realRect.left,
                  realRect.width <= 4 * PSDWriter.maximumSide, realRect.height <= 4 * PSDWriter.maximumSide
            else { continue }
            mask = Mask(rect: realRect, defaultValue: realDefault, isDisabled: realFlags & 0x02 != 0, channelID: -3)
            break
        }
        return mask
    }

    private static func globalLayerBlock(data: Data, cursor: inout Cursor, end: Int, depth: Int) throws -> [Layer] {
        while let block = try nextBlock(&cursor, end: end) {
            if block.key == "Lr16" || block.key == "Layr" {
                return try layerInfo(data: data, from: block.start, to: block.start + block.length, depth: depth)
            }
            cursor.offset = block.start + block.length
        }
        return []
    }

    /// The next tagged block before `end`. Writers pad block lengths differently, so a
    /// signature is also looked for up to three bytes later.
    private static func nextBlock(_ cursor: inout Cursor, end: Int) throws -> (key: String, start: Int, length: Int)? {
        for padding in 0...3 {
            let offset = cursor.offset + padding
            guard offset + 12 <= end else { return nil }
            var probe = Cursor(data: cursor.data, offset: offset)
            let signature = try probe.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { continue }
            let key = try probe.ascii(4)
            let length = Int(try probe.u32())
            guard probe.offset + length <= end else { return nil }
            cursor.offset = probe.offset
            return (key, probe.offset, length)
        }
        return nil
    }

    private static let adjustmentKeys: Set<String> = [
        "levl", "curv", "brit", "blnc", "hue ", "hue2", "selc", "thrs", "nvrt", "post", "mixr",
        "grdm", "phfl", "expA", "vibA", "clrL", "blwh", "CgEd", "SoCo", "GdFl", "PtFl"
    ]

    // MARK: - Channels

    /// One channel as 8-bit values, `width × height`.
    private func plane(_ channel: Channel, width: Int, height: Int) throws -> [UInt8] {
        let count = width * height
        guard count > 0 else { return [] }
        guard channel.length >= 2, channel.offset + channel.length <= data.count else { throw ReadError.invalid }
        let bytesPerSample = depth / 8
        let rowBytes = width * bytesPerSample
        var cursor = Cursor(data: data, offset: channel.offset)
        let compression = try cursor.u16()
        let payload = cursor.offset..<(channel.offset + channel.length)
        var samples: [UInt8]
        switch compression {
        case 0:
            guard payload.count >= rowBytes * height else { throw ReadError.invalid }
            samples = [UInt8](data[payload.lowerBound..<(payload.lowerBound + rowBytes * height)])
        case 1:
            samples = try packBits(payload, rows: height, rowBytes: rowBytes)
        case 2, 3:
            samples = try inflate(payload, size: rowBytes * height)
            if compression == 3 { Self.undoPrediction(&samples, rows: height, width: width, bytesPerSample: bytesPerSample) }
        default:
            throw ReadError.unsupported
        }
        guard bytesPerSample == 2 else { return samples }
        var plane = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let value = Int(samples[index * 2]) << 8 | Int(samples[index * 2 + 1])
            plane[index] = UInt8((value * 255 + 32_767) / 65_535)
        }
        return plane
    }

    private func packBits(_ payload: Range<Int>, rows: Int, rowBytes: Int) throws -> [UInt8] {
        guard payload.count >= rows * 2 else { throw ReadError.invalid }
        var output = [UInt8](repeating: 0, count: rows * rowBytes)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var counts = payload.lowerBound
            var source = payload.lowerBound + rows * 2
            for row in 0..<rows {
                let length = Int(bytes[counts]) << 8 | Int(bytes[counts + 1])
                counts += 2
                let rowEnd = source + length
                guard rowEnd <= payload.upperBound else { throw ReadError.invalid }
                var destination = row * rowBytes
                let destinationEnd = destination + rowBytes
                while source < rowEnd, destination < destinationEnd {
                    let header = Int(Int8(bitPattern: bytes[source]))
                    source += 1
                    if header >= 0 {
                        let run = min(header + 1, destinationEnd - destination, rowEnd - source)
                        for offset in 0..<run { output[destination + offset] = bytes[source + offset] }
                        source += header + 1
                        destination += run
                    } else if header != -128 {
                        guard source < rowEnd else { break }
                        let value = bytes[source]
                        source += 1
                        let run = min(1 - header, destinationEnd - destination)
                        for offset in 0..<run { output[destination + offset] = value }
                        destination += run
                    }
                }
                source = rowEnd
            }
        }
        return output
    }

    private func inflate(_ payload: Range<Int>, size: Int) throws -> [UInt8] {
        // A zlib stream: skip its 2-byte header, Compression reads raw deflate.
        guard payload.count > 2, size > 0 else { throw ReadError.invalid }
        var output = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, size, base + payload.lowerBound + 2,
                                          payload.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ReadError.invalid }
        return output
    }

    /// ZIP with prediction stores each sample as the difference from the one to its left.
    private static func undoPrediction(_ samples: inout [UInt8], rows: Int, width: Int, bytesPerSample: Int) {
        guard width > 1 else { return }
        for row in 0..<rows {
            let start = row * width * bytesPerSample
            if bytesPerSample == 1 {
                for index in (start + 1)..<(start + width) {
                    samples[index] = samples[index] &+ samples[index - 1]
                }
            } else {
                var previous = UInt16(samples[start]) << 8 | UInt16(samples[start + 1])
                for column in 1..<width {
                    let index = start + column * 2
                    let value = (UInt16(samples[index]) << 8 | UInt16(samples[index + 1])) &+ previous
                    samples[index] = UInt8(value >> 8)
                    samples[index + 1] = UInt8(value & 0xFF)
                    previous = value
                }
            }
        }
    }

    // MARK: - Big-endian cursor

    struct Cursor {
        let data: Data
        var offset = 0

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= data.count else { throw ReadError.invalid }
            offset += count
        }

        mutating func u8() throws -> UInt8 {
            guard offset < data.count else { throw ReadError.invalid }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }

        mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

        mutating func ascii(_ count: Int) throws -> String {
            guard offset + count <= data.count else { throw ReadError.invalid }
            defer { offset += count }
            return String(decoding: data[offset..<(offset + count)], as: UTF8.self)
        }
    }
}
