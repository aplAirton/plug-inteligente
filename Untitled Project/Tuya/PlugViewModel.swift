import Foundation
import Observation

struct SavedDeviceCredentials: Codable, Identifiable {
    var id: UUID = UUID()
    var uuid: String
    var loginKey6Hex: String
    var virtualID: String?
    var deviceName: String
    var savedAt: Date = Date()
}

final class CredentialsStore {
    static let shared = CredentialsStore()

    private let defaultsKey = "tuya.saved.credentials.v1"
    private let customKeyDefaultsKey = "tuya.custom.pairkey.v1"

    var all: [SavedDeviceCredentials] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let list = try? JSONDecoder().decode([SavedDeviceCredentials].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    func find(uuid: String) -> SavedDeviceCredentials? {
        all.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    func upsert(uuid: String, loginKey6: Data, virtualID: String?, name: String) {
        var list = all
        if let index = list.firstIndex(where: { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }) {
            list[index].loginKey6Hex = loginKey6.hexString
            list[index].virtualID = virtualID
            list[index].deviceName = name
            list[index].savedAt = Date()
        } else {
            list.append(SavedDeviceCredentials(
                uuid: uuid,
                loginKey6Hex: loginKey6.hexString,
                virtualID: virtualID,
                deviceName: name
            ))
        }
        all = list
    }

    func remove(id: UUID) {
        all = all.filter { $0.id != id }
    }

    var customPairKey: String {
        get {
            let stored = UserDefaults.standard.string(forKey: customKeyDefaultsKey) ?? ""
            if stored.count == 6 { return stored }
            let generated = TuyaCrypto.randomLoginKey()
            UserDefaults.standard.set(generated, forKey: customKeyDefaultsKey)
            return generated
        }
        set {
            UserDefaults.standard.set(newValue, forKey: customKeyDefaultsKey)
        }
    }
}

struct DPRecord: Identifiable {
    let id = UUID()
    let date: Date
    let dpID: UInt8
    let typeLabel: String
    let rawHex: String
    let decoded: String
}

struct PlugMetrics {
    var isOn: Bool?
    var voltageV: Double?
    var currentA: Double?
    var powerW: Double?
    var energyKWh: Double?
}

@Observable
final class PlugViewModel {
    let client = TuyaBleClient()
    let lan = TuyaLanClient()
    static let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    let energy: EnergyStore = {
        let store = EnergyStore(inMemory: PlugViewModel.isDemo)
        if PlugViewModel.isDemo { store.seedDemo() }
        return store
    }()
    let tariff = TariffSettings()
    let cloud = CloudSync()
    let profiles = ProfileStore()
    let alerts = AlertSettings()
    static let shared = PlugViewModel()
    private var lastAlertEval = Date.distantPast
    private var offlineTask: Task<Void, Never>?
    private var cloudTimer: Timer?
    private var lastVoltageAlert = Date.distantPast
    var countdownEnd: Date?
    var countdownTotal: Double = 0
    private var reconnectTask: Task<Void, Never>?
    var lanState: TuyaLanClient.State = .idle
    var lanHost = UserDefaults.standard.string(forKey: "tuya.lan.host") ?? ""
    var lanLocalKey = UserDefaults.standard.string(forKey: "tuya.lan.key") ?? ""
    private var pollTimer: Timer?

    /// Há um canal de controle ativo (Wi-Fi ou BLE com sessão).
    var canControl: Bool { lanState == .ready || handshake != nil }
    var isLive: Bool { lanState == .ready || state.isConnected }
    let store = CredentialsStore.shared

    var logs: [LogEntry] = []
    var devices: [DiscoveredDevice] = []
    var latest: [UInt8: RawDP] = [:]
    var history: [DPRecord] = []
    var savedCredentials: [SavedDeviceCredentials] = []

    var state: TuyaClientState = .bluetoothUnknown
    var selectedDevice: DiscoveredDevice?
    var handshake: HandshakeInfo?
    var isBusy = false
    var busyLabel = ""

    var scanAll = false
    var autoPair = false
    var autoQueryAfterPair = true

    var localKey = ""
    var virtualID = ""
    var secKey = ""
    var uuidOverride = ""
    var customPairKey = ""

    var pairStatusText: String?

    init() {
        customPairKey = store.customPairKey
        reloadSaved()
        client.onLog = { [weak self] entry in
            guard let self else { return }
            self.logs.append(entry)
            if self.logs.count > 1500 {
                self.logs.removeFirst(self.logs.count - 1500)
            }
        }
        client.onStateChange = { [weak self] state in
            self?.state = state
        }
        client.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.devices = self.client.devices
        }
        client.onDataPoints = { [weak self] dps, date in
            self?.ingest(dps, at: date)
        }
        lan.onLog = client.onLog
        lan.onState = { [weak self] st in
            guard let self else { return }
            let previous = self.lanState
            self.lanState = st
            self.pollTimer?.invalidate()
            if st == .ready {
                self.offlineTask?.cancel()
                self.reconnectTask?.cancel()
                if previous != .ready { self.energy.log(.connected, "Wi-Fi local") }
            } else if case .failed = st {
                if previous == .ready {
                    self.energy.markGap()
                    self.energy.log(.disconnected)
                    self.offlineTask?.cancel()
                    self.offlineTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(600))
                        guard let self, !Task.isCancelled, self.lanState != .ready else { return }
                        AlertEngine.offline(model: self)
                    }
                }
                self.scheduleReconnect()
            }
            if st == .ready {
                self.pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    self?.lan.refreshMeasurements()
                }
            }
        }
        lan.onDPs = { [weak self] dps in
            self?.ingestLAN(dps)
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--lan"), i + 2 < args.count {
            lanHost = args[i + 1]
            lanLocalKey = args[i + 2]
        }
        if !lanHost.isEmpty && lanLocalKey.count == 16 {
            connectLAN()
        }
        if !Self.isDemo {
            syncCloud()
            cloudTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                self?.syncCloud()
            }
        }
    }

    private func reloadSaved() {
        savedCredentials = store.all
    }

    var effectiveUUID: String {
        let manual = uuidOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return selectedDevice?.uuid ?? ""
    }

    var displayUUID: String {
        if let uuid = selectedDevice?.uuid, !uuid.isEmpty { return uuid }
        if effectiveUUID.isEmpty { return "—" }
        return effectiveUUID
    }

    var connectionTitle: String {
        if let name = client.activeDeviceName, state.isConnected {
            return name
        }
        return state.label
    }

    func connectLAN() {
        lanHost = lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(lanHost, forKey: "tuya.lan.host")
        UserDefaults.standard.set(lanLocalKey, forKey: "tuya.lan.key")
        lan.connect(host: lanHost, localKey: lanLocalKey)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.lanHost.isEmpty, self.lanLocalKey.count == 16 else { return }
            if case .failed = self.lanState { self.lan.connect(host: self.lanHost, localKey: self.lanLocalKey) }
        }
    }

    func syncCloud(force: Bool = false) {
        Task {
            await cloud.sync(into: energy, force: force)
            AlertEngine.evaluate(model: self)
        }
    }

    /// Executado pelo iOS em segundo plano (BGAppRefresh): importa da nuvem e avalia os gatilhos.
    func backgroundRefresh() async {
        await cloud.sync(into: energy, force: true)
        AlertEngine.evaluate(model: self)
    }

    /// Apaga o que veio da nuvem e importa os 7 dias disponíveis novamente.
    func reimportCloud() {
        energy.clearCloud()
        cloud.resetCursor()
        syncCloud(force: true)
    }

    /// Reconecta ao voltar para o primeiro plano.
    func resume() {
        if !Self.isDemo { syncCloud() }
        guard !lanHost.isEmpty, lanLocalKey.count == 16 else { return }
        switch lanState {
        case .idle, .failed: connectLAN()
        default: lan.query()
        }
    }

    func suspend() {
        energy.markGap()
    }

    /// Envia um DP arbitrário (Wi-Fi). Retorna false sem canal.
    @discardableResult
    func setDP(_ id: Int, _ value: Any) -> Bool {
        guard lanState == .ready else { return false }
        lan.setDPs([String(id): value])
        return true
    }

    func setCountdown(_ seconds: Int) {
        countdownTotal = Double(seconds)
        if setDP(9, seconds), seconds > 0 {
            energy.log(.timer, "\(Fmt.duration(Double(seconds)))")
        }
    }

    func disconnectAll() {
        reconnectTask?.cancel()
        lan.disconnect()
        client.disconnect()
    }

    private func ingestLAN(_ dps: [String: Any]) {
        let converted: [RawDP] = dps.compactMap { key, value in
            guard let id = UInt8(key) else { return nil }
            if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                return TuyaDataPointCodec.decode(dpID: id, type: .bool, raw: Data([n.boolValue ? 1 : 0]))
            }
            if let n = value as? NSNumber {
                var be = Data(); be.appendBE(UInt32(truncatingIfNeeded: n.int64Value))
                return TuyaDataPointCodec.decode(dpID: id, type: .value, raw: be)
            }
            if let t = value as? String {
                return TuyaDataPointCodec.decode(dpID: id, type: .string, raw: Data(t.utf8))
            }
            return nil
        }
        ingest(converted, at: Date())
    }

    func startScan() {
        pairStatusText = nil
        client.startScan(allDevices: scanAll)
    }

    func stopScan() {
        client.stopScan()
    }

    func connect(to device: DiscoveredDevice) async {
        selectedDevice = device
        if let saved = store.find(uuid: device.uuid ?? "") {
            let keyData = saved.loginKey6Hex.hexToData()
            let text = String(data: keyData, encoding: .utf8) ?? ""
            if text.count == 6, text.allSatisfy({ $0.isLetter || $0.isNumber }) {
                customPairKey = text
            }
            if let vid = saved.virtualID, virtualID.isEmpty {
                virtualID = vid
            }
        }
        pairStatusText = nil
        handshake = nil
        latest.removeAll()
        isBusy = true
        busyLabel = "Conectando..."
        defer { isBusy = false; busyLabel = "" }
        let connected = await client.connect(to: device)
        guard connected else {
            pairStatusText = "Falha ao conectar"
            return
        }
        await runHandshake()
    }

    func runHandshake() async {
        isBusy = true
        busyLabel = "Handshake..."
        defer { isBusy = false; busyLabel = "" }
        let candidates = makeCandidates()
        guard !candidates.isEmpty else {
            pairStatusText = "Sem candidatos de chave"
            return
        }
        let result = await client.runHandshake(candidates: candidates)
        handshake = result
        if let result {
            pairStatusText = "Handshake OK: \(result.candidateLabel)"
            if autoPair, !(selectedDevice?.isBound ?? false) {
                await pair()
            }
        } else {
            pairStatusText = "Nenhuma chave funcionou — tente informar o local_key"
        }
    }

    func pair() async {
        guard client.handshake != nil else {
            pairStatusText = "Pareamento: rode o handshake primeiro"
            return
        }
        let uuid = effectiveUUID
        guard uuid.count == 16 else {
            pairStatusText = "UUID inválido (precisa ter 16 caracteres) — veja no anúncio do dispositivo"
            return
        }
        isBusy = true
        busyLabel = "Pareando..."
        defer { isBusy = false; busyLabel = "" }
        let key6 = normalizedKey6(Data(customPairKey.utf8))
        let vid = virtualID.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await client.pair(uuid: uuid, loginKey6: key6, virtualID: vid.isEmpty ? nil : vid)
        switch result {
        case 0:
            store.upsert(uuid: uuid, loginKey6: key6, virtualID: vid.isEmpty ? nil : vid, name: selectedDevice?.name ?? uuid)
            reloadSaved()
            pairStatusText = "PAIR aceito — reconectando com a chave nova"
            await reconnectWithSavedKey(uuid: uuid, key6: key6)
        case 2:
            store.upsert(uuid: uuid, loginKey6: key6, virtualID: vid.isEmpty ? nil : vid, name: selectedDevice?.name ?? uuid)
            reloadSaved()
            pairStatusText = "Dispositivo já estava pareado (ok)"
            await queryStatus()
        default:
            pairStatusText = "PAIR recusado (código \(result.map(String.init) ?? "?"))"
        }
    }

    private func reconnectWithSavedKey(uuid: String, key6: Data) async {
        guard let device = selectedDevice else { return }
        client.disconnect()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let connected = await client.connect(to: device)
        guard connected else {
            pairStatusText = "Pareado, mas a reconexão falhou"
            return
        }
        let candidate = classicCandidate(label: "chave pareada (salva)", six: key6)
        if let info = await client.runHandshake(candidates: [candidate]) {
            handshake = info
            pairStatusText = "Pareado e reconectado com a chave \(key6.hexString)"
            if autoQueryAfterPair {
                await queryStatus()
            }
        } else {
            pairStatusText = "Pareado, mas o handshake com a chave nova falhou"
        }
    }

    func queryStatus() async {
        if lanState == .ready {
            lan.query()
            lan.refreshMeasurements()
            return
        }
        guard client.state.isConnected else { return }
        if client.handshake == nil {
            isBusy = true
            busyLabel = "Handshake..."
            handshake = await client.runHandshake(candidates: makeCandidates())
            isBusy = false
            busyLabel = ""
            if handshake == nil { return }
        }
        await client.queryStatus()
    }

    @discardableResult
    func setSwitch(_ on: Bool) async -> Bool {
        if lanState == .ready {
            lan.setDPs(["1": on])
            return true
        }
        let encoded = TuyaDataPointCodec.encode(dpID: 1, type: .bool, number: nil, boolean: on, text: nil)
        return await client.sendDataPoints(encoded)
    }

    @discardableResult
    func sendRawDP(id: UInt8, type: TuyaDPType, value: String) async -> Bool {
        var number: Int64?
        var boolean: Bool?
        var text: String?
        switch type {
        case .bool:
            boolean = (value == "1" || value.lowercased() == "true" || value.lowercased() == "on")
        case .value, .enumValue, .bitmap:
            number = Int64(value) ?? 0
        case .string:
            text = value
        case .raw:
            break
        }
        if lanState == .ready {
            let v: Any = boolean ?? number.map { $0 as Any } ?? text ?? value
            lan.setDPs([String(id): v])
            return true
        }
        let encoded = TuyaDataPointCodec.encode(dpID: id, type: type, number: number, boolean: boolean, text: text)
        return await client.sendDataPoints(encoded)
    }

    func unbind() async {
        isBusy = true
        busyLabel = "Desvinculando..."
        defer { isBusy = false; busyLabel = "" }
        await client.unbind()
    }

    private func ingest(_ dps: [RawDP], at date: Date) {
        let previousOn = latest[1]?.boolean
        if let newOn = dps.first(where: { $0.dpID == 1 })?.boolean, let previousOn, newOn != previousOn {
            AlertEngine.switched(model: self, on: newOn, at: date)
        }
        for dp in dps {
            latest[dp.dpID] = dp
            history.append(DPRecord(
                date: date,
                dpID: dp.dpID,
                typeLabel: dp.type.label,
                rawHex: dp.rawHex,
                decoded: dp.decoded
            ))
        }
        if history.count > 4000 {
            history.removeFirst(history.count - 4000)
        }
        if let c = dps.first(where: { $0.dpID == 9 })?.number {
            if c > 0 {
                countdownEnd = date.addingTimeInterval(Double(c))
                if Double(c) > countdownTotal { countdownTotal = Double(c) }
            } else {
                countdownEnd = nil
                countdownTotal = 0
            }
        }
        let ids = Set(dps.map(\.dpID))
        if !ids.isDisjoint(with: [1, 18, 19, 20]), let watts = metrics.powerW {
            let m = metrics
            energy.record(watts: watts, volts: m.voltageV ?? 0, amps: m.currentA ?? 0,
                          isOn: m.isOn ?? (watts > 0.5), at: date, alertWatts: tariff.alertWatts)
            if date.timeIntervalSince(lastAlertEval) > 60 {
                lastAlertEval = date
                AlertEngine.evaluate(model: self, now: date)
            }
            if let v = m.voltageV, v > 50, (v < tariff.voltageMin || v > tariff.voltageMax),
               date.timeIntervalSince(lastVoltageAlert) > 900 {
                lastVoltageAlert = date
                energy.log(.voltage, "\(Fmt.num(v)) V")
            }
        }
    }

    var metrics: PlugMetrics {
        var result = PlugMetrics()
        result.isOn = latest[1]?.boolean
        if let voltage = latest[20]?.number {
            result.voltageV = Double(voltage) / 10.0
        }
        if let current = latest[18]?.number {
            result.currentA = Double(current) / 1000.0
        }
        if let power = latest[19]?.number {
            result.powerW = Double(power) / 10.0
        }
        if let energy = latest[17]?.number {
            result.energyKWh = Double(energy) / 1000.0
        }
        return result
    }

    func interpretation(for dp: RawDP) -> String? {
        switch dp.dpID {
        case 1: return "Relé / interruptor (bool)"
        case 9: return "Countdown em segundos"
        case 17: return "Energia acumulada (0,001 kWh)"
        case 18: return "Corrente (mA)"
        case 19: return "Potência (0,1 W)"
        case 20: return "Tensão (0,1 V)"
        case 21: return "Inching / test_bit"
        case 22, 23, 24, 25: return "Coeficiente de calibração"
        case 26: return "Falha"
        case 38: return "Estado ao religar (memory/on/off)"
        case 39: return "Proteção de sobrecarga"
        case 40: return "Modo do LED"
        case 41: return "Trava infantil"
        default: return nil
        }
    }

    func dpBool(_ id: UInt8) -> Bool? { latest[id]?.boolean }
    func dpInt(_ id: UInt8) -> Int? { latest[id]?.number.map(Int.init) }
    func dpString(_ id: UInt8) -> String? { latest[id]?.text }

    var sortedLatest: [RawDP] {
        latest.values.sorted { $0.dpID < $1.dpID }
    }

    private func normalizedKey6(_ data: Data) -> Data {
        var key = data.prefix(6)
        while key.count < 6 { key.append(0) }
        return key
    }

    func classicCandidate(label: String, six: Data) -> KeyCandidate {
        let key6 = normalizedKey6(six)
        return KeyCandidate(
            label: label,
            scheme: .classic,
            flag4: TuyaSecurityFlag.loginKey.rawValue,
            flag5: TuyaSecurityFlag.sessionKey.rawValue,
            key4: TuyaCrypto.md5(key6),
            pairKey6: key6,
            makeSessionKey: { srand in TuyaCrypto.md5(key6 + srand) }
        )
    }

    func v2Candidate(label: String, material: Data) -> KeyCandidate {
        KeyCandidate(
            label: label,
            scheme: .v2(secKey: secKey),
            flag4: TuyaSecurityFlag.loginKeyV2.rawValue,
            flag5: TuyaSecurityFlag.sessionKeyV2.rawValue,
            key4: TuyaCrypto.md5(material),
            pairKey6: Data(material.prefix(6)),
            makeSessionKey: { srand in TuyaCrypto.md5(material + srand) }
        )
    }

    func makeCandidates() -> [KeyCandidate] {
        var candidates: [KeyCandidate] = []
        var seen = Set<String>()

        func add(_ candidate: KeyCandidate) {
            if seen.insert(candidate.key4.hexString).inserted {
                candidates.append(candidate)
            }
        }

        if let uuid = selectedDevice?.uuid ?? (effectiveUUID.isEmpty ? nil : effectiveUUID),
           let saved = store.find(uuid: uuid) {
            add(classicCandidate(label: "chave salva do pareamento", six: saved.loginKey6Hex.hexToData()))
        }

        let manual = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if manual.count >= 6 {
            add(classicCandidate(label: "local_key informado (\(manual.prefix(6)))", six: Data(manual.prefix(6).utf8)))
        }

        if let uuid = selectedDevice?.uuid, uuid.count >= 6 {
            add(classicCandidate(label: "uuid[:6] (\(uuid.prefix(6)))", six: Data(uuid.prefix(6).utf8)))
        }

        add(classicCandidate(label: "000000 (ASCII)", six: Data("000000".utf8)))
        add(classicCandidate(label: "zeros binários", six: Data(repeating: 0, count: 6)))

        let sec = secKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sec.isEmpty, manual.count >= 6 {
            let material = Data((manual + sec).utf8)
            add(v2Candidate(label: "v2 (local_key + sec_key)", material: material))
        }

        return candidates
    }

    func exportCSV() -> URL? {
        var csv = "timestamp;dp_id;tipo;valor_bruto;decodificado\n"
        let formatter = ISO8601DateFormatter()
        for record in history {
            csv += "\(formatter.string(from: record.date));\(record.dpID);\(record.typeLabel);\(record.rawHex);\(record.decoded)\n"
        }
        let name = "plug-dps-\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    func exportLog() -> URL? {
        var text = "Log BLE - Plug Inteligente\n\n"
        for entry in logs {
            text += "[\(entry.timeString)] \(label(for: entry.kind)) \(entry.title)"
            if let detail = entry.detail {
                text += " | \(detail)"
            }
            if let bytes = entry.bytes {
                text += " | \(bytes.hexString)"
            }
            text += "\n"
        }
        let name = "plug-log-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func label(for kind: LogEntry.Kind) -> String {
        switch kind {
        case .info: return "INFO"
        case .tx: return "TX→"
        case .rx: return "RX←"
        case .error: return "ERR "
        case .success: return "OK  "
        }
    }

    /// Teste LAN sem UI: `--lan <ip> <local_key> --lantest`. Só lê, não altera o relé.
    func runLanTest() async {
        print("[TUYA] LANTEST início")
        for _ in 0..<60 where lanState != .ready { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard lanState == .ready else { print("[TUYA] LANTEST FIM: \(lanState.label)"); return }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        let m = metrics
        print("[TUYA] LANTEST FIM: on=\(String(describing: m.isOn)) W=\(String(describing: m.powerW)) V=\(String(describing: m.voltageV)) A=\(String(describing: m.currentA)) kWh=\(String(describing: m.energyKWh)) amostras=\(history.count)")
    }

    /// Teste sem UI: `--autotest` nos argumentos de launch. Resultado vai para stdout ([TUYA]).
    func runAutotest() async {
        print("[TUYA] AUTOTEST início")
        for _ in 0..<20 where state != .ready { try? await Task.sleep(nanoseconds: 250_000_000) }
        scanAll = true
        startScan()
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        stopScan()
        print("[TUYA] AUTOTEST dispositivos: \(devices.map { "\($0.name) rssi=\($0.rssi) bound=\($0.isBound) pid=\($0.productID ?? "-") uuid=\($0.uuid ?? "-") mfr=\($0.manufacturerRaw?.hexString ?? "-") svc=\($0.serviceDataRaw?.hexString ?? "-")" })")
        guard let best = devices.max(by: { $0.rssi < $1.rssi }) else {
            print("[TUYA] AUTOTEST FIM: nenhum dispositivo Tuya encontrado"); return
        }
        await connect(to: best)
        if handshake != nil {
            await queryStatus()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        print("[TUYA] AUTOTEST FIM: handshake=\(handshake?.candidateLabel ?? "falhou") status=\(pairStatusText ?? "-") dps=\(sortedLatest.map { "\($0.dpID)=\($0.decoded)" })")
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearHistory() {
        history.removeAll()
        latest.removeAll()
    }

    func deleteSaved(id: UUID) {
        store.remove(id: id)
        reloadSaved()
    }
}

extension String {
    func hexToData() -> Data {
        var data = Data()
        var chars = Array(trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if chars.count % 2 != 0 { chars.insert("0", at: 0) }
        var index = 0
        while index + 1 < chars.count {
            let byteString = String(chars[index...(index + 1)])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
            index += 2
        }
        return data
    }
}
