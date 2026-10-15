import Foundation
import SwiftData

// MARK: - Modelos persistidos

/// Leitura agregada (média de ~15 s). Mantida por `EnergyStore.readingRetention`.
@Model
final class Reading {
    #Index<Reading>([\.date])
    var date: Date
    var watts: Double
    var volts: Double
    var amps: Double
    var isOn: Bool
    var fromCloud: Bool = false

    init(date: Date, watts: Double, volts: Double, amps: Double, isOn: Bool) {
        self.date = date
        self.watts = watts
        self.volts = volts
        self.amps = amps
        self.isOn = isOn
    }
}

/// Estatística de uma hora cheia. Mantida para sempre (base de dia/semana/mês).
@Model
final class HourStat {
    #Index<HourStat>([\.start])
    @Attribute(.unique) var start: Date
    var wattHours: Double
    var coveredSeconds: Double
    var onSeconds: Double
    var peakWatts: Double
    var sumWatts: Double
    var minVolts: Double
    var maxVolts: Double
    var sumVolts: Double
    var peakAmps: Double
    var samples: Int
    /// Energia reportada pela nuvem (add_ele) nesta hora, em Wh.
    var cloudWh: Double = 0
    /// Segundos ligada segundo o histórico de liga/desliga da nuvem.
    var cloudOnSeconds: Double = 0
    /// A nuvem monitorou esta hora (mesmo sem eventos).
    var cloudCovered: Bool = false

    init(start: Date) {
        self.start = start
        wattHours = 0
        coveredSeconds = 0
        onSeconds = 0
        peakWatts = 0
        sumWatts = 0
        minVolts = .greatestFiniteMagnitude
        maxVolts = 0
        sumVolts = 0
        peakAmps = 0
        samples = 0
    }

    var avgWatts: Double { samples > 0 ? sumWatts / Double(samples) : 0 }
    var avgVolts: Double { samples > 0 ? sumVolts / Double(samples) : 0 }
    /// Melhor estimativa: medição local (precisa) ou nuvem (cobre quando o app estava fechado).
    var effectiveWh: Double { max(wattHours, cloudWh) }
    var effectiveCovered: Double { cloudCovered ? 3600 : coveredSeconds }
    var effectiveOn: Double { max(onSeconds, cloudOnSeconds) }
    var kWh: Double { effectiveWh / 1000 }
}

/// Total diário vindo das estatísticas da nuvem (histórico longo, sem detalhe por hora).
@Model
final class DayTotal {
    @Attribute(.unique) var day: Date
    var kWh: Double

    init(day: Date, kWh: Double) {
        self.day = day
        self.kWh = kWh
    }
}

@Model
final class PlugEvent {
    #Index<PlugEvent>([\.date])
    var date: Date
    var kind: String
    var detail: String

    init(date: Date = .now, kind: Kind, detail: String = "") {
        self.date = date
        self.kind = kind.rawValue
        self.detail = detail
    }

    enum Kind: String {
        case switchedOn, switchedOff, connected, disconnected, peak, overload, voltage, timer

        var icon: String {
            switch self {
            case .switchedOn: return "power.circle.fill"
            case .switchedOff: return "poweroff"
            case .connected: return "wifi"
            case .disconnected: return "wifi.slash"
            case .peak: return "bolt.fill"
            case .overload: return "exclamationmark.triangle.fill"
            case .voltage: return "waveform.path.ecg"
            case .timer: return "timer"
            }
        }

        var title: String {
            switch self {
            case .switchedOn: return "Ligada"
            case .switchedOff: return "Desligada"
            case .connected: return "Conectada"
            case .disconnected: return "Conexão perdida"
            case .peak: return "Novo pico do dia"
            case .overload: return "Acima do limite"
            case .voltage: return "Tensão fora da faixa"
            case .timer: return "Temporizador"
            }
        }
    }

    var eventKind: Kind { Kind(rawValue: kind) ?? .connected }
}

