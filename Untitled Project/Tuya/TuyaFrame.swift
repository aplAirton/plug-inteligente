import Foundation

struct TuyaMessage {
    var seq: UInt32
    var responseTo: UInt32
    var code: UInt16
    var data: Data
    var securityFlag: UInt8

    var command: TuyaCommand? {
        TuyaCommand(rawValue: code)
    }

    var commandLabel: String {
        command?.label ?? String(format: "0x%04X", code)
    }
}

enum TuyaFrameCodec {
    static func encrypt(
        seq: UInt32,
        responseTo: UInt32,
        code: TuyaCommand,
        data: Data,
        key: Data,
        securityFlag: UInt8,
        protocolVersion: Int
    ) -> Data? {
        var raw = Data()
        raw.appendBE(seq)
        raw.appendBE(responseTo)
        raw.appendBE(code.rawValue)
        raw.appendBE(UInt16(data.count))
        raw.append(data)
        raw.appendBE(TuyaCrypto.crc16(raw))
        let padded = TuyaCrypto.zeroPad(raw)
        let iv = TuyaCrypto.randomData(count: 16)
        guard let ciphertext = TuyaCrypto.aesCBC(padded, key: key, iv: iv, encrypt: true) else {
            return nil
        }
        var out = Data()
        out.append(securityFlag)
        out.append(iv)
        out.append(ciphertext)
        return out
    }

    static func decrypt(payload: Data, key: Data) -> TuyaMessage? {
        guard payload.count > 17 else { return nil }
        let flag = payload[payload.startIndex]
        let iv = payload.subdata(in: 1..<17)
        let ciphertext = payload.subdata(in: 17..<payload.count)
        guard let raw = TuyaCrypto.aesCBC(ciphertext, key: key, iv: iv, encrypt: false) else {
            return nil
        }
        guard raw.count >= 14 else { return nil }
        guard let seq = raw.beUInt32(at: 0),
              let responseTo = raw.beUInt32(at: 4),
              let code = raw.beUInt16(at: 8),
              let length = raw.beUInt16(at: 10) else { return nil }
        let dataEnd = 12 + Int(length)
        guard dataEnd + 2 <= raw.count else { return nil }
        let computed = TuyaCrypto.crc16(raw.prefix(dataEnd))
        guard let received = raw.beUInt16(at: dataEnd), computed == received else {
            return nil
        }
        let data = raw.subdata(in: 12..<dataEnd)
        return TuyaMessage(seq: seq, responseTo: responseTo, code: code, data: data, securityFlag: flag)
    }

    static func packetize(_ encrypted: Data, protocolVersion: Int) -> [Data] {
        var packets: [Data] = []
        var packetNumber = 0
        var position = 0
        while position < encrypted.count {
            var packet = Data()
            packet.append(TuyaCrypto.packVarint(packetNumber))
            if packetNumber == 0 {
                packet.append(TuyaCrypto.packVarint(encrypted.count))
                packet.append(UInt8((protocolVersion & 0x0F) << 4))
            }
            let remaining = min(TuyaBLE.gattChunkSize - packet.count, encrypted.count - position)
            packet.append(encrypted.subdata(in: position..<(position + remaining)))
            packets.append(packet)
            position += remaining
            packetNumber += 1
        }
        return packets
    }
}

final class TuyaPacketReassembler {
    private var buffer = Data()
    private var expectedLength = 0
    var protocolVersion: Int?

    func reset() {
        buffer = Data()
        expectedLength = 0
    }

    func feed(_ packet: Data) -> Data? {
        var index = 0
        guard let packetNumber = TuyaCrypto.unpackVarint(packet, at: &index) else {
            reset()
            return nil
        }
        if packetNumber == 0 {
            buffer = Data()
            guard let total = TuyaCrypto.unpackVarint(packet, at: &index) else {
                reset()
                return nil
            }
            expectedLength = total
            guard index < packet.count else {
                reset()
                return nil
            }
            let versionByte = packet[packet.startIndex + index]
            protocolVersion = Int(versionByte >> 4)
            index += 1
        }
        buffer.append(packet.subdata(in: index..<packet.count))
        if buffer.count == expectedLength {
            let payload = buffer
            reset()
            return payload
        }
        if buffer.count > expectedLength {
            reset()
        }
        return nil
    }
}

enum TuyaDataPointCodec {
    static func widenLengths(_ v3: Data) -> Data {
        var out = Data()
        var i = v3.startIndex
        while i + 3 <= v3.endIndex {
            let len = Int(v3[i + 2])
            out.append(v3[i]); out.append(v3[i + 1]); out.appendBE(UInt16(len))
            out.append(v3[(i + 3)..<min(i + 3 + len, v3.endIndex)])
            i += 3 + len
        }
        return out
    }

