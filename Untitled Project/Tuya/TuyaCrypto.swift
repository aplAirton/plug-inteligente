import Foundation
import CommonCrypto
import CryptoKit

enum TuyaCrypto {
    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func zeroPad(_ data: Data, block: Int = 16) -> Data {
        var out = data
        while out.count % block != 0 {
            out.append(0)
        }
        return out
    }

    static func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, data.count % 16 == 0 else {
            return nil
        }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress,
                            data.count,
                            outPtr.baseAddress,
                            outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    static func packVarint(_ value: Int) -> Data {
        var out = Data()
        var v = value
        while true {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
            }
            out.append(byte)
            if v == 0 { break }
        }
        return out
    }

    static func unpackVarint(_ data: Data, at index: inout Int) -> Int? {
        var result = 0
        var offset = 0
        while offset < 5 {
            let pos = index + offset
            guard pos < data.count else { return nil }
            let byte = data[data.startIndex + pos]
            result |= Int(byte & 0x7F) << (offset * 7)
            offset += 1
            if byte & 0x80 == 0 { break }
        }
        guard offset <= 4 else { return nil }
        index += offset
        return result
    }

    static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func randomLoginKey() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
