import CoreGraphics
import Foundation

/// Converts rendered images into the 1-bit layout the glasses expect.
///
/// Rows run top-to-bottom, each row is MSB-first, and a set bit is a lit pixel.
/// `G1BitmapFrame` handles the BMP wrapping and row inversion from here.
public enum G1MonochromeBitmapPacker {
    /// Packs `image` into bit-packed rows, or `nil` if a grayscale context for it
    /// cannot be created.
    public static func packBits(from image: CGImage,
                                threshold: UInt8 = G1NavigationBitmapLayout.monochromeThreshold) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }

        var grayscale = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &grayscale,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let packedBytesPerRow = (width + 7) / 8
        var packed = [UInt8](repeating: 0, count: packedBytesPerRow * height)

        grayscale.withUnsafeBufferPointer { grayscaleBuffer in
            guard let grayscaleBase = grayscaleBuffer.baseAddress else {
                return
            }
            packed.withUnsafeMutableBufferPointer { packedBuffer in
                guard let packedBase = packedBuffer.baseAddress else {
                    return
                }
                for y in 0..<height {
                    let rowStart = y * width
                    let packedRowStart = y * packedBytesPerRow
                    for x in 0..<width {
                        let pixel = grayscaleBase[rowStart + x]
                        guard pixel >= threshold else {
                            continue
                        }
                        let byteOffset = packedRowStart + (x / 8)
                        let bitMask = UInt8(0x80 >> (x % 8))
                        packedBase[byteOffset] |= bitMask
                    }
                }
            }
        }

        return Data(packed)
    }

    /// Packs `image` and wraps it in a frame sized to the image itself.
    public static func frame(from image: CGImage,
                             threshold: UInt8 = G1NavigationBitmapLayout.monochromeThreshold) throws -> G1BitmapFrame? {
        guard let packed = packBits(from: image, threshold: threshold) else {
            return nil
        }
        return try G1BitmapFrame(width: image.width, height: image.height, bitPackedRows: packed)
    }
}
