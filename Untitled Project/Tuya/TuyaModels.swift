import Foundation
import CoreBluetooth

enum TuyaBLE {
    static let serviceUUID = CBUUID(string: "0000A201-0000-1000-8000-00805F9B34FB")
    static let notifyUUID = CBUUID(string: "00002B10-0000-1000-8000-00805F9B34FB")
    static let writeUUID = CBUUID(string: "00002B11-0000-1000-8000-00805F9B34FB")

    static let legacyServiceUUID = CBUUID(string: "0000FD50-0000-1000-8000-00805F9B34FB")
    static let legacyNotifyUUID = CBUUID(string: "00000002-0000-1001-8001-00805F9B07D0")
    static let legacyWriteUUID = CBUUID(string: "00000001-0000-1001-8001-00805F9B07D0")

    static let manufacturerID: UInt16 = 0x07D0
    static let gattChunkSize = 20
    static let defaultProtocolVersion = 2
}

enum TuyaCommand: UInt16 {
    case deviceInfo = 0x0000
    case pair = 0x0001
    case sendDataPoints = 0x0002
    case deviceStatus = 0x0003
    case loginKey = 0x0004
    case unbind = 0x0005
    case deviceReset = 0x0006
    case sendDataPointsV4 = 0x0027
    case receiveDP = 0x8001
    case receiveTimeDP = 0x8003
    case receiveSignDP = 0x8004
    case receiveSignTimeDP = 0x8005
    case receiveDPv4 = 0x8006
    case receiveTimeDPv4 = 0x8007
    case timeRequest1 = 0x8011
    case timeRequest2 = 0x8012

    var label: String {
        switch self {
        case .deviceInfo: return "DEVICE_INFO"
        case .pair: return "PAIR"
        case .sendDataPoints: return "SEND_DPS"
        case .deviceStatus: return "STATUS_QUERY"
        case .loginKey: return "LOGIN_KEY"
        case .unbind: return "UNBIND"
        case .deviceReset: return "DEVICE_RESET"
        case .sendDataPointsV4: return "SEND_DPS_V4"
        case .receiveDP: return "DP_REPORT"
        case .receiveTimeDP: return "DP_REPORT_TIME"
        case .receiveSignDP: return "DP_REPORT_SIGNED"
        case .receiveSignTimeDP: return "DP_REPORT_SIGNED_TIME"
        case .receiveDPv4: return "DP_REPORT_V4"
        case .receiveTimeDPv4: return "DP_REPORT_TIME_V4"
        case .timeRequest1: return "TIME_REQ_1"
        case .timeRequest2: return "TIME_REQ_2"
        }
    }

    var isReport: Bool {
        switch self {
        case .receiveDP, .receiveTimeDP, .receiveSignDP, .receiveSignTimeDP, .receiveDPv4, .receiveTimeDPv4:
            return true
        default:
            return false
        }
    }
}

enum TuyaSecurityFlag: UInt8 {
    case authKey = 0x01
    case loginKey = 0x04
    case sessionKey = 0x05
    case loginKeyV2 = 0x0E
    case sessionKeyV2 = 0x0F

    var label: String {
        switch self {
        case .authKey: return "auth_key"
        case .loginKey: return "login_key"
        case .sessionKey: return "session_key"
        case .loginKeyV2: return "login_key v2"
        case .sessionKeyV2: return "session_key v2"
        }
    }
}

enum TuyaDPType: Int, CaseIterable {
    case raw = 0
    case bool = 1
    case value = 2
    case string = 3
    case enumValue = 4
    case bitmap = 5

    var label: String {
        switch self {
        case .raw: return "raw"
        case .bool: return "bool"
        case .value: return "int"
        case .string: return "str"
        case .enumValue: return "enum"
        case .bitmap: return "bitmap"
        }
    }
}

struct RawDP: Identifiable, Hashable {
    let dpID: UInt8
    let type: TuyaDPType
    let raw: Data
    let number: Int64?
    let boolean: Bool?
    let text: String?

    var id: UInt8 { dpID }

    var rawHex: String { raw.hexString }

    var decoded: String {
        switch type {
        case .bool:
            return (boolean ?? false) ? "ligado" : "desligado"
        case .value, .enumValue:
            return number.map(String.init) ?? rawHex
        case .string:
            return text ?? ""
        case .raw, .bitmap:
            return rawHex
        }
    }

    static func == (lhs: RawDP, rhs: RawDP) -> Bool {
        lhs.dpID == rhs.dpID && lhs.type == rhs.type && lhs.raw == rhs.raw
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(dpID)
        hasher.combine(raw)
    }
}

struct HandshakeInfo: Equatable {
    var deviceVersion: String = ""
    var protocolVersion: String = ""
    var protocolVersionMajor: Int = 2
    var hardwareVersion: String = ""
    var isBound: Bool = false
    var srand: Data = Data()
    var authKey: Data = Data()
    var candidateLabel: String = ""
    var scheme: CryptoScheme = .classic
}

enum CryptoScheme: Equatable {
    case classic
    case v2(secKey: String)
}

struct KeyCandidate {
    let label: String
    let scheme: CryptoScheme
    let flag4: UInt8
    let flag5: UInt8
    let key4: Data
    let pairKey6: Data
    let makeSessionKey: (Data) -> Data
}

struct DiscoveredDevice: Identifiable, Equatable {
    let peripheral: CBPeripheral
    let peripheralID: UUID
    var name: String
    var rssi: Int
    var isBound: Bool
    var protocolVersion: Int
    var productID: String?
    var uuid: String?
    var manufacturerRaw: Data?
    var serviceDataRaw: Data?
    var lastSeen: Date

    var id: UUID { peripheralID }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.peripheralID == rhs.peripheralID && lhs.rssi == rhs.rssi && lhs.lastSeen == rhs.lastSeen
    }
}

struct LogEntry: Identifiable {
    enum Kind {
        case info
        case tx
        case rx
        case error
        case success
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let title: String
    let detail: String?
    let bytes: Data?

    var timeString: String {
        LogEntry.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ title: String, _ detail: String? = nil) -> LogEntry {
        LogEntry(kind: .info, title: title, detail: detail, bytes: nil)
    }

    static func success(_ title: String, _ detail: String? = nil) -> LogEntry {
        LogEntry(kind: .success, title: title, detail: detail, bytes: nil)
    }

    static func error(_ title: String, _ detail: String? = nil) -> LogEntry {
        LogEntry(kind: .error, title: title, detail: detail, bytes: nil)
    }

    static func tx(_ title: String, bytes: Data?) -> LogEntry {
        LogEntry(kind: .tx, title: title, detail: nil, bytes: bytes)
    }

    static func rx(_ title: String, bytes: Data?) -> LogEntry {
        LogEntry(kind: .rx, title: title, detail: nil, bytes: bytes)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var spacedHexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    var asciiString: String {
        String(data: self, encoding: .utf8) ?? hexString
    }

    func beUInt16(at index: Int) -> UInt16? {
        guard index + 2 <= count else { return nil }
        let start = startIndex + index
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }

    func beUInt32(at index: Int) -> UInt32? {
        guard index + 4 <= count else { return nil }
        let s = startIndex + index
        return UInt32(self[s]) << 24 | UInt32(self[s + 1]) << 16 | UInt32(self[s + 2]) << 8 | UInt32(self[s + 3])
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
