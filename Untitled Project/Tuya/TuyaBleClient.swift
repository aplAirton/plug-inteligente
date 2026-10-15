import Foundation
import CoreBluetooth

enum TuyaClientState: Equatable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case bluetoothUnknown
    case ready
    case scanning
    case connecting(String)
    case discovering
    case readyForHandshake
    case handshaking
    case paired
    case disconnected

    var label: String {
        switch self {
        case .bluetoothOff: return "Bluetooth desligado"
        case .bluetoothUnauthorized: return "Bluetooth não autorizado"
        case .bluetoothUnsupported: return "Bluetooth indisponível"
        case .bluetoothUnknown: return "Bluetooth iniciando"
        case .ready: return "Pronto"
        case .scanning: return "Escaneando"
        case .connecting(let name): return "Conectando a \(name)"
        case .discovering: return "Descobrindo serviços"
        case .readyForHandshake: return "Conectado (handshake pendente)"
        case .handshaking: return "Handshake"
        case .paired: return "Pareado e controlando"
        case .disconnected: return "Desconectado"
        }
    }

    var isConnected: Bool {
        switch self {
        case .readyForHandshake, .handshaking, .paired: return true
        default: return false
        }
    }
}

final class TuyaBleClient: NSObject {
    var onStateChange: ((TuyaClientState) -> Void)?
    var onLog: ((LogEntry) -> Void)?
    var onDevicesChanged: (() -> Void)?
    var onDataPoints: (([RawDP], Date) -> Void)?

    private(set) var state: TuyaClientState = .bluetoothUnknown {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private(set) var devices: [DiscoveredDevice] = []
    private(set) var handshake: HandshakeInfo?

    private var central: CBCentralManager!
    private var target: DiscoveredDevice?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var protocolVersion = TuyaBLE.defaultProtocolVersion
    private var sequence: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<TuyaMessage?, Never>] = [:]
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var reassembler = TuyaPacketReassembler()

    private var writeQueue: [Data] = []

    private var inboundKeys: [UInt8: Data] = [:]
    private var sessionKey: Data?
    private var sessionFlag: UInt8 = TuyaSecurityFlag.sessionKey.rawValue
    private var loginKey6: Data?
    private var scheme: CryptoScheme = .classic
    private var scanAllDevices = false
    private var pendingServiceScans = 0
    private var dpSequence: UInt32 = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var activeDeviceName: String? {
        target?.name
    }

    func startScan(allDevices: Bool) {
        guard central.state == .poweredOn else {
            log(.error("Bluetooth não está ligado/autorizado"))
            return
        }
        scanAllDevices = allDevices
        devices.removeAll()
        onDevicesChanged?()
        central.scanForPeripherals(
            withServices: allDevices ? nil : [TuyaBLE.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        state = .scanning
        log(.info("Escaneando dispositivos Tuya...", allDevices ? "modo: todos os BLE" : "filtro: serviço 0xA201"))
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning {
            state = .ready
        }
    }

    func connect(to device: DiscoveredDevice) async -> Bool {
        central.stopScan()
        target = device
        peripheral = device.peripheral
        writeCharacteristic = nil
        notifyCharacteristic = nil
        device.peripheral.delegate = self
        state = .connecting(device.name)
        log(.info("Conectando a \(device.name)", device.peripheralID.uuidString))
        central.connect(device.peripheral, options: nil)
        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connectContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if let pendingContinuation = self.connectContinuation {
                    self.connectContinuation = nil
                    pendingContinuation.resume(returning: false)
                    self.log(.error("Timeout ao conectar"))
                }
            }
        }
        if !connected { return false }
        return true
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        cleanupSession()
        state = .disconnected
    }

    private func cleanupSession() {
        sessionKey = nil
        loginKey6 = nil
        handshake = nil
        inboundKeys.removeAll()
        reassembler.reset()
        writeQueue.removeAll()
        sequence = 1
        resumeAllPending(with: nil)
    }

