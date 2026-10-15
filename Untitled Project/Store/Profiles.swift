import Foundation
import SwiftUI

/// Um horário dentro de um perfil: às HH:mm, liga ou desliga.
struct ScheduleEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    var minutes: Int          // minutos desde 00:00
    var turnOn: Bool

    var timeString: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    var date: Date {
        get { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())! }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}

/// Perfil de uso: dias da semana + sequência de liga/desliga. Executado pela nuvem Tuya.
struct UsageProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var icon: String
    var colorIndex: Int
    /// Domingo = 0 … sábado = 6.
    var days: Set<Int>
    var events: [ScheduleEvent]
    var isActive = false
    /// Agendamento simples (uma ação). Opcionais para manter compatibilidade com perfis já salvos.
    var isSimple: Bool? = nil
    /// Sem dias de repetição: executa uma vez nesta data.
    var onceDate: Date? = nil

    var simple: Bool { isSimple ?? false }
    var repeats: Bool { !days.isEmpty }

    /// Categoria usada na nuvem (curta, só [a-z0-9]).
    var cloudCategory: String { "p" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }

    var loops: String { (0..<7).map { days.contains($0) ? "1" : "0" }.joined() }

    var sortedEvents: [ScheduleEvent] { events.sorted { $0.minutes < $1.minutes } }

    static let palette: [Color] = [Volt.arc, Volt.amber, Volt.violet, Volt.live, Volt.fault, Volt.money]
    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    var daysSummary: String {
        if days.isEmpty {
            guard let d = onceDate else { return "Uma vez" }
            if Calendar.current.isDateInToday(d) { return "Hoje" }
            if Calendar.current.isDateInTomorrow(d) { return "Amanhã" }
            return "Em " + Fmt.dayMonth.string(from: d)
        }
        if days.count == 7 { return "Todos os dias" }
        if days == [1, 2, 3, 4, 5] { return "Dias úteis" }
        if days == [0, 6] { return "Fim de semana" }
        let names = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
        return days.sorted().map { names[$0] }.joined(separator: ", ")
    }

    /// Estado previsto em cada minuto do dia (nil = perfil não define; mantém o anterior).
    func state(atMinute m: Int) -> Bool? {
        let evs = sortedEvents
        guard !evs.isEmpty else { return nil }
        if let last = evs.last(where: { $0.minutes <= m }) { return last.turnOn }
        return evs.last!.turnOn   // vem do dia anterior
    }

    /// Minutos desligada por dia, segundo o perfil.
    var offMinutesPerDay: Int {
        guard !events.isEmpty else { return 0 }
        return (0..<1440).filter { state(atMinute: $0) == false }.count
    }

    static let templates: [UsageProfile] = [
        UsageProfile(name: "Noite econômica", icon: "moon.stars.fill", colorIndex: 2, days: Set(0...6),
                     events: [ScheduleEvent(minutes: 23 * 60, turnOn: false), ScheduleEvent(minutes: 6 * 60, turnOn: true)]),
        UsageProfile(name: "Horário comercial", icon: "briefcase.fill", colorIndex: 0, days: [1, 2, 3, 4, 5],
                     events: [ScheduleEvent(minutes: 8 * 60, turnOn: true), ScheduleEvent(minutes: 18 * 60, turnOn: false)]),
        UsageProfile(name: "Fim de semana", icon: "sun.max.fill", colorIndex: 1, days: [0, 6],
                     events: [ScheduleEvent(minutes: 9 * 60, turnOn: true), ScheduleEvent(minutes: 22 * 60, turnOn: false)]),
        UsageProfile(name: "Pico tarifário", icon: "bolt.slash.fill", colorIndex: 4, days: [1, 2, 3, 4, 5],
                     events: [ScheduleEvent(minutes: 18 * 60, turnOn: false), ScheduleEvent(minutes: 21 * 60, turnOn: true)]),
    ]
}

