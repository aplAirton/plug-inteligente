import Foundation
import CryptoKit
import Security

/// Cliente mínimo da Tuya OpenAPI (projeto Cloud em iot.tuya.com) para importar o log de relatórios.
/// A Tuya guarda ~7 dias de log no plano gratuito; o app importa a cada abertura e acumula localmente.
struct TuyaCloudClient {
    struct Log: Decodable {
        let code: String
        let event_time: Int64
        let value: String

        var date: Date { Date(timeIntervalSince1970: Double(event_time) / 1000) }
    }

    enum CloudError: LocalizedError {
        case api(String)
        var errorDescription: String? {
            switch self { case .api(let m): return m }
        }
    }

    let clientID: String
    let secret: String
    var host = "https://openapi.tuyaus.com"

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let code: Int?
        let msg: String?
        let result: T?
    }

    private struct Token: Decodable { let access_token: String }

    private struct LogPage: Decodable {
        let logs: [Log]
        let has_more: Bool?
        let last_row_key: String?
    }

    private func request<T: Decodable>(_ path: String, _ params: [String: String], token: String = "",
                                       method: String = "GET", body: Data? = nil) async throws -> Envelope<T> {
        let query = params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        let url = path + (query.isEmpty ? "" : "?" + query)
        let t = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let bodyHash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        let stringToSign = "\(method)\n\(bodyHash)\n\n\(url)"
        let message = clientID + token + t + nonce + stringToSign
        let sign = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02X", $0) }.joined()

        var req = URLRequest(url: URL(string: host + url)!)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue(clientID, forHTTPHeaderField: "client_id")
        req.setValue(sign, forHTTPHeaderField: "sign")
        req.setValue(t, forHTTPHeaderField: "t")
        req.setValue(nonce, forHTTPHeaderField: "nonce")
        req.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "access_token") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Envelope<T>.self, from: data)
    }

    func token() async throws -> String {
        let env: Envelope<Token> = try await request("/v1.0/token", ["grant_type": "1"])
        guard env.success, let tok = env.result?.access_token else {
            throw CloudError.api(env.msg ?? "falha no token")
        }
        return tok
    }

    // MARK: Timers na nuvem (executam mesmo com o app fechado)

    struct TimerInstruct: Encodable {
        struct Function: Encodable {
            let code: String
            let value: Bool
        }
        let functions: [Function]
        let date: String
        let time: String
    }

    private struct TimerBody: Encodable {
        let category: String
        let loops: String
        let timezone_id: String
        let time_zone: String
        let instruct: [TimerInstruct]
    }

    private struct Empty: Decodable {}
    private struct AnyResult: Decodable {}

    /// Cria um grupo de timers (uma categoria por perfil). `loops`: 7 dígitos, domingo→sábado.
    func createTimers(device: String, category: String, loops: String, instructs: [TimerInstruct]) async throws {
        let tok = try await token()
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT()
        let body = TimerBody(
            category: category, loops: loops, timezone_id: tz.identifier,
            time_zone: String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, (abs(offset) % 3600) / 60),
            instruct: instructs
        )
        let env: Envelope<AnyResult> = try await request("/v1.0/devices/\(device)/timers", [:], token: tok,
                                                          method: "POST", body: try JSONEncoder().encode(body))
        guard env.success else { throw CloudError.api(env.msg ?? "falha ao criar timers") }
    }

    func deleteTimers(device: String, category: String) async throws {
        let tok = try await token()
        let env: Envelope<Bool> = try await request("/v1.0/devices/\(device)/timers/categories/\(category)", [:],
                                                     token: tok, method: "DELETE")
        guard env.success else { throw CloudError.api(env.msg ?? "falha ao remover timers") }
    }

    // MARK: Estatísticas (histórico longo — exige o serviço "Statistics" no projeto)

    private struct DaysResult: Decodable { let days: [String: String]? }

    /// Totais diários de add_ele (kWh) no intervalo yyyyMMdd.
    func dailyTotals(device: String, from: Date, to: Date) async throws -> [Date: Double] {
        let tok = try await token()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .current
        let env: Envelope<DaysResult> = try await request("/v1.0/devices/\(device)/statistics/days",
            ["code": "add_ele", "start_day": f.string(from: from), "end_day": f.string(from: to)], token: tok)
        guard env.success else { throw CloudError.api(env.msg ?? "estatísticas indisponíveis") }
        var out: [Date: Double] = [:]
        for (k, v) in env.result?.days ?? [:] {
            if let d = f.date(from: k), let kwh = Double(v) { out[d] = kwh }
        }
        return out
    }

    /// Busca todos os relatórios no intervalo, paginando e respeitando o limite de frequência.
    func reportLogs(device: String, codes: [String], from: Date, to: Date,
                    progress: (Int) -> Void) async throws -> [Log] {
        let tok = try await token()
        var all: [Log] = []
        var rowKey: String?
        var retries = 0
        while true {
            var p = [
                "codes": codes.joined(separator: ","),
                "start_time": String(Int64(from.timeIntervalSince1970 * 1000)),
                "end_time": String(Int64(to.timeIntervalSince1970 * 1000)),
                "size": "100",
            ]
            if let rowKey { p["last_row_key"] = rowKey }
            let env: Envelope<LogPage> = try await request("/v2.0/cloud/thing/\(device)/report-logs", p, token: tok)
            if !env.success {
                // 40000309: consultas frequentes demais
                if env.code == 40000309, retries < 12 {
                    retries += 1
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                throw CloudError.api(env.msg ?? "erro \(env.code ?? 0)")
            }
            retries = 0
            guard let page = env.result else { break }
            all += page.logs
            progress(all.count)
            guard page.has_more == true, let key = page.last_row_key else { break }
            rowKey = key
            try await Task.sleep(for: .milliseconds(1200))
        }
        return all
    }
}

