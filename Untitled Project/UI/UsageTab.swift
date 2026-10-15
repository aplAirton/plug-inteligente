import SwiftUI

struct UsageTab: View {
    let model: PlugViewModel

    var body: some View {
        VoltScreen(title: "Consumo") {
            PeriodCard(model: model)
            CompareCard(model: model)
            HeatmapCard(model: model)
            InsightsCard(model: model)
        }
    }
}

// MARK: - Período (barras)

private struct PeriodCard: View {
    let model: PlugViewModel
    @State private var period: Period = .week
    @State private var selection: Date?

    enum Period: String, CaseIterable {
        case week, month, year
        var label: String {
            switch self {
            case .week: return "7 dias"
            case .month: return "30 dias"
            case .year: return "12 meses"
            }
        }
    }

    var body: some View {
        let _ = model.energy.revision
        let items = bars
        let total = items.reduce(0) { $0 + $1.value }
        let previous = previousTotal
        let nonZero = items.filter { $0.value > 0 }
        let avg = nonZero.isEmpty ? 0 : total / Double(nonZero.count)
        let (tv, tu) = Fmt.energy(total)

        VStack(alignment: .leading, spacing: 14) {
            PillPicker(options: Period.allCases, selection: $period) { $0.label }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total").font(.caption).foregroundStyle(Volt.inkSoft)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(tv).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(tu).font(.subheadline.weight(.semibold)).foregroundStyle(Volt.inkSoft)
                    }
                    .foregroundStyle(Volt.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.money(model.tariff.cost(total)))
                        .font(.headline.monospacedDigit()).foregroundStyle(Volt.money)
                        .contentTransition(.numericText())
                    if previous > 0.001 {
                        let d = (total - previous) / previous
                        Label("\(Fmt.num(abs(d) * 100, 0))% vs anterior", systemImage: d > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(d > 0 ? Volt.fault : Volt.live)
                    }
                }
            }

            BarsChart(items: items, selection: $selection, color: Volt.amber, height: 190,
                      format: { v in let (a, b) = Fmt.energy(v); return "\(a) \(b)" },
                      subtitle: { item in subtitle(item) },
                      target: targetKWh)
                .id(period)

            HStack(spacing: 0) {
                Stat(title: period == .year ? "Média/mês" : "Média/dia", value: { let (a, b) = Fmt.energy(avg); return "\(a) \(b)" }())
                Divider().frame(height: 28)
                Stat(title: "Maior", value: { let (a, b) = Fmt.energy(items.map(\.value).max() ?? 0); return "\(a) \(b)" }())
                Divider().frame(height: 28)
                Stat(title: "Custo médio", value: Fmt.money(model.tariff.cost(avg)))
            }
        }
        .voltCard()
        .onChange(of: period) { selection = nil }
        .animation(.snappy, value: period)
    }

    /// Meta mensal (R$) convertida em kWh por dia ou por mês.
    private var targetKWh: Double? {
        let t = model.tariff
        guard t.monthlyBudget > 0, t.effectivePrice > 0 else { return nil }
        let monthKWh = t.monthlyBudget / t.effectivePrice
        return period == .year ? monthKWh : monthKWh / 30
    }

    private func subtitle(_ item: BarItem) -> String {
        switch period {
        case .year: return item.id.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "pt_BR")))
        default: return "\(Fmt.weekdayShort.string(from: item.id)), \(Fmt.dayMonth.string(from: item.id)) · \(Fmt.money(model.tariff.cost(item.value)))"
        }
    }

    private var bars: [BarItem] {
        switch period {
        case .week, .month:
            let n = period == .week ? 7 : 30
            return model.energy.lastDays(n).map { d in
                BarItem(id: d.day,
                        label: n == 7 ? Fmt.weekdayShort.string(from: d.day).prefix(3).capitalized : "\(Calendar.current.component(.day, from: d.day))",
                        value: d.kWh,
                        isToday: Calendar.current.isDateInToday(d.day))
            }
        case .year:
            let cal = Calendar.current
            let thisMonth = cal.dateInterval(of: .month, for: Date())!.start
            return (0..<12).reversed().map { back in
                let start = cal.date(byAdding: .month, value: -back, to: thisMonth)!
                let end = cal.date(byAdding: .month, value: 1, to: start)!
                let label = start.formatted(.dateTime.month(.narrow).locale(Locale(identifier: "pt_BR")))
                return BarItem(id: start, label: label, value: model.energy.kWh(from: start, to: end), isToday: back == 0)
            }
        }
    }

    /// Total do período anterior, ou 0 se ele tiver menos de 80% de cobertura (comparação seria enganosa).
    private var previousTotal: Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let n: Int
        switch period {
        case .week: n = 7
        case .month: n = 30
        case .year: return 0
        }
        let prev = model.energy.days(from: cal.date(byAdding: .day, value: -(2 * n - 1), to: today)!, count: n)
        let covered = prev.map(\.coveredSeconds).reduce(0, +)
        guard covered >= Double(n) * 86_400 * 0.8 else { return 0 }
        return prev.map(\.kWh).reduce(0, +)
    }
}