// MARK: - Agregados (não persistidos)

struct DayStat: Identifiable, Hashable {
    let day: Date
    var kWh: Double
    var onSeconds: Double
    var peakWatts: Double
    var coveredSeconds: Double
    var hourly: [Double]          // Wh por hora (24)

    var id: Date { day }
}

// MARK: - Store / gravador

@Observable
final class EnergyStore {
    static let readingRetention: TimeInterval = 14 * 86_400
    private static let flushInterval: TimeInterval = 15
    private static let maxGap: TimeInterval = 90

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Buffer ao vivo (últimos ~15 min, todas as amostras) para o gráfico em tempo real.
    private(set) var live: [LiveSample] = []
    /// Incrementa a cada mudança persistida; views observam para recarregar.
    private(set) var revision = 0

    @ObservationIgnored private var cache: [String: Any] = [:]
    @ObservationIgnored private var cacheRevision = -1

    /// Memoiza consultas até a próxima gravação (evita fetch a cada redesenho).
    private func memo<T>(_ key: String, _ compute: () -> T) -> T {
        if cacheRevision != revision {
            cache.removeAll()
            cacheRevision = revision
        }
        if let hit = cache[key] as? T { return hit }
        let value = compute()
        cache[key] = value
        return value
    }

    private func minute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private var last: LiveSample?
    private var pending: [LiveSample] = []
    private var currentHour: HourStat?
    private var todayPeak: Double = 0
    @ObservationIgnored private let startedAt = Date()
    @ObservationIgnored private var peakDay = Calendar.current.startOfDay(for: Date())
    private var lastAlert: Date = .distantPast

    struct LiveSample: Identifiable, Hashable {
        let date: Date
        let watts: Double
        let volts: Double
        let amps: Double
        let isOn: Bool
        var id: Date { date }
    }