    private func resumeAllPending(with message: TuyaMessage?) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: message)
        }
    }

    private func enqueueWrite(_ data: Data) {
        guard let peripheral, let characteristic = writeCharacteristic else {
            log(.error("Sem característica de escrita"))
            return
        }
        if writeQueue.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            writeQueue.append(data)
        }
    }

    private func flushWriteQueue() {
        guard let peripheral, let characteristic = writeCharacteristic else {
            writeQueue.removeAll()
            return
        }
        while !writeQueue.isEmpty, peripheral.canSendWriteWithoutResponse {
            let data = writeQueue.removeFirst()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    @discardableResult
    private func send(
        code: TuyaCommand,
        data: Data,
        key: Data,
        flag: UInt8,
        responseTo: UInt32 = 0,
        wait: Bool,
        timeout: TimeInterval = 8
    ) async -> TuyaMessage? {
        guard let peripheral, writeCharacteristic != nil, peripheral.state == .connected else {
            log(.error("Envio falhou: não conectado"))
            return nil
        }
        let sn = nextSequence()
        guard let encrypted = TuyaFrameCodec.encrypt(
            seq: sn,
            responseTo: responseTo,
            code: code,
            data: data,
            key: key,
            securityFlag: flag,
            protocolVersion: protocolVersion
        ) else {
            log(.error("Falha ao cifrar pacote \(code.label)"))
            return nil
        }
        let packets = TuyaFrameCodec.packetize(encrypted, protocolVersion: protocolVersion)
        if responseTo == 0 {
            log(.tx("#\(sn) \(code.label) (flag 0x\(String(format: "%02x", flag))) data=\(data.count)B", bytes: encrypted))
        } else {
            log(.tx("#\(sn) \(code.label) RESP→#\(responseTo)", bytes: encrypted))
        }
        for packet in packets {
            enqueueWrite(packet)
        }
        guard wait else { return nil }
        return await awaitMessage(sn: sn, timeout: timeout)
    }

    private func sendResponse(code: TuyaCommand, data: Data, responseTo: UInt32) async {
        guard let sessionKey else {
            log(.error("Sem session key para responder \(code.label)"))
            return
        }
        await send(code: code, data: data, key: sessionKey, flag: sessionFlag, responseTo: responseTo, wait: false)
    }

    private func nextSequence() -> UInt32 {
        let sn = sequence
        sequence += 1
        return sn
    }

    private func awaitMessage(sn: UInt32, timeout: TimeInterval) async -> TuyaMessage? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<TuyaMessage?, Never>) in
            pending[sn] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let entry = self.pending.removeValue(forKey: sn) {
                    entry.resume(returning: nil)
                }
            }
        }
    }

    private func log(_ entry: LogEntry) {
        print("[TUYA] \(entry.timeString) \(entry.title) \(entry.detail ?? "") \(entry.bytes?.hexString ?? "")")
        onLog?(entry)
    }

    func runHandshake(candidates: [KeyCandidate]) async -> HandshakeInfo? {
        guard state.isConnected else {
            log(.error("Handshake: não conectado"))
            return nil
        }
        state = .handshaking
        for candidate in candidates {
            if peripheral?.state != .connected, let target {
                log(.info("Dispositivo desconectou após chave errada — reconectando"))
                guard await connect(to: target) else { break }
                state = .handshaking
            }
            log(.info("Tentando chave: \(candidate.label)", "flag 0x\(String(format: "%02x", candidate.flag4)) floodKey=\(candidate.key4.hexString)"))
            sessionKey = nil
            inboundKeys = [candidate.flag4: candidate.key4]
            scheme = candidate.scheme
            loginKey6 = candidate.pairKey6

            let response = await send(
                code: .deviceInfo,
                data: Data(),
                key: candidate.key4,
                flag: candidate.flag4,
                wait: true,
                timeout: 6
            )

            guard let response, response.command == .deviceInfo, response.data.count >= 46 else {
                continue
            }

            let info = parseHandshakeResponse(response, candidate: candidate)
            let sessionKey = candidate.makeSessionKey(info.srand)
            self.sessionKey = sessionKey
            self.sessionFlag = candidate.flag5
            inboundKeys[candidate.flag5] = sessionKey
            protocolVersion = info.protocolVersionMajor
            handshake = info
            state = .paired
            log(.success(
                "Handshake OK com \(candidate.label)",
                "device=\(info.deviceVersion) proto=\(info.protocolVersion) hw=\(info.hardwareVersion) bound=\(info.isBound) srand=\(info.srand.hexString) session=\(sessionKey.hexString)"
            ))
            return info
        }
        state = peripheral?.state == .connected ? .readyForHandshake : .disconnected
        log(.error("Nenhuma chave funcionou", "O dispositivo não respondeu a nenhum candidato de login key"))
        return nil
    }

    private func parseHandshakeResponse(_ response: TuyaMessage, candidate: KeyCandidate) -> HandshakeInfo {
        let data = response.data
        var info = HandshakeInfo()
        info.deviceVersion = "\(data[data.startIndex]).\(data[data.startIndex + 1])"
        info.protocolVersion = "\(data[data.startIndex + 2]).\(data[data.startIndex + 3])"
        info.protocolVersionMajor = Int(data[data.startIndex + 2])
        info.hardwareVersion = "\(data[data.startIndex + 12]).\(data[data.startIndex + 13])"
        info.isBound = data[data.startIndex + 5] != 0
        info.srand = data.subdata(in: 6..<12)
        info.authKey = data.subdata(in: 14..<46)
        info.candidateLabel = candidate.label
        info.scheme = candidate.scheme
        return info
    }

    @discardableResult
    func pair(uuid: String, loginKey6: Data, virtualID: String?) async -> UInt8? {
        guard let sessionKey else {
            log(.error("Pareamento: sem session key (rode o handshake primeiro)"))
            return nil
        }
        let payload = TuyaPayloadBuilder.pairPayload(uuid: uuid, loginKey: loginKey6, virtualID: virtualID)
        log(.info("Enviando PAIR", "uuid=\(uuid) key6=\(loginKey6.hexString) vid=\(virtualID ?? "-") payload=\(payload.hexString)"))
        let response = await send(
            code: .pair,
            data: payload,
            key: sessionKey,
            flag: sessionFlag,
            wait: true,
            timeout: 8
        )
        guard let response, response.command == .pair, let result = response.data.first else {
            log(.error("PAIR sem resposta válida"))
            return nil
        }
        switch result {
        case 0:
            state = .paired
            log(.success("PAIR aceito", "Dispositivo vinculado a este app"))
        case 2:
            state = .paired
            log(.success("PAIR: dispositivo já pareado", "Tratado como sucesso"))
        default:
            log(.error("PAIR recusado", "código \(result) (1 = device id não confere)"))
        }
        return result
    }

    func pairPayloadPreview(uuid: String, loginKey6: Data, virtualID: String?) -> Data {
        TuyaPayloadBuilder.pairPayload(uuid: uuid, loginKey: loginKey6, virtualID: virtualID)
    }

    @discardableResult
    func queryStatus() async -> Bool {
        guard let sessionKey else {
            log(.error("Consulta: sem session key"))
            return false
        }
        let response = await send(
            code: .deviceStatus,
            data: Data(),
            key: sessionKey,
            flag: sessionFlag,
            wait: true,
            timeout: 6
        )
        if let response {
            log(.info("Status respondeu", "ack=\(response.responseTo) data=\(response.data.hexString)"))
            return true
        }
        log(.error("Consulta de status sem resposta"))
        return false
    }

    @discardableResult
    func sendDataPoints(_ encoded: Data) async -> Bool {
        guard let sessionKey else {
            log(.error("Envio de DP: sem session key"))
            return false
        }
        var code = TuyaCommand.sendDataPoints
        var payload = encoded
        if protocolVersion >= 4 {
            // v4: dpSeq(4) + flags(1) + dps com comprimento em 2 bytes
            code = .sendDataPointsV4
            dpSequence &+= 1
            payload = Data()
            payload.appendBE(dpSequence)
            payload.append(0)
            payload.append(TuyaDataPointCodec.widenLengths(encoded))
        }
        let response = await send(
            code: code,
            data: payload,
            key: sessionKey,
            flag: sessionFlag,
            wait: true,
            timeout: 6
        )
        if let response {
            if let result = response.data.first, result != 0 {
                log(.error("DP recusado pelo dispositivo", "código \(result)"))
                return false
            }
            return true
        }
        log(.error("DP sem resposta"))
        return false
    }

    func unbind() async {
        guard let sessionKey else { return }
        let response = await send(code: .unbind, data: Data(), key: sessionKey, flag: sessionFlag, wait: true, timeout: 8)
        if let response, let result = response.data.first, result == 0 {
            log(.success("UNBIND ok", "Dispositivo desvinculado"))
        } else {
            log(.error("UNBIND sem confirmação"))
        }
    }

    func deviceReset() {
        guard let sessionKey else { return }
        Task { @MainActor in
            await send(code: .deviceReset, data: Data(), key: sessionKey, flag: sessionFlag, wait: false)
            log(.info("DEVICE_RESET enviado"))
        }
    }

    private func handlePayload(_ payload: Data) {
        guard payload.count > 17 else {
            log(.error("Payload muito curto", payload.hexString))
            return
        }
        let flag = payload[payload.startIndex]
        guard let key = inboundKeys[flag] else {
            log(.error("Sem chave para flag 0x\(String(format: "%02x", flag))", "recebido: \(payload.hexString)"))
            return
        }
        guard let message = TuyaFrameCodec.decrypt(payload: payload, key: key) else {
            log(.error("Não decifrou (chave errada ou CRC inválido)", payload.hexString))
            resumeAllPending(with: nil)
            return
        }
        if message.responseTo != 0 {
            log(.rx("#\(message.seq) \(message.commandLabel) ack=#\(message.responseTo) data=\(message.data.hexString)", bytes: message.data))
            if let continuation = pending.removeValue(forKey: message.responseTo) {
                continuation.resume(returning: message)
            } else {
                log(.info("Resposta sem solicitação pendente", "ack=#\(message.responseTo)"))
            }
        } else {
            log(.rx("#\(message.seq) \(message.commandLabel) data=\(message.data.hexString)", bytes: message.data))
            handleDeviceMessage(message)
        }
    }

    private func handleDeviceMessage(_ message: TuyaMessage) {
        switch message.command {
        case .receiveDP:
            let dps = TuyaDataPointCodec.parse(message.data)
            if !dps.isEmpty {
                onDataPoints?(dps, Date())
                log(.info("DPs recebidos", dps.map { "\($0.dpID)=\($0.decoded)" }.joined(separator: ", ")))
            }
            Task { @MainActor in
                await self.sendResponse(code: .receiveDP, data: Data(), responseTo: message.seq)
            }

        case .receiveSignDP:
            guard message.data.count >= 3 else { return }
            let dpSeq = message.data.beUInt16(at: 0) ?? 0
            let flags = message.data[message.data.startIndex + 2]
            var dps = TuyaDataPointCodec.parse(message.data, start: 3)
            if dps.isEmpty { dps = TuyaDataPointCodec.parse(message.data, start: 2) }
            if !dps.isEmpty {
                onDataPoints?(dps, Date())
                log(.info("DPs assinados", dps.map { "\($0.dpID)=\($0.decoded)" }.joined(separator: ", ")))
            }
            var ack = Data()
            ack.appendBE(dpSeq)
            ack.append(flags)
            ack.append(0)
            Task { @MainActor in
                await self.sendResponse(code: .receiveSignDP, data: ack, responseTo: message.seq)
            }

        case .receiveTimeDP:
            let position = Self.skipTimestamp(message.data)
            let dps = TuyaDataPointCodec.parse(message.data, start: position)
            if !dps.isEmpty {
                onDataPoints?(dps, Date())
                log(.info("DPs com tempo", dps.map { "\($0.dpID)=\($0.decoded)" }.joined(separator: ", ")))
            }
            Task { @MainActor in
                await self.sendResponse(code: .receiveTimeDP, data: Data(), responseTo: message.seq)
            }

        case .receiveSignTimeDP:
            guard message.data.count >= 4 else { return }
            let dpSeq = message.data.beUInt16(at: 0) ?? 0
            let flags = message.data[message.data.startIndex + 2]
            let position = Self.skipTimestamp(message.data, start: 3)
            let dps = TuyaDataPointCodec.parse(message.data, start: position)
            if !dps.isEmpty {
                onDataPoints?(dps, Date())
                log(.info("DPs assinados com tempo", dps.map { "\($0.dpID)=\($0.decoded)" }.joined(separator: ", ")))
            }
            var ack = Data()
            ack.appendBE(dpSeq)
            ack.append(flags)
            ack.append(0)
            Task { @MainActor in
                await self.sendResponse(code: .receiveSignTimeDP, data: ack, responseTo: message.seq)
            }

        case .receiveDPv4, .receiveTimeDPv4:
            // dpSeq(4) + flags(1) [+ timestamp] + dps(id,tipo,len16)
            let start = message.command == .receiveTimeDPv4 ? Self.skipTimestamp(message.data, start: 5) : 5
            let dps = TuyaDataPointCodec.parse(message.data, start: start, lengthBytes: 2)
            if !dps.isEmpty {
                onDataPoints?(dps, Date())
                log(.info("DPs v4", dps.map { "\($0.dpID)=\($0.decoded)" }.joined(separator: ", ")))
            }
            var ack = Data(message.data.prefix(5))
            ack.append(0)
            Task { @MainActor in
                await self.sendResponse(code: message.command!, data: ack, responseTo: message.seq)
            }

        case .timeRequest1:
            log(.info("Dispositivo pediu a hora (v1) — respondendo"))
            Task { @MainActor in
                await self.sendResponse(code: .timeRequest1, data: TuyaPayloadBuilder.time1Response(), responseTo: message.seq)
            }

        case .timeRequest2:
            log(.info("Dispositivo pediu a hora (v2) — respondendo"))
            Task { @MainActor in
                await self.sendResponse(code: .timeRequest2, data: TuyaPayloadBuilder.time2Response(), responseTo: message.seq)
            }

        default:
            log(.info("Comando não tratado: \(message.commandLabel)", message.data.hexString))
        }
    }

    private static func skipTimestamp(_ data: Data, start: Int = 0) -> Int {
        guard start < data.count else { return start }
        let type = data[data.startIndex + start]
        switch type {
        case 0:
            return min(start + 1 + 13, data.count)
        case 1:
            return min(start + 1 + 4, data.count)
        default:
            return start + 1
        }
    }
}

