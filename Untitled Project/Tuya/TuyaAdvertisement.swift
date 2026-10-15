import Foundation
import CoreBluetooth

struct TuyaAdvertisement {
    var isBound: Bool = false
    var protocolVersion: Int = TuyaBLE.defaultProtocolVersion
    var productID: String?
    var productIDIsPlain: Bool = false
    var uuid: String?
    var manufacturerRaw: Data?
    var serviceDataRaw: Data?
    var hasTuyaSignature: Bool = false
}

enum TuyaAdvertisementParser {
    static func parse(manufacturerData: Data?, serviceData: [CBUUID: Data]?) -> TuyaAdvertisement {
        var adv = TuyaAdvertisement()

        let servicePayload = serviceData?[TuyaBLE.serviceUUID]
        adv.serviceDataRaw = servicePayload
        var productID: String?

        if let payload = servicePayload, payload.count > 1 {
            adv.hasTuyaSignature = true
            let type = payload[payload.startIndex]
            let body = payload.dropFirst()
            switch type {
            case 0:
                let pid = String(data: Data(body), encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                if let pid, !pid.isEmpty {
                    productID = pid
                    adv.productIDIsPlain = true
                }
            case 1:
                adv.productIDIsPlain = false
            default:
                break
            }
        }
        // Firmware com serviço legado FD50: [frameCtrl(2)][tipo][len][product_id]
        if productID == nil, let legacy = serviceData?[TuyaBLE.legacyServiceUUID], legacy.count > 4 {
            adv.hasTuyaSignature = true
            adv.serviceDataRaw = legacy
            let bytes = [UInt8](legacy)
            let length = Int(bytes[3])
            if bytes[2] == 0, 4 + length <= bytes.count,
               let pid = String(bytes: bytes[4..<(4 + length)], encoding: .utf8) {
                productID = pid
                adv.productIDIsPlain = true
            }
        }
        adv.productID = productID

        if let full = manufacturerData, full.count >= 2 {
            let company = UInt16(full[full.startIndex]) | (UInt16(full[full.startIndex + 1]) << 8)
            if company == TuyaBLE.manufacturerID {
                adv.hasTuyaSignature = true
                let payload = Data(full.dropFirst(2))
                adv.manufacturerRaw = payload
                if payload.count > 6 {
                    let bytes = [UInt8](payload)
                    adv.isBound = (bytes[0] & 0x80) != 0
                    adv.protocolVersion = Int(bytes[1])
                    if bytes.count >= 22, let productID {
                        let key = TuyaCrypto.md5(Data(productID.utf8))
                        let block = Data(bytes[6..<22])
                        let padded = TuyaCrypto.zeroPad(block)
                        if let decrypted = TuyaCrypto.aesCBC(padded, key: key, iv: key, encrypt: false) {
                            let raw = decrypted.prefix(16)
                            let text = String(data: raw, encoding: .utf8)?
                                .trimmingCharacters(in: .controlCharacters)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                            if let text, !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber }) {
                                adv.uuid = text
                            }
                        }
                    }
                }
            }
        }

        return adv
    }

    static func looksLikeTuya(name: String?, adv: TuyaAdvertisement) -> Bool {
        if adv.hasTuyaSignature { return true }
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("ty") || name.contains("amg") || name.contains("tuya") || name.contains("panda")
    }
}
