import Foundation
import Network
import CryptoKit

/// Cliente local Tuya protocolo 3.5 (TCP 6668, frames 0x6699, AES-GCM, sessão negociada).
/// Referência: tinytuya (jasonacox/tinytuya) core.
final class TuyaLanClient {
    enum State: Equatable {
        case idle, connecting, negotiating, ready, failed(String)

        var label: String {
            switch self {
            case .idle: return "Wi-Fi desconectado"
            case .connecting: return "Conectando via Wi-Fi"
            case .negotiating: return "Negociando sessão"
            case .ready: return "Conectado via Wi-Fi"
            case .failed(let why): return "Wi-Fi: \(why)"
            }
        }
    }

    enum Cmd: UInt32 {
        case sessKeyNegStart = 0x03, sessKeyNegResp = 0x04, sessKeyNegFinish = 0x05
        case status = 0x08, heartBeat = 0x09, controlNew = 0x0D, dpQueryNew = 0x10, updateDPs = 0x12
    }

    var onState: ((State) -> Void)?
    var onDPs: (([String: Any]) -> Void)?
    var onLog: ((LogEntry) -> Void)?

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private var seq: UInt32 = 1
    private var localKey = Data()
    private var sessionKey: Data?
    private var localNonce = Data()
    private var heartbeat: Timer?
    private var negotiationTimeout: Timer?

    func connect(host: String, localKey: String) {
        disconnect()
        self.localKey = Data(localKey.utf8)
        guard self.localKey.count == 16 else {
            state = .failed("local_key precisa ter 16 caracteres")
            return
        }
        state = .connecting
        log(.info("LAN: conectando \(host):6668"))
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 6668, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] st in
            guard let self, self.connection === conn else { return }
            switch st {
            case .ready:
                self.startNegotiation()
                self.receive()
            case .waiting(let error):
                // Normal enquanto o iOS pede permissão de Rede Local; o NWConnection tenta de novo sozinho.
                self.log(.info("LAN: aguardando rede/permissão", error.localizedDescription))
            case .failed(let error):
                self.log(.error("LAN: conexão falhou", error.localizedDescription))
                self.state = .failed(error.localizedDescription)
                self.teardown()
            case .cancelled:
                if self.state != .idle { self.state = .idle }
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        teardown()
        state = .idle
    }

    private func teardown() {
        heartbeat?.invalidate(); heartbeat = nil
        negotiationTimeout?.invalidate(); negotiationTimeout = nil
        connection?.cancel(); connection = nil
        buffer.removeAll()
        sessionKey = nil
        seq = 1
    }

    // MARK: Comandos

    func setDPs(_ dps: [String: Any]) {
        let body: [String: Any] = [
            "protocol": 5,
            "t": Int(Date().timeIntervalSince1970),
            "data": ["dps": dps],
        ]
        sendJSON(.controlNew, body)
    }

    func query() {
        sendJSON(.dpQueryNew, [:])
    }

    /// Pede ao device para reenviar medições (corrente/potência/tensão/energia).
    func refreshMeasurements(_ ids: [Int] = [17, 18, 19, 20]) {
        sendJSON(.updateDPs, ["dpId": ids])
    }

    private func sendJSON(_ cmd: Cmd, _ object: [String: Any]) {
        guard state == .ready, let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        // Comandos "novos" levam o cabeçalho de versão "3.5" + 12 zeros.
        var payload = Data()
        if cmd == .controlNew {
            payload.append(Data("3.5".utf8))
            payload.append(Data(count: 12))
        }
        payload.append(json)
        send(cmd, payload: payload)
        log(.tx("LAN \(cmd) \(String(decoding: json, as: UTF8.self))", bytes: nil))
    }

    // MARK: Negociação de sessão