extension TuyaBleClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .bluetoothUnknown || state == .bluetoothOff || state == .bluetoothUnsupported || state == .bluetoothUnauthorized {
                state = .ready
            }
        case .poweredOff:
            state = .bluetoothOff
            cleanupSession()
        case .unauthorized:
            state = .bluetoothUnauthorized
        case .unsupported:
            state = .bluetoothUnsupported
        default:
            state = .bluetoothUnknown
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let adv = TuyaAdvertisementParser.parse(manufacturerData: manufacturer, serviceData: serviceData)
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Sem nome"

        if scanAllDevices && !TuyaAdvertisementParser.looksLikeTuya(name: name, adv: adv) {
            return
        }

        if !devices.contains(where: { $0.peripheralID == peripheral.identifier }) {
            let svc = serviceData?.map { "\($0.key.uuidString)=\($0.value.hexString)" }.joined(separator: ",") ?? "-"
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? "-"
            log(.info("ADV \(name)", "mfr=\(manufacturer?.hexString ?? "-") svcData=\(svc) svcUUIDs=\(uuids)"))
        }
        let device = DiscoveredDevice(
            peripheral: peripheral,
            peripheralID: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            isBound: adv.isBound,
            protocolVersion: adv.protocolVersion,
            productID: adv.productID,
            uuid: adv.uuid,
            manufacturerRaw: adv.manufacturerRaw,
            serviceDataRaw: adv.serviceDataRaw,
            lastSeen: Date()
        )

        if let index = devices.firstIndex(where: { $0.peripheralID == device.peripheralID }) {
            if devices[index] != device {
                devices[index] = device
                onDevicesChanged?()
            }
        } else {
            devices.append(device)
            onDevicesChanged?()
            log(.info(
                "Encontrado: \(name)",
                "rssi=\(RSSI.intValue) bound=\(adv.isBound) proto=\(adv.protocolVersion) pid=\(adv.productID ?? "-") uuid=\(adv.uuid ?? "-")"
            ))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log(.success("Conectado a \(peripheral.name ?? "dispositivo")"))
        state = .discovering
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log(.error("Falha ao conectar", error?.localizedDescription))
        resolveConnect(false)
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log(.info("Desconectado", error?.localizedDescription))
        resolveConnect(false)
        cleanupSession()
        state = .disconnected
    }

    private func resolveConnect(_ result: Bool) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(returning: result)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log(.error("Erro ao descobrir serviços", error.localizedDescription))
            return
        }
        let services = peripheral.services ?? []
        log(.info("Serviços encontrados", services.map { $0.uuid.uuidString }.joined(separator: ", ")))
        // As características 2B10/2B11 costumam ficar no serviço 0x1910, não no 0xA201
        // (que só aparece no anúncio). Varre todos os serviços.
        guard !services.isEmpty else {
            log(.error("Nenhum serviço GATT"))
            disconnect()
            return
        }
        pendingServiceScans = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log(.error("Erro ao descobrir características", error.localizedDescription))
            return
        }
        let characteristics = service.characteristics ?? []
        log(.info("Características de \(service.uuid.uuidString)", characteristics.map { "\($0.uuid.uuidString) [\(describe(properties: $0.properties))]" }.joined(separator: "; ")))
        let notifyCandidates = [TuyaBLE.notifyUUID, TuyaBLE.legacyNotifyUUID]
        let writeCandidates = [TuyaBLE.writeUUID, TuyaBLE.legacyWriteUUID]
        if notifyCharacteristic == nil {
            notifyCharacteristic = characteristics.first(where: { notifyCandidates.contains($0.uuid) })
        }
        if writeCharacteristic == nil {
            writeCharacteristic = characteristics.first(where: { writeCandidates.contains($0.uuid) })
        }
        pendingServiceScans -= 1
        guard pendingServiceScans <= 0 else { return }

        guard let notifyCharacteristic else {
            log(.error("Característica 2B10 (notify) não encontrada"))
            disconnect()
            return
        }
        guard writeCharacteristic != nil else {
            log(.error("Característica 2B11 (write) não encontrada"))
            disconnect()
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log(.error("Falha ao ativar notificações", error.localizedDescription))
            resolveConnect(false)
            return
        }
        if characteristic.isNotifying {
            log(.success("Notificações ativas — pronto para handshake"))
            state = .readyForHandshake
            resolveConnect(true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log(.error("Erro de leitura", error.localizedDescription))
            return
        }
        guard characteristic == notifyCharacteristic, let value = characteristic.value else { return }
        if let payload = reassembler.feed(value) {
            handlePayload(payload)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWriteQueue()
    }

    private func describe(properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

extension TuyaBleClient: CBPeripheralDelegate {}
