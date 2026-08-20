import Foundation

/// Represents the G1 font metadata for text layout calculations
public struct G1FontData: Codable, Sendable {
    public let font: String
    public let glyphs: [G1Glyph]
    
    public init(font: String, glyphs: [G1Glyph]) {
        self.font = font
        self.glyphs = glyphs
    }
}

/// A single glyph in the G1 font
public struct G1Glyph: Codable, Sendable, Identifiable {
    public var id: Int { codePoint }
    
    public let codePoint: Int
    public let char: String
    public let width: Int
    public let height: Int
    
    enum CodingKeys: String, CodingKey {
        case codePoint = "code_point"
        case char
        case width
        case height
    }
    
    public init(codePoint: Int, char: String, width: Int, height: Int) {
        self.codePoint = codePoint
        self.char = char
        self.width = width
        self.height = height
    }
}

/// G1 Text Helper for calculating text layout and creating display commands
public final class G1TextHelper: @unchecked Sendable {
    
    // MARK: - Display Constants
    
    /// G1 display width in pixels
    public static let displayWidth: Int = 576
    
    /// G1 display height in pixels  
    public static let displayHeight: Int = 135
    
    /// Default character height
    public static let defaultCharHeight: Int = 26
    
    /// Spacing between characters (pixels)
    public static let charSpacing: Int = 1
    
    /// Spacing between lines (pixels)
    public static let lineSpacing: Int = 4
    
    /// Maximum characters per line (rough estimate for ASCII)
    public static let maxCharsPerLine: Int = 40
    
    /// Maximum lines on display
    public static let maxLines: Int = 5
    
    // MARK: - Font Data
    
    private var glyphWidths: [Int: Int] = [:]
    private var fontData: G1FontData?
    
    /// Default width for unknown characters
    public let defaultCharWidth: Int = 5
    
    // MARK: - Initialization
    
    public init() {
        loadEmbeddedFont()
    }
    
    /// Load font data from JSON
    public func loadFont(from data: Data) throws {
        let decoder = JSONDecoder()
        fontData = try decoder.decode(G1FontData.self, from: data)
        
        // Build lookup table
        glyphWidths.removeAll()
        for glyph in fontData?.glyphs ?? [] {
            glyphWidths[glyph.codePoint] = glyph.width
        }
    }
    
    /// Load the embedded font data
    private func loadEmbeddedFont() {
        // Load from embedded glyph widths table
        glyphWidths = Self.getDefaultGlyphWidths()
    }
    
    // MARK: - Text Measurement
    
    /// Get the pixel width of a character
    public func charWidth(_ char: Character) -> Int {
        guard let scalar = char.unicodeScalars.first else {
            return defaultCharWidth
        }
        let codePoint = Int(scalar.value)
        return glyphWidths[codePoint] ?? defaultCharWidth
    }
    
    /// Get the pixel width of a string
    public func stringWidth(_ text: String) -> Int {
        var width = 0
        var isFirstCharacter = true
        for char in text {
            if !isFirstCharacter {
                width += Self.charSpacing
            }
            width += charWidth(char)
            isFirstCharacter = false
        }
        return width
    }
    
    /// Check if a character is supported by the font
    public func isSupported(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return glyphWidths[Int(scalar.value)] != nil
    }
    
    /// Get all supported characters
    public func supportedCharacters() -> [Character] {
        fontData?.glyphs.compactMap { glyph in
            guard let scalar = Unicode.Scalar(glyph.codePoint) else { return nil }
            return Character(scalar)
        } ?? []
    }
    
    // MARK: - Text Layout
    