@Observable
final class ProfileStore {
    private(set) var profiles: [UsageProfile] = []
    var syncing: Set<UUID> = []
    var lastError: String?

    private let key = "profiles.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([UsageProfile].self, from: data) {
            profiles = list
        }
        if PlugViewModel.isDemo && profiles.isEmpty {
            profiles = UsageProfile.templates.prefix(2).map { var p = $0; p.isActive = true; return p }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: key) }
    }

    var active: [UsageProfile] { profiles.filter(\.isActive) }

    /// Estado previsto hoje a cada minuto, combinando perfis ativos que valem para hoje.
    func todayPlan(_ date: Date = .now) -> [Bool?] {
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let today = active.filter {
            $0.days.contains(weekday) || ($0.days.isEmpty && $0.onceDate.map { Calendar.current.isDate($0, inSameDayAs: date) } == true)
        }
        guard !today.isEmpty else { return Array(repeating: nil, count: 1440) }
        let events = today.flatMap(\.events).sorted { $0.minutes < $1.minutes }
        return (0..<1440).map { m in
            if let last = events.last(where: { $0.minutes <= m }) { return last.turnOn }
            return events.last?.turnOn
        }
    }

    /// Próxima ação agendada (até 7 dias à frente).
    func nextAction(from now: Date = .now) -> (Date, Bool, UsageProfile)? {
        let cal = Calendar.current
        for dayOffset in 0..<8 {
            let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
            let weekday = cal.component(.weekday, from: day) - 1
            let candidates = active.filter { $0.days.contains(weekday) || ($0.days.isEmpty && $0.onceDate.map { cal.isDate($0, inSameDayAs: day) } == true) }
                .flatMap { p in p.events.map { (cal.date(byAdding: .minute, value: $0.minutes, to: day)!, $0.turnOn, p) } }
                .filter { $0.0 > now }
                .sorted { $0.0 < $1.0 }
            if let first = candidates.first { return first }
        }
        return nil
    }

    func upsert(_ profile: UsageProfile, cloud: CloudSync) async {
        let wasActive = profiles.first { $0.id == profile.id }?.isActive ?? false
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        persist()
        if profile.isActive || wasActive {
            await push(profile, cloud: cloud)
        }
    }

    func setActive(_ id: UUID, _ active: Bool, cloud: CloudSync) async {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].isActive = active
        persist()
        await push(profiles[i], cloud: cloud)
    }

    func delete(_ id: UUID, cloud: CloudSync) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        persist()
        if p.isActive {
            var off = p
            off.isActive = false
            await push(off, cloud: cloud)
        }
    }

    /// Reflete o perfil na nuvem: remove a categoria e, se ativo, recria os timers.
    private func push(_ profile: UsageProfile, cloud: CloudSync) async {
        guard cloud.isConfigured else {
            lastError = "Configure a nuvem Tuya em Ajustes para os agendamentos funcionarem com o app fechado."
            return
        }
        syncing.insert(profile.id)
        defer { syncing.remove(profile.id) }
        let client = cloud.client
        do {
            try? await client.deleteTimers(device: cloud.deviceID, category: profile.cloudCategory)
            if profile.isActive, !profile.events.isEmpty, profile.repeats || profile.onceDate != nil {
                // Recorrente: a nuvem exige data vazia (com data retorna erro 501). Única: data yyyyMMdd.
                let day: String
                if profile.repeats {
                    day = ""
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "yyyyMMdd"
                    day = f.string(from: profile.onceDate!)
                }
                let instructs = profile.sortedEvents.map {
                    TuyaCloudClient.TimerInstruct(functions: [.init(code: "switch_1", value: $0.turnOn)],
                                                  date: day, time: $0.timeString)
                }
                try await client.createTimers(device: cloud.deviceID, category: profile.cloudCategory,
                                              loops: profile.loops, instructs: instructs)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if let i = profiles.firstIndex(where: { $0.id == profile.id }), profile.isActive {
                profiles[i].isActive = false
                persist()
            }
        }
    }
}
