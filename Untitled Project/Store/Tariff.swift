import Foundation

/// Bandeiras tarifárias ANEEL (adicional por kWh, valores vigentes 2025).
enum TariffFlag: String, CaseIterable, Identifiable {
    case verde, amarela, vermelha1, vermelha2

    var id: String { rawValue }

    var label: String {
        switch self {
        case .verde: return "Verde"
        case .amarela: return "Amarela"
        case .vermelha1: return "Vermelha 1"
        case .vermelha2: return "Vermelha 2"
        }
    }

    /// R$ por kWh.
    var surcharge: Double {
        switch self {
        case .verde: return 0
        case .amarela: return 0.01885
        case .vermelha1: return 0.04463
        case .vermelha2: return 0.07877
        }
    }
}

/// Configurações persistidas em UserDefaults.
@Observable
final class TariffSettings {
    private let d = UserDefaults.standard

    var pricePerKWh: Double { didSet { d.set(pricePerKWh, forKey: "tariff.price") } }
    var includesTaxes: Bool { didSet { d.set(includesTaxes, forKey: "tariff.taxesIncluded") } }
    var taxPercent: Double { didSet { d.set(taxPercent, forKey: "tariff.taxes") } }
    var flag: TariffFlag { didSet { d.set(flag.rawValue, forKey: "tariff.flag") } }
    var billingDay: Int { didSet { d.set(billingDay, forKey: "tariff.billingDay") } }
    var monthlyBudget: Double { didSet { d.set(monthlyBudget, forKey: "tariff.budget") } }
    var alertWatts: Double { didSet { d.set(alertWatts, forKey: "alert.watts") } }
    var voltageMin: Double { didSet { d.set(voltageMin, forKey: "alert.vmin") } }
    var voltageMax: Double { didSet { d.set(voltageMax, forKey: "alert.vmax") } }
    var deviceName: String { didSet { d.set(deviceName, forKey: "device.name") } }
    var applianceIcon: String { didSet { d.set(applianceIcon, forKey: "device.icon") } }

    /// Fator de emissão do SIN (kg CO₂/kWh, média MCTI recente) — estimativa.
    let co2PerKWh = 0.0385

    init() {
        pricePerKWh = d.object(forKey: "tariff.price") as? Double ?? 0.85
        includesTaxes = d.object(forKey: "tariff.taxesIncluded") as? Bool ?? false
        taxPercent = d.object(forKey: "tariff.taxes") as? Double ?? 27
        flag = TariffFlag(rawValue: d.string(forKey: "tariff.flag") ?? "") ?? .verde
        billingDay = d.object(forKey: "tariff.billingDay") as? Int ?? 1
        monthlyBudget = d.object(forKey: "tariff.budget") as? Double ?? 60
        alertWatts = d.object(forKey: "alert.watts") as? Double ?? 3000
        voltageMin = d.object(forKey: "alert.vmin") as? Double ?? 202
        voltageMax = d.object(forKey: "alert.vmax") as? Double ?? 231
        deviceName = d.string(forKey: "device.name") ?? "Tomada"
        applianceIcon = d.string(forKey: "device.icon") ?? "powerplug.fill"
    }

    /// Preço final por kWh (tarifa + bandeira, com tributos).
    var effectivePrice: Double {
        let base = pricePerKWh + flag.surcharge
        return includesTaxes ? base : base * (1 + taxPercent / 100)
    }

    func cost(_ kWh: Double) -> Double { kWh * effectivePrice }

    /// Início do ciclo de faturamento que contém `date`.
    func cycleStart(containing date: Date = .now) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: date)
        comps.day = min(billingDay, 28)
        let candidate = cal.date(from: comps)!
        return candidate <= date ? candidate : cal.date(byAdding: .month, value: -1, to: candidate)!
    }

    func cycleEnd(containing date: Date = .now) -> Date {
        Calendar.current.date(byAdding: .month, value: 1, to: cycleStart(containing: date))!
    }
}