    /// Word-wrap text to fit within the display width
    public func wrapText(_ text: String, maxWidth: Int = displayWidth) -> [String] {
        var lines: [String] = []
        var currentLine = ""
        var currentWidth = 0
        
        let words = text.components(separatedBy: .whitespaces)
        
        for word in words {
            let wordWidth = stringWidth(word)
            let spaceWidth = charWidth(" ") + Self.charSpacing
            
            if currentLine.isEmpty {
                // First word on line
                if wordWidth <= maxWidth {
                    currentLine = word
                    currentWidth = wordWidth
                } else {
                    // Word too long, break it
                    let brokenLines = breakWord(word, maxWidth: maxWidth)
                    lines.append(contentsOf: brokenLines.dropLast())
                    if let lastPart = brokenLines.last {
                        currentLine = lastPart
                        currentWidth = stringWidth(lastPart)
                    }
                }
            } else {
                // Check if word fits on current line
                let neededWidth = currentWidth + spaceWidth + wordWidth
                
                if neededWidth <= maxWidth {
                    currentLine += " " + word
                    currentWidth = neededWidth
                } else {
                    // Start new line
                    lines.append(currentLine)
                    
                    if wordWidth <= maxWidth {
                        currentLine = word
                        currentWidth = wordWidth
                    } else {
                        // Word too long, break it
                        let brokenLines = breakWord(word, maxWidth: maxWidth)
                        lines.append(contentsOf: brokenLines.dropLast())
                        if let lastPart = brokenLines.last {
                            currentLine = lastPart
                            currentWidth = stringWidth(lastPart)
                        }
                    }
                }
            }
        }
        
        // Add remaining line
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        return lines
    }
    
    /// Break a single word that's too long
    private func breakWord(_ word: String, maxWidth: Int) -> [String] {
        var parts: [String] = []
        var currentPart = ""
        var currentWidth = 0
        
        for char in word {
            let charW = charWidth(char) + Self.charSpacing
            
            if currentWidth + charW > maxWidth && !currentPart.isEmpty {
                parts.append(currentPart)
                currentPart = String(char)
                currentWidth = charWidth(char)
            } else {
                currentPart.append(char)
                currentWidth += charW
            }
        }
        
        if !currentPart.isEmpty {
            parts.append(currentPart)
        }
        
        return parts
    }
    
    /// Calculate how many lines of text will fit on the display
    public func visibleLineCount() -> Int {
        return Self.displayHeight / (Self.defaultCharHeight + Self.lineSpacing)
    }
    
    // MARK: - Text Commands
    
    /// Create text display chunks for the G1 glasses
    /// Command format: 0x4E [seq] [total] [current] [flags] [pos_hi] [pos_lo] [page] [maxPages] [text...]
    public func createTextChunks(_ text: String, maxChunkSize: Int = 180) -> [[UInt8]] {
        let lines = wrapText(text)
        let displayText = lines.prefix(Self.maxLines).joined(separator: "\n")
        
        guard let textData = displayText.data(using: .utf8) else {
            return []
        }
        
        // Split into chunks if needed
        let textBytes = Array(textData)
        let headerSize = 9  // Fixed header bytes
        let maxPayload = maxChunkSize - headerSize
        
        var chunks: [[UInt8]] = []
        var offset = 0
        var seqNum: UInt8 = 0
        
        while offset < textBytes.count {
            let remaining = textBytes.count - offset
            let chunkSize = min(remaining, maxPayload)
            let isLast = offset + chunkSize >= textBytes.count
            
            var chunk: [UInt8] = [
                G1Command.SEND_TEXT.rawValue,  // 0x4E
                seqNum,                         // Sequence number
                UInt8(chunks.count + 1),        // Total packages (will update)
                UInt8(chunks.count),            // Current package (0-indexed)
                isLast ? 0x71 : 0x70,          // Flags: 0x71 = new content + show, 0x70 = continue
                0x00,                           // Char position high
                0x00,                           // Char position low
                0x01,                           // Page number
                0x01                            // Max pages
            ]
            
            chunk.append(contentsOf: textBytes[offset..<(offset + chunkSize)])
            chunks.append(chunk)
            
            offset += chunkSize
            seqNum = seqNum &+ 1
        }
        
        // Update total packages count in each chunk
        let totalPackages = UInt8(chunks.count)
        for i in 0..<chunks.count {
            chunks[i][2] = totalPackages
        }
        
        return chunks
    }
    