    static func parse(_ data: Data, start: Int = 0, enforceLength: Bool = true, lengthBytes: Int = 1) -> [RawDP] {
        var result: [RawDP] = []
        var position = start
        let header = 2 + lengthBytes
        while position + header <= data.count {
            let base = data.startIndex + position
            let dpID = data[base]
            let typeValue = data[base + 1]
            let length = lengthBytes == 2 ? Int(data.beUInt16(at: position + 2) ?? 0) : Int(data[base + 2])
            guard let type = TuyaDPType(rawValue: Int(typeValue)) else {
                if enforceLength { break } else {
                    position += 1
                    continue
                }
            }
            let valueStart = position + header
            let valueEnd = valueStart + length
            if valueEnd > data.count {
                if enforceLength { break } else {
                    position += 1
                    continue
                }
            }
            let raw = data.subdata(in: valueStart..<valueEnd)
            result.append(decode(dpID: dpID, type: type, raw: raw))
            position = valueEnd
        }
        return result
    }

    static func decode(dpID: UInt8, type: TuyaDPType, raw: Data) -> RawDP {
        var number: Int64?
        var boolean: Bool?
        var text: String?
        switch type {
        case .bool:
            boolean = raw.first.map { $0 != 0 } ?? false
        case .value, .enumValue, .bitmap:
            var value: Int64 = 0
            for byte in raw {
                value = (value << 8) | Int64(byte)
            }
            if type == .value, raw.count == 4, value & 0x8000_0000 != 0 {
                value -= 0x1_0000_0000
            }
            number = value
        case .string:
            text = String(data: raw, encoding: .utf8)
        case .raw:
            break
        }
        return RawDP(dpID: dpID, type: type, raw: raw, number: number, boolean: boolean, text: text)
    }

    static func encode(dpID: UInt8, type: TuyaDPType, number: Int64?, boolean: Bool?, text: String?) -> Data {
        var value = Data()
        var length = 0
        switch type {
        case .bool:
            value = Data([(boolean ?? false) ? 1 : 0])
            length = 1
        case .value:
            let v = UInt32(truncatingIfNeeded: number ?? 0)
            value.append(UInt8((v >> 24) & 0xFF))
            value.append(UInt8((v >> 16) & 0xFF))
            value.append(UInt8((v >> 8) & 0xFF))
            value.append(UInt8(v & 0xFF))
            length = 4
        case .enumValue:
            let v = UInt8(truncatingIfNeeded: number ?? 0)
            value = Data([v])
            length = 1
        case .string:
            let data = Data((text ?? "").utf8)
            value = data
            length = data.count
        case .raw, .bitmap:
            value = Data()
            length = 0
        }
        var out = Data([dpID, UInt8(type.rawValue), UInt8(length)])
        out.append(value)
        return out
    }
}

enum TuyaPayloadBuilder {
    static func pairPayload(uuid: String, loginKey: Data, virtualID: String?) -> Data {
        var out = Data()
        var uuidBytes = Data(uuid.utf8)
        if uuidBytes.count > 16 { uuidBytes = uuidBytes.prefix(16) }
        while uuidBytes.count < 16 { uuidBytes.append(0) }
        out.append(uuidBytes)

        var key = loginKey
        if key.count > 6 { key = key.prefix(6) }
        while key.count < 6 { key.append(0) }
        out.append(key)

        var vid = Data((virtualID ?? "").utf8)
        if vid.count > 22 { vid = vid.prefix(22) }
        while vid.count < 22 { vid.append(0) }
        out.append(vid)

        return out
    }

    static func time1Response() -> Data {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        var out = Data(String(ms).utf8)
        out.appendBE(timezoneField())
        return out
    }

    static func time2Response() -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: Date())
        let swiftWeekday = components.weekday ?? 1
        let pythonWeekday = (swiftWeekday + 5) % 7
        var out = Data()
        out.append(UInt8((components.year ?? 2026) % 100))
        out.append(UInt8(components.month ?? 1))
        out.append(UInt8(components.day ?? 1))
        out.append(UInt8(components.hour ?? 0))
        out.append(UInt8(components.minute ?? 0))
        out.append(UInt8(components.second ?? 0))
        out.append(UInt8(pythonWeekday))
        out.appendBE(timezoneField())
        return out
    }

    private static func timezoneField() -> UInt16 {
        let field = Int16(TimeZone.current.secondsFromGMT() / 36)
        return UInt16(bitPattern: field)
    }
}