// MARK: - Dia × Dia × Média

private struct CompareCard: View {
    let model: PlugViewModel
    @State private var dayA = Calendar.current.startOfDay(for: Date())
    @State private var dayB = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400))
    @State private var cumulative = true
    @State private var editing: Slot = .a

    enum Slot { case a, b }

    var body: some View {
        let _ = model.energy.revision
        let days = model.energy.lastDays(14)
        let a = days.first { $0.day == dayA }
        let b = days.first { $0.day == dayB }
        let past7 = days.filter { !Calendar.current.isDateInToday($0.day) }.suffix(7)
        let avg: [Double] = (0..<24).map { h in
            past7.isEmpty ? 0 : past7.map { $0.hourly[h] }.reduce(0, +) / Double(past7.count)
        }

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Dia × dia × média", icon: "chart.line.uptrend.xyaxis")
                Spacer()
                PillPicker(options: [true, false], selection: $cumulative) { $0 ? "Acumulado" : "Por hora" }
                    .frame(width: 190)
            }

            HStack(spacing: 8) {
                DayBadge(title: label(dayA), color: Volt.arc, kWh: a?.kWh ?? 0, active: editing == .a) { editing = .a }
                DayBadge(title: label(dayB), color: Volt.amber, kWh: b?.kWh ?? 0, active: editing == .b) { editing = .b }
                DayBadge(title: "Média 7d", color: Volt.inkSoft, kWh: avg.reduce(0, +) / 1000, active: false, dashed: true) {}
                if let meta = metaSeries.first {
                    DayBadge(title: "Meta", color: Volt.fault, kWh: meta.values.reduce(0, +) / 1000, active: false, dashed: true) {}
                }
            }

            CompareChart(series: [
                CompareSeries(id: "avg", name: "Média", color: Volt.inkSoft, values: avg, dashed: true),
            ] + metaSeries + [
                series(id: "b", day: dayB, stat: b, color: Volt.amber, avg: avg),
                series(id: "a", day: dayA, stat: a, color: Volt.arc, avg: avg),
            ], cumulative: cumulative)
            .id("\(dayA)\(dayB)")

            if let today = [dayA, dayB].first(where: { Calendar.current.isDateInToday($0) }) {
                let forecast = series(id: "f", day: today, stat: days.first { $0.day == today }, color: Volt.arc, avg: avg)
                    .values.reduce(0, +) / 1000
                HStack(spacing: 6) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 16, y: 1)) }
                        .stroke(Volt.arc, style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                        .frame(width: 16, height: 2)
                    Text("Previsão para hoje: \(Fmt.num(forecast, 2)) kWh · \(Fmt.money(model.tariff.cost(forecast)))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Volt.inkSoft)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(days.reversed()) { d in
                        let isA = d.day == dayA, isB = d.day == dayB
                        Button {
                            withAnimation(.snappy) {
                                if editing == .a { dayA = d.day; editing = .b } else { dayB = d.day; editing = .a }
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text(Fmt.weekdayShort.string(from: d.day).prefix(3).capitalized)
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(Calendar.current.component(.day, from: d.day))")
                                    .font(.subheadline.weight(.bold))
                            }
                            .frame(width: 42, height: 46)
                            .foregroundStyle(isA ? Volt.arc : isB ? Volt.amber : Volt.ink)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isA ? Volt.arc.opacity(0.12) : isB ? Volt.amber.opacity(0.14) : Volt.surfaceRaised)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isA ? Volt.arc : isB ? Volt.amber : Volt.stroke, lineWidth: isA || isB ? 1.5 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .sensoryFeedback(.selection, trigger: dayA)
            .sensoryFeedback(.selection, trigger: dayB)

            Text("Toque em \(editing == .a ? "azul" : "âmbar") e escolha um dia. Arraste no gráfico para comparar hora a hora.")
                .font(.caption2).foregroundStyle(Volt.inkFaint)
        }
        .voltCard()
    }

    /// Meta diária derivada da meta mensal, distribuída igualmente pelas 24 h.
    private var metaSeries: [CompareSeries] {
        let t = model.tariff
        guard t.monthlyBudget > 0, t.effectivePrice > 0 else { return [] }
        let dayWh = t.monthlyBudget / 30 / t.effectivePrice * 1000
        return [CompareSeries(id: "meta", name: "Meta", color: Volt.fault, values: Array(repeating: dayWh / 24, count: 24), dashed: true)]
    }

    /// Para o dia atual: horas passadas reais; hora corrente completada pela média proporcional; restante = média (previsão).
    private func series(id: String, day: Date, stat: DayStat?, color: Color, avg: [Double]) -> CompareSeries {
        var values = stat?.hourly ?? Array(repeating: 0, count: 24)
        guard Calendar.current.isDateInToday(day) else {
            return CompareSeries(id: id, name: label(day), color: color, values: values)
        }
        let now = Date()
        let h = Calendar.current.component(.hour, from: now)
        let frac = Double(Calendar.current.component(.minute, from: now)) / 60
        values[h] += avg[h] * (1 - frac)
        for i in (h + 1)..<24 { values[i] = avg[i] }
        return CompareSeries(id: id, name: label(day), color: color, values: values, cutoff: max(h - 1, 0))
    }

    private func label(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Hoje" }
        if Calendar.current.isDateInYesterday(d) { return "Ontem" }
        return "\(Fmt.weekdayShort.string(from: d).prefix(3).capitalized) \(Calendar.current.component(.day, from: d))"
    }
}