// MARK: - Keychain

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Sincronização

@Observable
final class CloudSync {
    enum Status: Equatable {
        case idle, syncing(Int), done(Date, Int), failed(String)

        var label: String {
            switch self {
            case .idle: return "Não sincronizado"
            case .syncing(let n): return n == 0 ? "Conectando à nuvem…" : "Importando… \(n) registros"
            case .done(let d, let n): return "Atualizado \(d.formatted(.relative(presentation: .named).locale(Locale(identifier: "pt_BR")))) · \(n) novos"
            case .failed(let m): return "Erro: \(m)"
            }
        }
    }

    var clientID: String { didSet { Keychain.set(clientID, for: "cloud.id") } }
    var secret: String { didSet { Keychain.set(secret, for: "cloud.secret") } }
    var deviceID: String { didSet { UserDefaults.standard.set(deviceID, forKey: "cloud.device") } }
    private(set) var status: Status = .idle

    /// Último event_time importado (ms) — próxima consulta começa depois dele.
    private var cursor: Int64 {
        get { (UserDefaults.standard.object(forKey: "cloud.cursor") as? NSNumber)?.int64Value ?? 0 }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: "cloud.cursor") }
    }
    private var syncedUntil: Date? {
        get { UserDefaults.standard.object(forKey: "cloud.syncedUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.syncedUntil") }
    }

    static let codes = ["cur_power", "cur_voltage", "cur_current", "add_ele", "switch_1"]

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--cloud"), i + 3 < args.count {
            Keychain.set(args[i + 1], for: "cloud.id")
            Keychain.set(args[i + 2], for: "cloud.secret")
            UserDefaults.standard.set(args[i + 3], forKey: "cloud.device")
        }
        clientID = Keychain.get("cloud.id")
        secret = Keychain.get("cloud.secret")
        deviceID = UserDefaults.standard.string(forKey: "cloud.device") ?? ""
    }

    var client: TuyaCloudClient {
        TuyaCloudClient(clientID: clientID.trimmingCharacters(in: .whitespaces),
                        secret: secret.trimmingCharacters(in: .whitespaces))
    }

    var isConfigured: Bool { !clientID.isEmpty && !secret.isEmpty && !deviceID.isEmpty }

    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    /// Mensagem sobre o histórico longo (estatísticas), exibida em Ajustes.
    private(set) var statisticsNote: String?

    /// Importa totais diários de até 2 anos, em blocos de 30 dias, parando ao encontrar 60 dias vazios.
    private func importStatistics(into store: EnergyStore, client: TuyaCloudClient) async {
        let cal = Calendar.current
        let lastFull = UserDefaults.standard.object(forKey: "cloud.statsFull") as? Date
        let horizon = lastFull != nil ? 35 : 730
        var end = Date()
        var emptyRun = 0
        var imported = 0
        while cal.dateComponents([.day], from: end, to: Date()).day ?? 0 < horizon {
            let start = cal.date(byAdding: .day, value: -29, to: end)!
            do {
                let totals = try await client.dailyTotals(device: deviceID.trimmingCharacters(in: .whitespaces), from: start, to: end)
                store.importDayTotals(totals)
                let nonZero = totals.values.filter { $0 > 0 }.count
                imported += nonZero
                emptyRun = nonZero == 0 ? emptyRun + 30 : 0
                if emptyRun >= 60 { break }
            } catch {
                statisticsNote = "Histórico longo indisponível: \(error.localizedDescription). Ative o serviço \"Statistics\" no projeto em iot.tuya.com."
                return
            }
            end = cal.date(byAdding: .day, value: -1, to: start)!
            try? await Task.sleep(for: .milliseconds(400))
        }
        UserDefaults.standard.set(Date(), forKey: "cloud.statsFull")
        statisticsNote = imported > 0 ? "Histórico longo: \(imported) dias importados das estatísticas" : nil
    }

    func resetCursor() {
        UserDefaults.standard.removeObject(forKey: "cloud.statsFull")
        cursor = 0
        syncedUntil = nil
    }

    func sync(into store: EnergyStore, force: Bool = false) async {
        guard isConfigured, !isSyncing else { return }
        if !force, let until = syncedUntil, Date().timeIntervalSince(until) < 300 { return }
        status = .syncing(0)
        let now = Date()
        let floor = now.addingTimeInterval(-7 * 86_400 + 60)
        let from = max(cursor > 0 ? Date(timeIntervalSince1970: Double(cursor + 1) / 1000) : floor, floor)
        let client = TuyaCloudClient(clientID: clientID.trimmingCharacters(in: .whitespaces),
                                     secret: secret.trimmingCharacters(in: .whitespaces))
        do {
            let logs = try await client.reportLogs(device: deviceID.trimmingCharacters(in: .whitespaces),
                                                   codes: Self.codes, from: from, to: now) { [weak self] n in
                self?.status = .syncing(n)
            }
            let coverageStart = syncedUntil.map { max($0, floor) } ?? (logs.map(\.date).min() ?? from)
            store.importCloud(logs, covering: coverageStart...now)
            // Estatísticas longas exigem serviço "Statistics" (indisponível); o espelho local acumula além de 7 dias.
            if let maxT = logs.map(\.event_time).max() { cursor = max(cursor, maxT) }
            syncedUntil = now
            status = .done(now, logs.count)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
