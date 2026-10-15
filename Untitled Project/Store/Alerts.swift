import Foundation
import UserNotifications

/// Gatilhos de notificação e seus parâmetros (UserDefaults).
@Observable
final class AlertSettings {
    enum Trigger: String, CaseIterable, Identifiable {
        case sustainedHigh, instantPeak, voltage, forgottenOn, standby, budget80, budget100, projection, unusualDay
        case switched, scheduleRan, offline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sustainedHigh: return "Consumo alto prolongado"
            case .instantPeak: return "Pico acima do limite"
            case .voltage: return "Tensão fora da faixa"
            case .forgottenOn: return "Esquecida ligada"
            case .standby: return "Standby prolongado"
            case .budget80: return "80% da meta atingidos"
            case .budget100: return "Meta estourada"
            case .projection: return "Projeção acima da meta"
            case .unusualDay: return "Dia acima do normal"
            case .switched: return "Ligou / desligou"
            case .scheduleRan: return "Agendamento executado"
            case .offline: return "Tomada offline"
            }
        }

        var icon: String {
            switch self {
            case .sustainedHigh: return "flame.fill"
            case .instantPeak: return "bolt.fill"
            case .voltage: return "waveform.path.ecg"
            case .forgottenOn: return "hourglass"
            case .standby: return "moon.zzz.fill"
            case .budget80, .budget100: return "brazilianrealsign.circle.fill"
            case .projection: return "chart.line.uptrend.xyaxis"
            case .unusualDay: return "calendar.badge.exclamationmark"
            case .switched: return "power"
            case .scheduleRan: return "clock.badge.checkmark.fill"
            case .offline: return "wifi.slash"
            }
        }

        var defaultOn: Bool {
            switch self {
            case .switched, .standby: return false
            default: return true
            }
        }

        /// Intervalo mínimo entre dois avisos do mesmo tipo.
        var cooldown: TimeInterval {
            switch self {
            case .sustainedHigh, .forgottenOn, .standby: return 3 * 3600
            case .instantPeak, .voltage, .offline: return 1800
            case .budget80, .budget100, .projection: return 7 * 86_400
            case .unusualDay: return 20 * 3600
            case .switched, .scheduleRan: return 0
            }
        }
    }

    private let d = UserDefaults.standard

    var enabled: [Trigger: Bool] {
        didSet { d.set(Dictionary(uniqueKeysWithValues: enabled.map { ($0.key.rawValue, $0.value) }), forKey: "alerts.enabled") }
    }
    var sustainedWatts: Double { didSet { d.set(sustainedWatts, forKey: "alerts.sustainedW") } }
    var sustainedMinutes: Double { didSet { d.set(sustainedMinutes, forKey: "alerts.sustainedMin") } }
    var forgottenHours: Double { didSet { d.set(forgottenHours, forKey: "alerts.forgottenH") } }
    var standbyWatts: Double { didSet { d.set(standbyWatts, forKey: "alerts.standbyW") } }
    var unusualFactor: Double { didSet { d.set(unusualFactor, forKey: "alerts.unusual") } }

    init() {
        let stored = d.dictionary(forKey: "alerts.enabled") as? [String: Bool] ?? [:]
        enabled = Dictionary(uniqueKeysWithValues: Trigger.allCases.map { ($0, stored[$0.rawValue] ?? $0.defaultOn) })
        sustainedWatts = d.object(forKey: "alerts.sustainedW") as? Double ?? 800
        sustainedMinutes = d.object(forKey: "alerts.sustainedMin") as? Double ?? 60
        forgottenHours = d.object(forKey: "alerts.forgottenH") as? Double ?? 6
        standbyWatts = d.object(forKey: "alerts.standbyW") as? Double ?? 5
        unusualFactor = d.object(forKey: "alerts.unusual") as? Double ?? 1.5
    }

    func isOn(_ t: Trigger) -> Bool { enabled[t] ?? t.defaultOn }
}