private struct DayBadge: View {
    let title: String
    let color: Color
    let kWh: Double
    let active: Bool
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Capsule().fill(color).frame(width: 12, height: 3)
                        .overlay { if dashed { Capsule().stroke(Volt.surface, style: StrokeStyle(lineWidth: 1, dash: [2, 2])) } }
                    Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Volt.inkSoft).lineLimit(1)
                }
                let (v, u) = Fmt.energy(kWh)
                Text("\(v) \(u)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Volt.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Volt.surfaceRaised))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? color : Volt.stroke, lineWidth: active ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mapa de calor

private struct HeatmapCard: View {
    let model: PlugViewModel

    var body: some View {
        let _ = model.energy.revision
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Mapa de calor · 7 dias", icon: "square.grid.3x3.fill")
            HeatmapChart(days: model.energy.lastDays(7))
        }
        .voltCard()
    }
}

// MARK: - Insights

private struct InsightsCard: View {
    let model: PlugViewModel

    var body: some View {
        let _ = model.energy.revision
        let days = model.energy.lastDays(28).filter { $0.coveredSeconds > 3600 }
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Descobertas", icon: "sparkles")
            if days.isEmpty {
                Text("Os padrões de uso aparecem aqui depois de algumas horas de coleta.")
                    .font(.footnote).foregroundStyle(Volt.inkSoft)
            } else {
                ForEach(insights(days), id: \.title) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: i.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(i.color)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(i.color.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).font(.subheadline.weight(.semibold)).foregroundStyle(Volt.ink)
                            Text(i.detail).font(.caption).foregroundStyle(Volt.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .voltCard()
    }

    struct Insight {
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private func insights(_ days: [DayStat]) -> [Insight] {
        var out: [Insight] = []
        // hora de pico média
        let hourAvg = (0..<24).map { h in days.map { $0.hourly[h] }.reduce(0, +) / Double(days.count) }
        if let peakH = hourAvg.indices.max(by: { hourAvg[$0] < hourAvg[$1] }), hourAvg[peakH] > 0 {
            out.append(Insight(icon: "clock.fill", color: Volt.arc,
                               title: "Horário de maior uso: \(peakH)h–\(peakH + 1)h",
                               detail: "Em média \(Fmt.num(hourAvg[peakH], 0)) Wh nessa hora — \(Fmt.money(model.tariff.cost(hourAvg[peakH] / 1000))) por dia."))
        }
        // dia da semana mais intenso
        var byWeekday: [Int: [Double]] = [:]
        for d in days { byWeekday[Calendar.current.component(.weekday, from: d.day), default: []].append(d.kWh) }
        let wdAvg = byWeekday.mapValues { $0.reduce(0, +) / Double($0.count) }
        if wdAvg.count >= 3, let top = wdAvg.max(by: { $0.value < $1.value }) {
            var ptCal = Calendar.current
            ptCal.locale = Locale(identifier: "pt_BR")
            let name = ptCal.weekdaySymbols[top.key - 1]
            let (v, u) = Fmt.energy(top.value)
            out.append(Insight(icon: "calendar", color: Volt.violet,
                               title: "\(name.prefix(1).uppercased() + name.dropFirst()) é o dia mais intenso",
                               detail: "Média de \(v) \(u) nesse dia da semana."))
        }
        // consumo de base (standby) — madrugada
        let night = (1...5).map { hourAvg[$0] }
        let base = night.min() ?? 0
        if base > 0.2 {
            let monthly = base * 24 * 30 / 1000
            out.append(Insight(icon: "moon.zzz.fill", color: Volt.amber,
                               title: "Consumo de base ≈ \(Fmt.num(base, 1)) W",
                               detail: "Mesmo ocioso, isso soma ~\(Fmt.num(monthly, 1)) kWh/mês (\(Fmt.money(model.tariff.cost(monthly)))). Desligar à noite economiza."))
        }
        // tendência
        if days.count >= 14 {
            let recent = days.suffix(7).map(\.kWh).reduce(0, +)
            let before = days.dropLast(7).suffix(7).map(\.kWh).reduce(0, +)
            if before > 0.01 {
                let d = (recent - before) / before
                out.append(Insight(icon: d > 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                                   color: d > 0 ? Volt.fault : Volt.live,
                                   title: d > 0 ? "Consumo subindo \(Fmt.num(d * 100, 0))%" : "Consumo caiu \(Fmt.num(-d * 100, 0))%",
                                   detail: "Últimos 7 dias comparados aos 7 anteriores."))
            }
        }
        // CO2
        let total = days.map(\.kWh).reduce(0, +)
        out.append(Insight(icon: "leaf.fill", color: Volt.live,
                           title: "\(Fmt.num(total * model.tariff.co2PerKWh, 2)) kg de CO₂",
                           detail: "Estimativa das emissões do período medido (fator médio da rede brasileira)."))
        return out
    }
}