    init(inMemory: Bool = false) {
        let schema = Schema([Reading.self, HourStat.self, PlugEvent.self, DayTotal.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Banco corrompido/migração impossível: recomeça em memória para não travar o app.
            print("[STORE] falha ao abrir: \(error)")
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        todayPeak = day(Date()).peakWatts
        prune()
    }

    // MARK: Gravação

    func record(watts: Double, volts: Double, amps: Double, isOn: Bool, at date: Date = .now, alertWatts: Double? = nil) {
        let sample = LiveSample(date: date, watts: watts, volts: volts, amps: amps, isOn: isOn)
        live.append(sample)
        if let first = live.first, date.timeIntervalSince(first.date) > 900 {
            live.removeAll { date.timeIntervalSince($0.date) > 900 }
        }

        if let last, last.isOn != isOn {
            log(isOn ? .switchedOn : .switchedOff)
        }

        if let last {
            let dt = date.timeIntervalSince(last.date)
            if dt > 0 && dt <= Self.maxGap {
                integrate(from: last, to: sample, dt: dt)
            }
        }
        last = sample
        pending.append(sample)

        let day = Calendar.current.startOfDay(for: date)
        if day != peakDay { peakDay = day; todayPeak = 0 }
        if watts > todayPeak {
            // Só registra pico depois de 10 min de coleta e se superar o anterior em 10%.
            let notable = date.timeIntervalSince(startedAt) > 600 && todayPeak > 0 && watts > todayPeak * 1.1 && watts > 50
            todayPeak = watts
            if notable { log(.peak, "\(Fmt.num(watts, 0)) W") }
        }
        if let alertWatts, watts > alertWatts, date.timeIntervalSince(lastAlert) > 600 {
            lastAlert = date
            log(.overload, "\(Fmt.num(watts)) W > \(Fmt.num(alertWatts, 0)) W")
        }

        if let first = pending.first, date.timeIntervalSince(first.date) >= Self.flushInterval {
            flush()
        }
    }

    /// Integra energia por trapézio, dividindo entre horas quando necessário.
    private func integrate(from a: LiveSample, to b: LiveSample, dt: Double) {
        let hourA = hourStart(a.date)
        let hourB = hourStart(b.date)
        if hourA == hourB {
            accumulate(hour: hourA, a: a, b: b, dt: dt)
        } else {
            let split = hourB.timeIntervalSince(a.date)
            let mid = LiveSample(date: hourB, watts: a.watts + (b.watts - a.watts) * split / dt,
                                 volts: b.volts, amps: b.amps, isOn: b.isOn)
            accumulate(hour: hourA, a: a, b: mid, dt: split)
            accumulate(hour: hourB, a: mid, b: b, dt: dt - split)
        }
    }

    private func accumulate(hour: Date, a: LiveSample, b: LiveSample, dt: Double) {
        let stat = hourStat(hour)
        stat.wattHours += (a.watts + b.watts) / 2 * dt / 3600
        stat.coveredSeconds += dt
        if b.isOn { stat.onSeconds += dt }
        stat.peakWatts = max(stat.peakWatts, b.watts)
        stat.peakAmps = max(stat.peakAmps, b.amps)
        stat.sumWatts += b.watts
        if b.volts > 50 {
            stat.minVolts = min(stat.minVolts, b.volts)
            stat.maxVolts = max(stat.maxVolts, b.volts)
            stat.sumVolts += b.volts
        }
        stat.samples += 1
    }

    private func hourStat(_ start: Date) -> HourStat {
        if let currentHour, currentHour.start == start { return currentHour }
        let descriptor = FetchDescriptor<HourStat>(predicate: #Predicate { $0.start == start })
        let stat = (try? context.fetch(descriptor).first) ?? {
            let s = HourStat(start: start)
            context.insert(s)
            return s
        }()
        currentHour = stat
        return stat
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let n = Double(pending.count)
        let avg = Reading(
            date: pending.last!.date,
            watts: pending.map(\.watts).reduce(0, +) / n,
            volts: pending.map(\.volts).reduce(0, +) / n,
            amps: pending.map(\.amps).reduce(0, +) / n,
            isOn: pending.last!.isOn
        )
        context.insert(avg)
        pending.removeAll()
        try? context.save()
        revision &+= 1
    }

    func log(_ kind: PlugEvent.Kind, _ detail: String = "") {
        context.insert(PlugEvent(kind: kind, detail: detail))
        try? context.save()
        revision &+= 1
    }

    /// Quebra a continuidade (ex.: desconexão) para não integrar o intervalo sem dados.
    func markGap() {
        flush()
        last = nil
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.readingRetention)
        try? context.delete(model: Reading.self, where: #Predicate { $0.date < cutoff })
        let eventCutoff = Date().addingTimeInterval(-90 * 86_400)
        try? context.delete(model: PlugEvent.self, where: #Predicate { $0.date < eventCutoff })
        try? context.save()
    }

    func eraseAll() {
        try? context.delete(model: Reading.self)
        try? context.delete(model: HourStat.self)
        try? context.delete(model: PlugEvent.self)
        try? context.delete(model: DayTotal.self)
        try? context.save()
        currentHour = nil
        live.removeAll()
        last = nil
        todayPeak = 0
        revision &+= 1
    }

    // MARK: Consultas

    private var calendar: Calendar { Calendar.current }

    func hourStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .hour, for: date)!.start
    }

    func hours(from: Date, to: Date) -> [HourStat] {
        let descriptor = FetchDescriptor<HourStat>(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func day(_ date: Date) -> DayStat {
        days(from: date, count: 1).first!
    }

    /// `count` dias consecutivos começando no dia de `from` (inclui dias sem dados).
    func days(from: Date, count: Int) -> [DayStat] {
        memo("days-\(calendar.startOfDay(for: from).timeIntervalSince1970)-\(count)") { computeDays(from: from, count: count) }
    }

    private func computeDays(from: Date, count: Int) -> [DayStat] {
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: count, to: start)!
        var result: [Date: DayStat] = [:]
        for i in 0..<count {
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            result[d] = DayStat(day: d, kWh: 0, onSeconds: 0, peakWatts: 0, coveredSeconds: 0, hourly: Array(repeating: 0, count: 24))
        }
        for h in hours(from: start, to: end) {
            let d = calendar.startOfDay(for: h.start)
            let hour = calendar.component(.hour, from: h.start)
            guard var stat = result[d] else { continue }
            stat.kWh += h.kWh
            stat.onSeconds += h.effectiveOn
            stat.coveredSeconds += h.effectiveCovered
            stat.peakWatts = max(stat.peakWatts, h.peakWatts)
            stat.hourly[hour] += h.effectiveWh
            result[d] = stat
        }
        // Totais diários da nuvem cobrem dias sem detalhe horário.
        let totals = (try? context.fetch(FetchDescriptor<DayTotal>(predicate: #Predicate { $0.day >= start && $0.day < end }))) ?? []
        for t in totals {
            guard var stat = result[t.day], t.kWh > stat.kWh + 0.001 else { continue }
            stat.kWh = t.kWh
            stat.coveredSeconds = max(stat.coveredSeconds, 86_400)
            result[t.day] = stat
        }
        return result.values.sorted { $0.day < $1.day }
    }

    func importDayTotals(_ totals: [Date: Double]) {
        for (day, kWh) in totals where kWh > 0 {
            let d = calendar.startOfDay(for: day)
            let existing = try? context.fetch(FetchDescriptor<DayTotal>(predicate: #Predicate { $0.day == d })).first
            if let existing { existing.kWh = kWh } else { context.insert(DayTotal(day: d, kWh: kWh)) }
        }
        try? context.save()
        revision &+= 1
    }

    func lastDays(_ n: Int) -> [DayStat] {
        let first = calendar.date(byAdding: .day, value: -(n - 1), to: Date())!
        return days(from: first, count: n)
    }

    func readings(since raw: Date) -> [Reading] {
        let since = minute(raw)
        return memo("readings-\(since.timeIntervalSince1970)") { fetchReadings(since: since) }
    }

    private func fetchReadings(since: Date) -> [Reading] {
        let descriptor = FetchDescriptor<Reading>(
            predicate: #Predicate { $0.date >= since },
            sortBy: [SortDescriptor(\.date)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func events(limit: Int = 60) -> [PlugEvent] {
        memo("events-\(limit)") { fetchEvents(limit: limit) }
    }

    private func fetchEvents(limit: Int) -> [PlugEvent] {
        var descriptor = FetchDescriptor<PlugEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func kWh(from: Date, to: Date) -> Double {
        let a = hourStart(from), b = minute(to)
        return memo("kwh-\(a.timeIntervalSince1970)-\(b.timeIntervalSince1970)") {
            let startDay = calendar.startOfDay(for: a)
            let endDay = calendar.startOfDay(for: b)
            // dias inteiros pelo agregado diário (inclui totais da nuvem); bordas parciais pelas horas
            if calendar.isDate(a, inSameDayAs: b) {
                return hours(from: a, to: b.addingTimeInterval(60)).reduce(0) { $0 + $1.kWh }
            }
            let n = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
            let full = days(from: startDay, count: n).map(\.kWh).reduce(0, +)
            let partial = hours(from: endDay, to: b.addingTimeInterval(60)).reduce(0) { $0 + $1.kWh }
            return full + partial
        }
    }

    var firstRecord: Date? {
        memo("first") {
            var d = FetchDescriptor<DayTotal>(sortBy: [SortDescriptor(\.day)])
            d.fetchLimit = 1
            let t = try? context.fetch(d).first?.day
            let h = fetchFirst()
            return [t, h].compactMap { $0 }.min()
        }
    }

    private func fetchFirst() -> Date? {
        var descriptor = FetchDescriptor<HourStat>(sortBy: [SortDescriptor(\.start)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.start
    }

    // MARK: Importação da nuvem

    /// Incorpora relatórios da nuvem: add_ele → energia/hora, cur_* → leituras e picos, switch_1 → eventos e tempo ligada.
    func importCloud(_ logs: [TuyaCloudClient.Log], covering window: ClosedRange<Date>) {
        let sorted = logs.sorted { $0.event_time < $1.event_time }
        var volts = 0.0, amps = 0.0
        var isOn: Bool?
        var switches: [(Date, Bool)] = []
        var hourCache: [Date: HourStat] = [:]
        func stat(_ d: Date) -> HourStat {
            let h = hourStart(d)
            if let s = hourCache[h] { return s }
            let s = hourStat(h)
            hourCache[h] = s
            return s
        }

        // cobertura: todas as horas da janela
        var h = hourStart(window.lowerBound)
        while h <= window.upperBound {
            stat(h).cloudCovered = true
            h = calendar.date(byAdding: .hour, value: 1, to: h)!
        }

        for log in sorted {
            let d = log.date
            switch log.code {
            case "add_ele":
                stat(d).cloudWh += Double(log.value) ?? 0
            case "cur_voltage":
                volts = (Double(log.value) ?? 0) / 10
                if volts > 50 {
                    let s = stat(d)
                    s.minVolts = min(s.minVolts, volts)
                    s.maxVolts = max(s.maxVolts, volts)
                }
            case "cur_current":
                amps = (Double(log.value) ?? 0) / 1000
                stat(d).peakAmps = max(stat(d).peakAmps, amps)
            case "cur_power":
                let w = (Double(log.value) ?? 0) / 10
                let s = stat(d)
                s.peakWatts = max(s.peakWatts, w)
                let r = Reading(date: d, watts: w, volts: volts, amps: amps, isOn: isOn ?? (w > 0.5))
                r.fromCloud = true
                context.insert(r)
            case "switch_1":
                let on = log.value == "true"
                isOn = on
                switches.append((d, on))
                context.insert(PlugEvent(date: d, kind: on ? .switchedOn : .switchedOff, detail: "Histórico da nuvem"))
            default:
                break
            }
        }

        // tempo ligada: estado inicial = oposto do primeiro evento (ou ligada, se não houve eventos)
        var state = switches.first.map { !$0.1 } ?? true
        var cursor = window.lowerBound
        for (d, on) in switches + [(window.upperBound, state)] where d >= cursor {
            if state { addOnSeconds(from: cursor, to: d, stat: stat) }
            cursor = d
            state = on
        }

        try? context.save()
        currentHour = nil
        revision &+= 1
    }

    private func addOnSeconds(from a: Date, to b: Date, stat: (Date) -> HourStat) {
        var t = a
        while t < b {
            let next = min(calendar.date(byAdding: .hour, value: 1, to: hourStart(t))!, b)
            stat(t).cloudOnSeconds = min(stat(t).cloudOnSeconds + next.timeIntervalSince(t), 3600)
            t = next
        }
    }

    /// Zera os campos vindos da nuvem (para reimportação completa).
    func clearCloud() {
        for h in hours(from: .distantPast, to: .distantFuture) {
            h.cloudWh = 0
            h.cloudOnSeconds = 0
            h.cloudCovered = false
        }
        try? context.delete(model: PlugEvent.self, where: #Predicate { $0.detail == "Histórico da nuvem" })
        try? context.delete(model: Reading.self, where: #Predicate { $0.fromCloud })
        try? context.save()
        revision &+= 1
    }

    // MARK: Exportação

    func exportHourlyCSV() -> URL? {
        let all = hours(from: .distantPast, to: .distantFuture)
        var csv = "inicio_hora;kwh;potencia_media_w;pico_w;tensao_min_v;tensao_max_v;tensao_media_v;ligada_s;cobertura_s\n"
        let iso = ISO8601DateFormatter()
        for h in all {
            csv += [iso.string(from: h.start), String(format: "%.4f", h.kWh), String(format: "%.1f", h.avgWatts),
                    String(format: "%.1f", h.peakWatts),
                    String(format: "%.1f", h.minVolts == .greatestFiniteMagnitude ? 0 : h.minVolts),
                    String(format: "%.1f", h.maxVolts), String(format: "%.1f", h.avgVolts),
                    String(format: "%.0f", h.onSeconds), String(format: "%.0f", h.coveredSeconds)]
                .joined(separator: ";") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tomada-consumo-horario.csv")
        return (try? csv.data(using: .utf8)?.write(to: url)) != nil ? url : nil
    }

    func exportReadingsCSV() -> URL? {
        var csv = "timestamp;potencia_w;tensao_v;corrente_a;ligada\n"
        let iso = ISO8601DateFormatter()
        for r in readings(since: .distantPast) {
            csv += "\(iso.string(from: r.date));\(String(format: "%.1f", r.watts));\(String(format: "%.1f", r.volts));\(String(format: "%.3f", r.amps));\(r.isOn ? 1 : 0)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tomada-leituras.csv")
        return (try? csv.data(using: .utf8)?.write(to: url)) != nil ? url : nil
    }

    // MARK: Dados de demonstração (somente com --demo, banco em memória)

    func seedDemo(days count: Int = 35) {
        let now = Date()
        var rng = SystemRandomNumberGenerator()
        for d in stride(from: count, through: 0, by: -1) {
            let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -d, to: now)!)
            let weekend = calendar.isDateInWeekend(dayStart)
            for h in 0..<24 {
                let start = calendar.date(byAdding: .hour, value: h, to: dayStart)!
                guard start < now else { break }
                let stat = HourStat(start: start)
                let base: Double = 4
                var load = base
                if (7...8).contains(h) { load += Double.random(in: 300...900, using: &rng) }
                if (12...13).contains(h) { load += Double.random(in: 100...400, using: &rng) }
                if (18...22).contains(h) { load += Double.random(in: 250...700, using: &rng) * (weekend ? 1.3 : 1) }
                if (0...5).contains(h) { load += Double.random(in: 0...20, using: &rng) }
                load *= Double.random(in: 0.8...1.2, using: &rng)
                stat.wattHours = load
                stat.coveredSeconds = 3600
                stat.onSeconds = load > 30 ? 3600 : 1800
                stat.peakWatts = load * Double.random(in: 1.4...2.4, using: &rng)
                stat.samples = 240
                stat.sumWatts = load * 240
                let v = Double.random(in: 208...222, using: &rng)
                stat.minVolts = v - Double.random(in: 1...6, using: &rng)
                stat.maxVolts = v + Double.random(in: 1...5, using: &rng)
                stat.sumVolts = v * 240
                stat.peakAmps = stat.peakWatts / v
                context.insert(stat)
            }
        }
        let events: [(Double, PlugEvent.Kind, String)] = [
            (-60, .switchedOn, ""), (-1800, .peak, "1.240 W"), (-7200, .switchedOff, ""),
            (-9000, .connected, "Wi-Fi local"), (-86_400, .overload, "2.310 W > 2.000 W"),
        ]
        for (dt, k, s) in events { context.insert(PlugEvent(date: now.addingTimeInterval(dt), kind: k, detail: s)) }
        try? context.save()
        for i in stride(from: 180, through: 0, by: -1) {
            let t = now.addingTimeInterval(Double(-i) * 5)
            let w = 320 + 140 * sin(Double(i) / 9) + Double.random(in: -25...25, using: &rng)
            live.append(LiveSample(date: t, watts: max(w, 0), volts: 214 + Double.random(in: -2...2, using: &rng),
                                   amps: w / 214, isOn: true))
        }
        revision &+= 1
    }
}