    private func startNegotiation() {
        state = .negotiating
        localNonce = TuyaCrypto.randomData(count: 16)
        send(.sessKeyNegStart, payload: localNonce, key: localKey)
        negotiationTimeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, self.state == .negotiating else { return }
            self.log(.error("LAN: device não respondeu à negociação", "local_key errado ou outro cliente conectado"))
            self.state = .failed("sem resposta (local_key?)")
            self.teardown()
        }
    }

    private func handleNegotiationResponse(_ payload: Data) {
        // remote_nonce(16) + hmac(local_key, local_nonce)(32), às vezes precedido de retcode(4)
        let body = payload.count >= 52 ? payload.suffix(48) : payload
        guard body.count == 48 else {
            fail("resposta de negociação inválida (\(payload.count)B)")
            return
        }
        let remoteNonce = Data(body.prefix(16))
        let mac = Data(body.suffix(32))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: localNonce, using: SymmetricKey(data: localKey)))
        guard mac == expected else {
            fail("HMAC não confere — local_key errado")
            return
        }
        let finish = Data(HMAC<SHA256>.authenticationCode(for: remoteNonce, using: SymmetricKey(data: localKey)))
        send(.sessKeyNegFinish, payload: finish, key: localKey)

        let xored = Data(zip(localNonce, remoteNonce).map { $0 ^ $1 })
        guard let sealed = try? AES.GCM.seal(
            xored,
            using: SymmetricKey(data: localKey),
            nonce: AES.GCM.Nonce(data: localNonce.prefix(12))
        ) else {
            fail("falha ao derivar session key")
            return
        }
        sessionKey = Data(sealed.ciphertext.prefix(16))
        negotiationTimeout?.invalidate()
        state = .ready
        log(.success("LAN: sessão 3.5 estabelecida"))
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.send(.heartBeat, payload: Data("{}".utf8))
        }
        query()
    }

    private func fail(_ why: String) {
        log(.error("LAN: \(why)"))
        state = .failed(why)
        teardown()
    }

    // MARK: Frames 0x6699

    private func send(_ cmd: Cmd, payload: Data, key: Data? = nil) {
        guard let connection, let key = key ?? sessionKey else { return }
        let iv = TuyaCrypto.randomData(count: 12)
        var header = Data()
        header.appendBE(UInt32(0x0000_6699))
        header.appendBE(UInt16(0))
        header.appendBE(seq)
        header.appendBE(cmd.rawValue)
        header.appendBE(UInt32(12 + payload.count + 16))
        seq &+= 1
        guard let sealed = try? AES.GCM.seal(
            payload,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: iv),
            authenticating: header.dropFirst(4)
        ) else { return }
        var frame = header
        frame.append(iv)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        frame.appendBE(UInt32(0x0000_9966))
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.log(.error("LAN: envio falhou", error.localizedDescription)) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                if self.state == .ready || self.state == .negotiating {
                    self.log(.info("LAN: conexão encerrada pelo device", error?.localizedDescription))
                    self.state = .failed("conexão encerrada")
                }
                self.teardown()
                return
            }
            self.receive()
        }
    }

    private func drainFrames() {
        while buffer.count >= 22 {
            guard buffer.beUInt32(at: 0) == 0x0000_6699 else {
                // ressincroniza no próximo prefixo
                if let r = buffer.range(of: Data([0, 0, 0x66, 0x99]), in: (buffer.startIndex + 1)..<buffer.endIndex) {
                    buffer = Data(buffer[r.lowerBound...])
                    continue
                }
                buffer.removeAll()
                return
            }
            let length = Int(buffer.beUInt32(at: 14) ?? 0)
            let total = 18 + length + 4
            guard buffer.count >= total else { return }
            let frame = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            handleFrame(frame, length: length)
        }
    }

    private func handleFrame(_ frame: Data, length: Int) {
        guard length >= 28, let cmdRaw = frame.beUInt32(at: 10) else { return }
        let header = frame.subdata(in: 4..<18)
        let iv = frame.subdata(in: 18..<30)
        let cipher = frame.subdata(in: 30..<(18 + length - 16))
        let tag = frame.subdata(in: (18 + length - 16)..<(18 + length))
        let key = (cmdRaw == Cmd.sessKeyNegResp.rawValue || sessionKey == nil) ? localKey : sessionKey!
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header) else {
            log(.error("LAN: frame cmd \(cmdRaw) não decifrou"))
            return
        }
        if cmdRaw == Cmd.sessKeyNegResp.rawValue {
            handleNegotiationResponse(plain)
            return
        }
        handlePayload(plain, cmd: cmdRaw)
    }

    private func handlePayload(_ plain: Data, cmd: UInt32) {
        // Pode vir: retcode(4) e/ou "3.5"+12 bytes antes do JSON.
        guard let start = plain.firstIndex(of: UInt8(ascii: "{")) else { return }
        let json = plain[start...]
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            log(.info("LAN: payload não-JSON cmd \(cmd)", String(decoding: json, as: UTF8.self)))
            return
        }
        let dps = (object["dps"] as? [String: Any])
            ?? ((object["data"] as? [String: Any])?["dps"] as? [String: Any])
        if let dps, !dps.isEmpty {
            log(.rx("LAN cmd \(cmd) dps=\(dps)", bytes: nil))
            onDPs?(dps)
        }
    }

    private func log(_ entry: LogEntry) {
        print("[TUYA] \(entry.timeString) \(entry.title) \(entry.detail ?? "")")
        onLog?(entry)
    }
}