    /// Create a simple single-line text command
    public func createSimpleTextCommand(_ text: String) -> [UInt8] {
        guard let textData = text.prefix(Self.maxCharsPerLine).data(using: .utf8) else {
            return []
        }
        
        var command: [UInt8] = [
            G1Command.SEND_TEXT.rawValue,  // 0x4E
            0x00,                           // Sequence
            0x01,                           // Total packages
            0x00,                           // Current package
            0x71,                           // Flags: new content + show
            0x00,                           // Char position high
            0x00,                           // Char position low
            0x01,                           // Page number
            0x01                            // Max pages
        ]
        
        command.append(contentsOf: Array(textData))
        return command
    }
}

// MARK: - Embedded Font Data

extension G1TextHelper {
    /// Build the font lookup table programmatically
    /// Based on the G1 extended font glyph widths
    private static func buildDefaultGlyphWidths() -> [Int: Int] {
        var widths: [Int: Int] = [:]
        
        // ASCII printable characters (32-126)
        let asciiWidths: [(Int, Int)] = [
            (32, 2),   // space
            (33, 1),   // !
            (34, 2),   // "
            (35, 6),   // #
            (36, 5),   // $
            (37, 6),   // %
            (38, 7),   // &
            (39, 1),   // '
            (40, 2),   // (
            (41, 2),   // )
            (42, 3),   // *
            (43, 4),   // +
            (44, 1),   // ,
            (45, 4),   // -
            (46, 1),   // .
            (47, 3),   // /
            (48, 5), (49, 3), (50, 5), (51, 5), (52, 5),  // 0-4
            (53, 5), (54, 5), (55, 5), (56, 5), (57, 5),  // 5-9
            (58, 1),   // :
            (59, 1),   // ;
            (60, 4),   // <
            (61, 4),   // =
            (62, 4),   // >
            (63, 5),   // ?
            (64, 7),   // @
            (65, 6), (66, 5), (67, 5), (68, 5), (69, 4),  // A-E
            (70, 4), (71, 5), (72, 5), (73, 2), (74, 3),  // F-J
            (75, 5), (76, 4), (77, 7), (78, 5), (79, 5),  // K-O
            (80, 5), (81, 5), (82, 5), (83, 5), (84, 5),  // P-T
            (85, 5), (86, 6), (87, 7), (88, 6), (89, 6),  // U-Y
            (90, 5),   // Z
            (91, 2),   // [
            (92, 3),   // \
            (93, 2),   // ]
            (94, 4),   // ^
            (95, 3),   // _
            (96, 2),   // `
            (97, 5), (98, 4), (99, 4), (100, 4), (101, 4),   // a-e
            (102, 4), (103, 4), (104, 4), (105, 1), (106, 2), // f-j
            (107, 4), (108, 1), (109, 7), (110, 4), (111, 4), // k-o
            (112, 4), (113, 4), (114, 3), (115, 4), (116, 3), // p-t
            (117, 5), (118, 5), (119, 7), (120, 5), (121, 5), // u-y
            (122, 4),  // z
            (123, 3),  // {
            (124, 1),  // |
            (125, 3),  // }
            (126, 7),  // ~
        ]
        
        for (cp, w) in asciiWidths {
            widths[cp] = w
        }
        
        // Extended Latin characters
        let extendedWidths: [(Int, Int)] = [
            (192, 6), (193, 6), (194, 6), (195, 6), (196, 6), (197, 6), (198, 8),  // À-Æ
            (199, 5), (200, 4), (201, 4), (202, 4), (203, 4),  // Ç-Ë
            (204, 2), (205, 2), (206, 3), (207, 3), (208, 5),  // Ì-Ð
            (209, 5), (210, 5), (211, 5), (212, 5), (213, 5), (214, 5),  // Ñ-Ö
            (215, 4), (216, 6), (217, 5), (218, 5), (219, 5), (220, 5),  // ×-Ü
            (221, 6), (222, 5), (223, 4),  // Ý-ß
            (224, 5), (225, 5), (226, 5), (227, 5), (228, 5), (229, 5), (230, 8),  // à-æ
            (231, 4), (232, 4), (233, 4), (234, 4), (235, 4),  // ç-ë
            (236, 2), (237, 2), (238, 3), (239, 3), (240, 5),  // ì-ð
            (241, 4), (242, 4), (243, 4), (244, 4), (245, 4), (246, 4),  // ñ-ö
            (247, 4), (248, 5), (249, 5), (250, 5), (251, 5), (252, 5),  // ÷-ü
            (253, 5), (254, 4), (255, 5),  // ý-ÿ
            (376, 6),  // Ÿ
            (7838, 5), // ẞ (capital sharp s)
        ]
        
        for (cp, w) in extendedWidths {
            widths[cp] = w
        }
        
        // Special characters and symbols
        let specialWidths: [(Int, Int)] = [
            (162, 5),   // ¢
            (163, 6),   // £
            (165, 5),   // ¥
            (166, 1),   // ¦
            (167, 5),   // §
            (168, 3),   // ¨
            (169, 8),   // ©
            (171, 5),   // «
            (172, 5),   // ¬
            (174, 5),   // ®
            (175, 3),   // ¯
            (176, 2),   // °
            (177, 4),   // ±
            (180, 2),   // ´
            (182, 7),   // ¶
            (183, 1),   // ·
            (184, 2),   // ¸
            (187, 5),   // »
            (188, 6),   // ¼
            (189, 6),   // ½
            (190, 7),   // ¾
            (191, 5),   // ¿
            (306, 4),   // Ĳ
            (307, 2),   // ĳ
            (352, 5),   // Š
            (353, 4),   // š
            (381, 5),   // Ž
            (382, 4),   // ž
            (710, 3),   // ˆ
            (711, 3),   // ˇ
            (728, 4),   // ˘
            (729, 1),   // ˙
            (730, 2),   // ˚
            (731, 2),   // ˛
            (732, 3),   // ˜
            (733, 4),   // ˝
            (3647, 5),  // ฿
            (8211, 6),  // –
            (8212, 6),  // —
            (8216, 1),  // '
            (8217, 1),  // '
            (8218, 1),  // ‚
            (8220, 3),  // "
            (8221, 3),  // "
            (8222, 3),  // „
            (8224, 5),  // †
            (8225, 5),  // ‡
            (8226, 3),  // •
            (8230, 4),  // …
            (8240, 7),  // ‰
            (8249, 3),  // ‹
            (8250, 3),  // ›
            (8260, 4),  // ⁄
            (8304, 3),  // ⁰
            (8305, 6),  // ⁱ
            (8308, 3), (8309, 3), (8310, 3), (8311, 3), (8312, 3), (8313, 3),  // ⁴-⁹
            (8320, 3), (8321, 2), (8322, 3), (8323, 3), (8324, 3),  // ₀-₄
            (8325, 3), (8326, 3), (8327, 3), (8328, 3), (8329, 3),  // ₅-₉
            (8364, 7),  // €
            (8383, 5),  // ₿
            (8482, 6),  // ™
            (8539, 6), (8540, 7), (8541, 7), (8542, 6),  // ⅛ ⅜ ⅝ ⅞
            (8592, 7),  // ←
            (8593, 6),  // ↑
            (8594, 7),  // →
            (8595, 6),  // ↓
            (8596, 8),  // ↔
            (8597, 6),  // ↕
            (8598, 6), (8599, 6), (8600, 6), (8601, 6),  // ↖ ↗ ↘ ↙
            (8706, 5),  // ∂
            (8719, 5),  // ∏
            (8721, 5),  // ∑
            (8722, 4),  // −
            (8730, 5),  // √
            (8734, 8),  // ∞
            (8747, 5),  // ∫
            (8776, 5),  // ≈
            (8800, 4),  // ≠
            (8804, 4),  // ≤
            (8805, 4),  // ≥
            (9674, 5),  // ◊
            (9676, 9),  // ◌
        ]
        
        for (cp, w) in specialWidths {
            widths[cp] = w
        }
        
        return widths
    }
    
    /// Get default glyph widths
    static func getDefaultGlyphWidths() -> [Int: Int] {
        return buildDefaultGlyphWidths()
    }
}