/// Envia notificações locais e lembra quando cada gatilho disparou.
enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(_ trigger: AlertSettings.Trigger, title: String, body: String, force: Bool = false) {
        let key = "alerts.last.\(trigger.rawValue)"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= trigger.cooldown else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = trigger.rawValue
        let req = UNNotificationRequest(identifier: "\(trigger.rawValue)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// "Armado" de novo quando a condição deixa de valer (ex.: consumo voltou ao normal).
    static func rearm(_ trigger: AlertSettings.Trigger) {
        UserDefaults.standard.removeObject(forKey: "alerts.last.\(trigger.rawValue)")
    }
}

/// Mostra notificações também com o app aberto.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Avalia os gatilhos a partir do banco (funciona com dados locais ou importados da nuvem).
@MainActor
enum AlertEngine {
    static func evaluate(model: PlugViewModel, now: Date = .now) {
        let s = model.alerts
        let store = model.energy
        let tariff = model.tariff
        let name = tariff.deviceName
        let readings = store.readings(since: now.addingTimeInterval(-max(s.forgottenHours, 3) * 3600 - 1800))
        let live = store.live.map { (date: $0.date, watts: $0.watts, volts: $0.volts, isOn: $0.isOn) }
        // série combinada (banco + ao vivo), ordenada
        let series = (readings.map { (date: $0.date, watts: $0.watts, volts: $0.volts, isOn: $0.isOn) } + live)
            .sorted { $0.date < $1.date }

        /// Valor mínimo de potência ao longo da janela [now - minutes, now], considerando o valor vigente no início.
        func minWatts(overMinutes minutes: Double) -> Double? {
            let start = now.addingTimeInterval(-minutes * 60)
            guard let atStart = series.last(where: { $0.date <= start }) else { return nil }
            let inside = series.filter { $0.date > start }
            return ([atStart] + inside).map(\.watts).min()
        }
        func maxWatts(overMinutes minutes: Double) -> Double? {
            let start = now.addingTimeInterval(-minutes * 60)
            guard let atStart = series.last(where: { $0.date <= start }) else { return nil }
            return ([atStart] + series.filter { $0.date > start }).map(\.watts).max()
        }

        // Consumo alto prolongado
        if s.isOn(.sustainedHigh) {
            if let m = minWatts(overMinutes: s.sustainedMinutes), m > s.sustainedWatts {
                Notifier.post(.sustainedHigh, title: "Consumo alto há \(Fmt.duration(s.sustainedMinutes * 60))",
                              body: "\(name) está acima de \(Fmt.num(s.sustainedWatts, 0)) W sem parar (agora \(Fmt.num(series.last?.watts ?? m, 0)) W, \(Fmt.money(tariff.cost((series.last?.watts ?? m) / 1000)))/h).")
            } else if let last = series.last, last.watts < s.sustainedWatts * 0.8 {
                Notifier.rearm(.sustainedHigh)
            }
        }

        // Pico instantâneo
        if s.isOn(.instantPeak), let last = series.last, now.timeIntervalSince(last.date) < 600, last.watts > tariff.alertWatts {
            Notifier.post(.instantPeak, title: "Pico de \(Fmt.num(last.watts, 0)) W",
                          body: "\(name) passou do limite de \(Fmt.num(tariff.alertWatts, 0)) W.")
        }

        // Tensão
        if s.isOn(.voltage), let last = series.last(where: { $0.volts > 50 }), now.timeIntervalSince(last.date) < 900,
           last.volts < tariff.voltageMin || last.volts > tariff.voltageMax {
            Notifier.post(.voltage, title: "Tensão \(last.volts < tariff.voltageMin ? "baixa" : "alta"): \(Fmt.num(last.volts)) V",
                          body: "Fora da faixa \(Fmt.num(tariff.voltageMin, 0))–\(Fmt.num(tariff.voltageMax, 0)) V. Aparelhos sensíveis podem sofrer.")
        }

        // Esquecida ligada (consumindo > 10 W há N horas)
        if s.isOn(.forgottenOn) {
            if let m = minWatts(overMinutes: s.forgottenHours * 60), m > 10 {
                Notifier.post(.forgottenOn, title: "\(name) ligada há \(Fmt.num(s.forgottenHours, 0)) h",
                              body: "Consumindo sem pausa desde \(Fmt.hourMinute.string(from: now.addingTimeInterval(-s.forgottenHours * 3600))). Foi intencional?")
            } else if let last = series.last, last.watts < 5 {
                Notifier.rearm(.forgottenOn)
            }
        }

        // Standby prolongado (ligada, mas consumindo pouco por 2 h)
        if s.isOn(.standby), let hi = maxWatts(overMinutes: 120), hi > 0.3, hi < s.standbyWatts {
            Notifier.post(.standby, title: "Em standby há 2 h",
                          body: "\(name) consome só \(Fmt.num(hi, 1)) W. Desligar economiza ~\(Fmt.money(tariff.cost(hi * 24 * 30 / 1000)))/mês.")
        }

        // Meta / projeção
        let budget = tariff.monthlyBudget
        if budget > 0 {
            let start = tariff.cycleStart()
            let spent = tariff.cost(store.kWh(from: start, to: now))
            let key = "alerts.cycle.\(Int(start.timeIntervalSince1970))"
            var fired = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            func once(_ t: AlertSettings.Trigger, _ title: String, _ body: String) {
                guard s.isOn(t), !fired.contains(t.rawValue) else { return }
                fired.insert(t.rawValue)
                UserDefaults.standard.set(Array(fired), forKey: key)
                Notifier.post(t, title: title, body: body, force: true)
            }
            if spent >= budget {
                once(.budget100, "Meta mensal estourada", "\(name) já gastou \(Fmt.money(spent)) neste ciclo (meta \(Fmt.money(budget))).")
            } else if spent >= budget * 0.8 {
                once(.budget80, "80% da meta usados", "\(Fmt.money(spent)) de \(Fmt.money(budget)) neste ciclo.")
            }
            let elapsed = max(now.timeIntervalSince(start) / 86_400, 0.5)
            let total = tariff.cycleEnd().timeIntervalSince(start) / 86_400
            if elapsed >= 3 {
                let projected = spent / elapsed * total
                if projected > budget * 1.05 {
                    once(.projection, "Projeção acima da meta",
                         "No ritmo atual o ciclo fecha em \(Fmt.money(projected)) — \(Fmt.money(projected - budget)) acima da meta.")
                }
            }
        }

        // Dia atípico (após 18h, hoje > fator × média dos 7 dias anteriores)
        if s.isOn(.unusualDay), Calendar.current.component(.hour, from: now) >= 18 {
            let prev = store.lastDays(8).dropLast().filter { $0.coveredSeconds > 12 * 3600 }
            let today = store.day(now).kWh
            if prev.count >= 4 {
                let avg = prev.map(\.kWh).reduce(0, +) / Double(prev.count)
                if avg > 0.05, today > avg * s.unusualFactor {
                    Notifier.post(.unusualDay, title: "Hoje acima do normal",
                                  body: "\(Fmt.num(today, 2)) kWh até agora — \(Fmt.num((today / avg - 1) * 100, 0))% acima da média diária (\(Fmt.num(avg, 2)) kWh).")
                }
            }
        }
    }

    /// Mudança de estado do relé (chamado pelo modelo quando o DP 1 muda).
    static func switched(model: PlugViewModel, on: Bool, at date: Date = .now) {
        let s = model.alerts
        let name = model.tariff.deviceName
        // agendamento executado: mudança até 3 min de um horário de perfil ativo com a mesma ação
        let cal = Calendar.current
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let weekday = cal.component(.weekday, from: date) - 1
        let match = model.profiles.active.first { p in
            (p.days.contains(weekday) || p.days.isEmpty) && p.events.contains { $0.turnOn == on && abs($0.minutes - minute) <= 3 }
        }
        if let match, s.isOn(.scheduleRan) {
            Notifier.post(.scheduleRan, title: "\(name) \(on ? "ligada" : "desligada")", body: "Agendamento \"\(match.name)\" executado às \(Fmt.hourMinute.string(from: date)).")
        } else if s.isOn(.switched) {
            Notifier.post(.switched, title: "\(name) \(on ? "ligada" : "desligada")", body: "Às \(Fmt.hourMinute.string(from: date)).")
        }
    }

    static func offline(model: PlugViewModel) {
        guard model.alerts.isOn(.offline) else { return }
        Notifier.post(.offline, title: "\(model.tariff.deviceName) offline",
                      body: "Perdi a conexão com a tomada pela rede local. Ela pode ter ficado sem energia ou Wi-Fi.")
    }
}
