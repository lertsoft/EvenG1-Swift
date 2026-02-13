import Foundation

// MARK: - Data Extensions

public extension Data {
    /// Convert data to hex string with optional separator
    func hexString(separator: String = " ") -> String {
        map { String(format: "%02X", $0) }.joined(separator: separator)
    }
    
    /// Initialize from hex string
    init?(hexString: String) {
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        guard cleanHex.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = cleanHex.startIndex
        
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let byteString = cleanHex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
    
    /// Split data into chunks of specified size
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { startIndex in
            let endIndex = Swift.min(startIndex + size, count)
            return subdata(in: startIndex..<endIndex)
        }
    }
    
    /// CRC32 calculation (matches MentraOS)
    var crc32: UInt32 {
        withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: UInt8.self)
            var crc: UInt32 = 0xFFFFFFFF
            
            for byte in buffer {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    if crc & 1 == 1 {
                        crc = (crc >> 1) ^ 0xEDB88320
                    } else {
                        crc >>= 1
                    }
                }
            }
            
            return ~crc
        }
    }
}

// MARK: - Array Extensions

public extension Array {
    /// Safe subscript access
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - String Extensions

public extension String {
    /// Convert hex string to Data
    var hexToData: Data? {
        Data(hexString: self)
    }
}
