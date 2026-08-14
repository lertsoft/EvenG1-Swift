import Foundation

public enum G1BitmapFrameError: Error, Equatable {
    case invalidDimensions
    case invalidByteCount(expected: Int, actual: Int)
}

public struct G1BitmapFrame: Sendable, Equatable {
    public static let defaultWidth = 576
    public static let defaultHeight = 135

    public let width: Int
    public let height: Int
    public let bitPackedRows: Data

    public var bytesPerRow: Int {
        (width + 7) / 8
    }

    public var byteCount: Int {
        bytesPerRow * height
    }

    /// A Windows 3.x 1-bit BMP matching the byte layout used by EvenDemoApp.
    /// Frame rows are stored top-to-bottom with `1` representing a lit pixel;
    /// BMP rows are emitted bottom-to-top and inverted for the vendor palette.
    public var bmpData: Data {
        let bitmapHeaderSize = 14
        let dibHeaderSize = 40
        let paletteSize = 8
        let pixelDataOffset = bitmapHeaderSize + dibHeaderSize + paletteSize
        let bmpBytesPerRow = (bytesPerRow + 3) & ~3
        let pixelBytesWithoutFilePadding = bmpBytesPerRow * height
        let unalignedFileSize = pixelDataOffset + pixelBytesWithoutFilePadding
        let trailingFilePadding = (4 - (unalignedFileSize % 4)) % 4
        let imageSize = pixelBytesWithoutFilePadding + trailingFilePadding
        let fileSize = pixelDataOffset + imageSize

        var data = Data()
        data.reserveCapacity(fileSize)

        // BITMAPFILEHEADER
        data.append(contentsOf: [0x42, 0x4D])
        data.appendLittleEndian(UInt32(fileSize))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(pixelDataOffset))

        // BITMAPINFOHEADER
        data.appendLittleEndian(UInt32(dibHeaderSize))
        data.appendLittleEndian(Int32(width))
        data.appendLittleEndian(Int32(height))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(imageSize))
        data.appendLittleEndian(Int32(2_834))
        data.appendLittleEndian(Int32(2_834))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))

        // Vendor palette: index 0 is white and index 1 is black.
        data.append(contentsOf: [
            0xFF, 0xFF, 0xFF, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])

        for row in (0..<height).reversed() {
            let rowStart = row * bytesPerRow
            let rowEnd = rowStart + bytesPerRow
            for byte in bitPackedRows[rowStart..<rowEnd] {
                data.append(~byte)
            }
            if bmpBytesPerRow > bytesPerRow {
                data.append(contentsOf: repeatElement(0, count: bmpBytesPerRow - bytesPerRow))
            }
        }

        if trailingFilePadding > 0 {
            data.append(contentsOf: repeatElement(0, count: trailingFilePadding))
        }
        return data
    }

    public init(width: Int = G1BitmapFrame.defaultWidth,
                height: Int = G1BitmapFrame.defaultHeight,
                bitPackedRows: Data) throws {
        guard width > 0, height > 0 else {
            throw G1BitmapFrameError.invalidDimensions
        }

        let expected = ((width + 7) / 8) * height
        guard bitPackedRows.count == expected else {
            throw G1BitmapFrameError.invalidByteCount(expected: expected, actual: bitPackedRows.count)
        }

        self.width = width
        self.height = height
        self.bitPackedRows = bitPackedRows
    }

    public static func blank(width: Int = G1BitmapFrame.defaultWidth,
                             height: Int = G1BitmapFrame.defaultHeight) throws -> G1BitmapFrame {
        guard width > 0, height > 0 else {
            throw G1BitmapFrameError.invalidDimensions
        }
        let byteCount = ((width + 7) / 8) * height
        return try G1BitmapFrame(width: width, height: height, bitPackedRows: Data(repeating: 0x00, count: byteCount))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
