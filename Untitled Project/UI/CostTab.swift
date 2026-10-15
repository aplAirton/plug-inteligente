import SwiftUI

struct CostTab: View {
    let model: PlugViewModel
    @State private var editingTariff = false

    var body: some View {
        VoltScreen(title: "Custos") {
            CycleHero(model: model)
            PaceSection(model: model)
            BudgetSection(model: model)
            PeriodCostSection(model: model)
            DaypartSection(model: model)
            SimulatorSection(model: model)
            TariffSection(model: model) { editingTariff = true }
        }
        .sheet(isPresented: $editingTariff) {
            NavigationStack { TariffEditor(tariff: model.tariff) }
        }
    }
}

// MARK: - Dados do ciclo

private struct CycleData {
    let start: Date
    let end: Date
    let days: [DayStat]            // do início do ciclo até hoje
    let cumulative: [Double]       // R$ acumulado por dia
    let spent: Double
    let projected: Double
    let totalDays: Int
    let elapsedDays: Double

    init(model: PlugViewModel) {
        let t = model.tariff
        let cal = Calendar.current
        start = t.cycleStart()
        end = t.cycleEnd()
        totalDays = cal.dateComponents([.day], from: start, to: end).day ?? 30
        let todayIndex = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: Date())).day ?? 0
        days = model.energy.days(from: start, count: todayIndex + 1)
        var acc = 0.0
        cumulative = days.map { acc += t.cost($0.kWh); return acc }
        spent = acc
        elapsedDays = max(Date().timeIntervalSince(start) / 86_400, 0.25)
        // ritmo: média dos últimos 7 dias completos com dados; senão, média do ciclo
        let recent = model.energy.lastDays(8).dropLast().filter { $0.coveredSeconds > 6 * 3600 }
        let daily = recent.count >= 3 ? t.cost(recent.map(\.kWh).reduce(0, +) / Double(recent.count)) : spent / elapsedDays
        projected = spent + daily * max(Double(totalDays) - elapsedDays, 0)
    }
}

// MARK: - Herói: ciclo atual

private struct CycleHero: View {
    let model: PlugViewModel
    @State private var scrubDay: Int?

    var body: some View {
        let _ = model.energy.revision
        let c = CycleData(model: model)
        let budget = model.tariff.monthlyBudget
        let shownDay = scrubDay.map { min($0, c.cumulative.count - 1) }
        let shownValue = shownDay.map { c.cumulative[$0] } ?? c.spent

        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Ciclo \(Fmt.dayMonth.string(from: c.start)) – \(Fmt.dayMonth.string(from: c.end))")
            VStack(alignment: .leading, spacing: 2) {
                Text(shownDay.map { "Até \(Fmt.dayMonth.string(from: c.days[$0].day))" } ?? "Gasto até agora")
                    .font(.subheadline).foregroundStyle(Volt.inkSoft)
                    .contentTransition(.interpolate)
                Text(Fmt.money(shownValue))
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Volt.ink)
                    .contentTransition(.numericText(value: shownValue))
                HStack(spacing: 6) {
                    Text("Projeção")
                    Text(Fmt.money(c.projected)).fontWeight(.bold)
                        .foregroundStyle(budget > 0 && c.projected > budget ? Volt.fault : Volt.money)
                    if budget > 0 {
                        Text("· meta \(Fmt.money(budget))")
                    }
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Volt.inkSoft)
            }

            CycleTrack(cycle: c, budget: budget, scrubDay: $scrubDay)
        }
        .voltCard()
        .animation(.snappy, value: scrubDay)
    }
}

/// Trilho horizontal do ciclo: gasto (sólido), projeção (claro), meta (marca). Arraste para ver dia a dia.
private struct CycleTrack: View {
    let cycle: CycleData
    let budget: Double
    @Binding var scrubDay: Int?

    var body: some View {
        let scale = max(cycle.projected, budget, cycle.spent, 0.01) * 1.05
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let spentX = w * cycle.spent / scale
                let projX = w * cycle.projected / scale
                let budgetX = w * budget / scale
                ZStack(alignment: .leading) {
                    Capsule().fill(Volt.grid)
                    Capsule().fill(Volt.money.opacity(0.25)).frame(width: projX)
                    Capsule()
                        .fill(budget > 0 && cycle.projected > budget ? Volt.fault : Volt.money)
                        .frame(width: max(spentX, 6))
                    if budget > 0 {
                        Rectangle().fill(Volt.ink).frame(width: 2, height: 30).offset(x: budgetX - 1)
                    }
                    if let d = scrubDay, d < cycle.cumulative.count {
                        let x = w * cycle.cumulative[d] / scale
                        Circle().fill(Volt.ink).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Volt.canvas, lineWidth: 3))
                            .offset(x: x - 7)
                    }
                }
                .frame(height: 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let frac = min(max(v.location.x / w, 0), 1)
                            scrubDay = Int((frac * Double(cycle.cumulative.count - 1)).rounded())
                        }
                        .onEnded { _ in scrubDay = nil }
                )
            }
            .frame(height: 30)
            .sensoryFeedback(.selection, trigger: scrubDay)

            HStack {
                legend(color: budget > 0 && cycle.projected > budget ? Volt.fault : Volt.money, "Gasto")
                legend(color: Volt.money.opacity(0.35), "Projeção")
                if budget > 0 { legend(color: Volt.ink, "Meta") }
                Spacer()
                Text("dia \(Int(cycle.elapsedDays.rounded(.up))) de \(cycle.totalDays)")
            }
            .font(.caption2)
            .foregroundStyle(Volt.inkSoft)
        }
    }

    private func legend(color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(text)
        }
    }
}

// MARK: - Ritmo do ciclo (acumulado × ritmo ideal)

private struct PaceSection: View {
    let model: PlugViewModel
    @State private var scrub: Int?
    @State private var drawn: CGFloat = 0

    var body: some View {
        let _ = model.energy.revision
        let c = CycleData(model: model)
        let budget = model.tariff.monthlyBudget
        let n = c.totalDays
        let hi = ChartMath.niceCeil(max(c.projected, budget, c.spent, 0.01) * 1.05)

        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Ritmo do ciclo")
            if let s = scrub, s < c.cumulative.count {
                let ideal = budget * Double(s + 1) / Double(n)
                HStack {
                    Text(Fmt.dayMonth.string(from: c.days[s].day)).foregroundStyle(Volt.inkSoft)
                    Spacer()
                    Text(Fmt.money(c.cumulative[s])).fontWeight(.bold).foregroundStyle(Volt.ink)
                    if budget > 0 {
                        Text(c.cumulative[s] > ideal ? "acima do ritmo" : "abaixo do ritmo")
                            .foregroundStyle(c.cumulative[s] > ideal ? Volt.fault : Volt.live)
                    }
                }
                .font(.caption.monospacedDigit())
            } else {
                Text(paceText(c, budget)).font(.caption).foregroundStyle(Volt.inkSoft)
            }

            GeometryReader { geo in
                let w = geo.size.width - 34, h = geo.size.height - 16
                let x: (Double) -> CGFloat = { CGFloat($0 / Double(max(n - 1, 1))) * w }
                let y: (Double) -> CGFloat = { h - CGFloat($0 / hi) * h }
                let actual = c.cumulative.enumerated().map { CGPoint(x: x(Double($0.offset)), y: y($0.element)) }

                ZStack(alignment: .topLeading) {
                    ForEach(0..<3) { i in
                        let v = hi * Double(2 - i) / 2
                        Path { p in p.move(to: CGPoint(x: 0, y: y(v))); p.addLine(to: CGPoint(x: w, y: y(v))) }
                            .stroke(Volt.grid, style: StrokeStyle(lineWidth: 1, dash: i == 2 ? [] : [3, 4]))
                        Text(Fmt.money(v)).font(.system(size: 9).monospacedDigit()).foregroundStyle(Volt.inkFaint)
                            .position(x: w + 18, y: y(v))
                    }
                    if budget > 0 {
                        Path { p in p.move(to: CGPoint(x: 0, y: y(budget / Double(n)))); p.addLine(to: CGPoint(x: w, y: y(budget))) }
                            .stroke(Volt.inkSoft, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    }
                    if let last = actual.last {
                        Path { p in p.move(to: last); p.addLine(to: CGPoint(x: w, y: y(c.projected))) }
                            .stroke(Volt.money.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
                            .opacity(drawn)
                    }
                    if actual.count > 1 {
                        var area = ChartMath.monotonePath(actual)
                        let _ = {
                            area.addLine(to: CGPoint(x: actual.last!.x, y: h))
                            area.addLine(to: CGPoint(x: 0, y: h))
                            area.closeSubpath()
                        }()
                        area.fill(LinearGradient(colors: [Volt.money.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                            .opacity(drawn)
                        ChartMath.monotonePath(actual).trim(from: 0, to: drawn)
                            .stroke(Volt.money, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    if let s = scrub, s < actual.count {
                        Path { p in p.move(to: CGPoint(x: actual[s].x, y: 0)); p.addLine(to: CGPoint(x: actual[s].x, y: h)) }
                            .stroke(Volt.inkSoft.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Circle().fill(Volt.money).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Volt.canvas, lineWidth: 2))
                            .position(actual[s])
                    }
                    HStack {
                        Text(Fmt.dayMonth.string(from: c.start))
                        Spacer()
                        Text(Fmt.dayMonth.string(from: c.end))
                    }
                    .font(.system(size: 9)).foregroundStyle(Volt.inkFaint)
                    .frame(width: w).offset(y: h + 4)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(Int((v.location.x / w * Double(n - 1)).rounded()), 0), max(c.cumulative.count - 1, 0)) }
                    .onEnded { _ in scrub = nil })
                .sensoryFeedback(.selection, trigger: scrub)
            }
            .frame(height: 170)

            HStack(spacing: 14) {
                key(Volt.money, solid: true, "Acumulado")
                key(Volt.money.opacity(0.6), solid: false, "Projeção")
                if budget > 0 { key(Volt.inkSoft, solid: false, "Ritmo da meta") }
            }
            .font(.caption2).foregroundStyle(Volt.inkSoft)
        }
        .voltCard()
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { drawn = 1 } }
    }

    private func paceText(_ c: CycleData, _ budget: Double) -> String {
        guard budget > 0 else { return "Defina uma meta para comparar o ritmo." }
        let ideal = budget * c.elapsedDays / Double(c.totalDays)
        let diff = c.spent - ideal
        return diff > 0 ? "\(Fmt.money(diff)) acima do ritmo ideal para hoje" : "\(Fmt.money(-diff)) abaixo do ritmo ideal para hoje"
    }

    private func key(_ color: Color, solid: Bool, _ text: String) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: solid ? [] : [3, 2]))
                .frame(width: 14, height: 2)
            Text(text)
        }
    }
}

// MARK: - Meta

private struct BudgetSection: View {
    let model: PlugViewModel

    var body: some View {
        @Bindable var t = model.tariff
        let c = CycleData(model: model)
        let fraction = t.monthlyBudget > 0 ? c.projected / t.monthlyBudget : 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Meta mensal")
                Spacer()
                Text(Fmt.money(t.monthlyBudget))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Volt.ink)
                    .contentTransition(.numericText(value: t.monthlyBudget))
            }
            Slider(value: $t.monthlyBudget, in: 10...500, step: 5)
                .tint(fraction > 1 ? Volt.fault : Volt.money)
                .sensoryFeedback(.selection, trigger: t.monthlyBudget)
            HStack(spacing: 8) {
                Image(systemName: fraction > 1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(fraction > 1
                     ? "Projeção \(Fmt.num((fraction - 1) * 100, 0))% acima da meta (\(Fmt.money(c.projected - t.monthlyBudget)))"
                     : "Projeção usa \(Fmt.num(fraction * 100, 0))% da meta — sobra \(Fmt.money(t.monthlyBudget - c.projected))")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(fraction > 1 ? Volt.fault : Volt.live)
            .animation(.snappy, value: fraction > 1)
        }
        .voltCard()
    }
}

// MARK: - Custo por período (barras / linha)

private struct PeriodCostSection: View {
    let model: PlugViewModel
    @State private var period: Period = .week
    @State private var style: Style = ProcessInfo.processInfo.arguments.contains("--line") ? .line : .bars
    @State private var selection: Date?

    enum Period: String, CaseIterable {
        case day, week, month, year
        var label: String {
            switch self {
            case .day: return "Hoje"
            case .week: return "7 dias"
            case .month: return "30 dias"
            case .year: return "12 meses"
            }
        }
    }

    enum Style: String, CaseIterable {
        case bars, line
        var icon: String { self == .bars ? "chart.bar.fill" : "chart.xyaxis.line" }
    }

    struct Point: Identifiable {
        let id: Date
        let label: String
        let kWh: Double
        var isCurrent = false
    }

    var body: some View {
        let _ = model.energy.revision
        let t = model.tariff
        let pts = points
        let totalKWh = pts.map(\.kWh).reduce(0, +)
        let total = t.cost(totalKWh)
        let nonZero = pts.filter { $0.kWh > 0 }
        let avg = nonZero.isEmpty ? 0 : total / Double(nonZero.count)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Custo por período")
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Style.allCases, id: \.self) { st in
                        Image(systemName: st.icon)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(style == st ? Volt.onInk : Volt.inkSoft)
                            .frame(width: 36, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(style == st ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Color.clear)))
                            .onTapGesture { withAnimation(.snappy) { style = st } }
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Volt.surfaceRaised))
                .sensoryFeedback(.selection, trigger: style)
            }

            PillPicker(options: Period.allCases, selection: $period) { $0.label }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.money(total))
                        .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Volt.ink)
                        .contentTransition(.numericText(value: total))
                    let (v, u) = Fmt.energy(totalKWh)
                    Text("\(v) \(u)").font(.caption.monospacedDigit()).foregroundStyle(Volt.inkSoft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.money(avg)).font(.headline.monospacedDigit()).foregroundStyle(Volt.money)
                    Text(avgLabel).font(.caption2).foregroundStyle(Volt.inkSoft)
                }
            }

            Group {
                switch style {
                case .bars:
                    BarsChart(items: pts.map { BarItem(id: $0.id, label: $0.label, value: t.cost($0.kWh), isToday: $0.isCurrent) },
                              selection: $selection, color: Volt.money, height: 180,
                              format: { Fmt.money($0) }, subtitle: { tooltip($0.id) }, target: target)
                case .line:
                    MoneyLineChart(points: pts.map { (label: $0.label, value: t.cost($0.kWh), date: $0.id) },
                                   tooltip: tooltip, target: target)
                }
            }
            .id("\(period)-\(style)")
            .transition(.opacity)
        }
        .voltCard()
        .animation(.snappy, value: period)
        .onChange(of: period) { selection = nil }
    }

    /// Meta mensal convertida para a unidade de cada ponto do recorte.
    private var target: Double? {
        let b = model.tariff.monthlyBudget
        guard b > 0 else { return nil }
        switch period {
        case .day: return b / 30 / 24
        case .week, .month: return b / 30
        case .year: return b
        }
    }

    private var avgLabel: String {
        switch period {
        case .day: return "média por hora"
        case .week, .month: return "média por dia"
        case .year: return "média por mês"
        }
    }

    private func tooltip(_ d: Date) -> String {
        switch period {
        case .day: return "\(Calendar.current.component(.hour, from: d))h–\(Calendar.current.component(.hour, from: d) + 1)h"
        case .week, .month: return "\(Fmt.weekdayShort.string(from: d)), \(Fmt.dayMonth.string(from: d))"
        case .year: return d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "pt_BR")))
        }
    }

    private var points: [Point] {
        let e = model.energy
        let cal = Calendar.current
        switch period {
        case .day:
            let today = e.day(Date())
            let now = cal.component(.hour, from: Date())
            let start = cal.startOfDay(for: Date())
            return (0...now).map { h in
                Point(id: cal.date(byAdding: .hour, value: h, to: start)!, label: "\(h)h", kWh: today.hourly[h] / 1000, isCurrent: h == now)
            }
        case .week, .month:
            let n = period == .week ? 7 : 30
            return e.lastDays(n).map { d in
                Point(id: d.day,
                      label: n == 7 ? Fmt.weekdayShort.string(from: d.day).prefix(3).capitalized : "\(cal.component(.day, from: d.day))",
                      kWh: d.kWh, isCurrent: cal.isDateInToday(d.day))
            }
        case .year:
            let thisMonth = cal.dateInterval(of: .month, for: Date())!.start
            return (0..<12).reversed().map { back in
                let start = cal.date(byAdding: .month, value: -back, to: thisMonth)!
                let end = min(cal.date(byAdding: .month, value: 1, to: start)!, Date())
                return Point(id: start, label: start.formatted(.dateTime.month(.narrow).locale(Locale(identifier: "pt_BR"))),
                             kWh: e.kWh(from: start, to: end), isCurrent: back == 0)
            }
        }
    }
}

/// Linha suave com área e scrubbing (mesmo estilo do dia × dia), em reais.
private struct MoneyLineChart: View {
    let points: [(label: String, value: Double, date: Date)]
    let tooltip: (Date) -> String
    var target: Double? = nil
    var height: CGFloat = 190

    @State private var scrub: Int?
    @State private var drawn: CGFloat = 0

    var body: some View {
        let hi = ChartMath.niceCeil(max(points.map(\.value).max() ?? 0, target ?? 0, 0.01) * 1.08)
        GeometryReader { geo in
            let w = geo.size.width - 40
            let h = geo.size.height - 18
            let n = max(points.count - 1, 1)
            let pt: (Int) -> CGPoint = { i in
                CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h - CGFloat(points[i].value / hi) * h)
            }
            let pts = points.indices.map(pt)

            ZStack(alignment: .topLeading) {
                ForEach(0..<4) { i in
                    let y = h * CGFloat(i) / 3
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Volt.grid, style: StrokeStyle(lineWidth: 1, dash: i == 3 ? [] : [3, 4]))
                    Text(Fmt.money(hi * Double(3 - i) / 3))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Volt.inkFaint)
                        .position(x: w + 22, y: y)
                }
                let stride = max(1, points.count / 6)
                ForEach(points.indices, id: \.self) { i in
                    if i % stride == 0 || i == points.count - 1 {
                        Text(points[i].label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Volt.inkFaint)
                            .position(x: pts[i].x, y: h + 10)
                    }
                }

                if let target, target > 0 {
                    let ty = h - CGFloat(target / hi) * h
                    Path { p in p.move(to: CGPoint(x: 0, y: ty)); p.addLine(to: CGPoint(x: w, y: ty)) }
                        .stroke(Volt.fault, style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
                    Text("meta \(Fmt.money(target))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Volt.fault)
                        .fixedSize()
                        .position(x: 40, y: ty - 9)
                        .opacity(scrub == nil ? 1 : 0)
                }

                if pts.count > 1 {
                    let line = ChartMath.monotonePath(pts)
                    var area = line
                    let _ = {
                        area.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        area.addLine(to: CGPoint(x: 0, y: h))
                        area.closeSubpath()
                    }()
                    area.fill(LinearGradient(colors: [Volt.money.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                        .mask(alignment: .leading) { Rectangle().frame(width: w * drawn) }
                    line.trim(from: 0, to: drawn)
                        .stroke(Volt.money, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    if scrub == nil, let last = pts.last, drawn >= 1 {
                        PulseDot(color: Volt.money).position(last)
                    }
                }

                if let i = scrub, i < pts.count {
                    Path { p in p.move(to: CGPoint(x: pts[i].x, y: 0)); p.addLine(to: CGPoint(x: pts[i].x, y: h)) }
                        .stroke(Volt.inkSoft.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Circle().fill(Volt.money).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Volt.canvas, lineWidth: 2))
                        .position(pts[i])
                    Callout(title: Fmt.money(points[i].value), subtitle: tooltip(points[i].date), color: Volt.money)
                        .fixedSize()
                        .position(x: min(max(pts[i].x, 55), w - 55), y: -20)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in scrub = min(max(Int((v.location.x / w * CGFloat(n)).rounded()), 0), points.count - 1) }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { scrub = nil } })
            .sensoryFeedback(.selection, trigger: scrub)
        }
        .frame(height: height)
        .padding(.top, 26)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { drawn = 1 } }
    }
}

// MARK: - Quando você gasta

private struct DaypartSection: View {
    let model: PlugViewModel
    @State private var selected: Int?

    private let parts: [(String, String, Range<Int>, Color)] = [
        ("Madrugada", "moon.zzz.fill", 0..<6, Volt.violet),
        ("Manhã", "sunrise.fill", 6..<12, Volt.amber),
        ("Tarde", "sun.max.fill", 12..<18, Volt.arc),
        ("Noite", "moon.fill", 18..<24, Volt.fault),
    ]

    var body: some View {
        let _ = model.energy.revision
        let days = model.energy.lastDays(7).filter { $0.coveredSeconds > 3600 }
        let totals = parts.map { p in days.map { d in p.2.map { d.hourly[$0] }.reduce(0, +) }.reduce(0, +) / 1000 }
        let sum = max(totals.reduce(0, +), 0.0001)
        let perMonth = days.isEmpty ? 0 : 30.0 / Double(days.count)

        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Quando você gasta · média 7 dias")
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(parts.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(parts[i].3.opacity(selected == nil || selected == i ? 1 : 0.3))
                            .frame(width: max((geo.size.width - 9) * totals[i] / sum, 4))
                            .onTapGesture { withAnimation(.snappy) { selected = selected == i ? nil : i } }
                    }
                }
            }
            .frame(height: 28)
            .sensoryFeedback(.selection, trigger: selected)

            ForEach(parts.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Image(systemName: parts[i].1)
                        .foregroundStyle(parts[i].3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(parts[i].0).font(.subheadline.weight(.semibold)).foregroundStyle(Volt.ink)
                        Text("\(parts[i].2.lowerBound)h–\(parts[i].2.upperBound)h · \(Fmt.num(totals[i] / sum * 100, 0))%")
                            .font(.caption).foregroundStyle(Volt.inkSoft)
                    }
                    Spacer()
                    Text("\(Fmt.money(model.tariff.cost(totals[i] * perMonth)))/mês")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Volt.ink)
                }
                .opacity(selected == nil || selected == i ? 1 : 0.4)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { selected = selected == i ? nil : i } }
            }
        }
        .voltCard()
    }
}

// MARK: - Simulador

private struct SimulatorSection: View {
    let model: PlugViewModel
    @State private var watts: Double = 100
    @State private var hours: Double = 8
    @State private var seeded = false

    var body: some View {
        let t = model.tariff
        let kWhDay = watts * hours / 1000
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Simulador")
                Spacer()
                Button("Usar leitura atual") {
                    withAnimation(.snappy) { watts = max(model.metrics.powerW ?? watts, 1).rounded() }
                }
                .font(.caption.weight(.semibold))
                .disabled(model.metrics.powerW == nil)
            }
            VStack(spacing: 6) {
                HStack {
                    Text("Potência").foregroundStyle(Volt.inkSoft)
                    Spacer()
                    Text("\(Fmt.num(watts, 0)) W").fontWeight(.semibold).monospacedDigit()
                }
                .font(.subheadline)
                Slider(value: $watts, in: 1...3500, step: 1).tint(Volt.arc)
            }
            VStack(spacing: 6) {
                HStack {
                    Text("Uso por dia").foregroundStyle(Volt.inkSoft)
                    Spacer()
                    Text(Fmt.duration(hours * 3600)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.subheadline)
                Slider(value: $hours, in: 0.25...24, step: 0.25).tint(Volt.arc)
            }
            HStack(spacing: 0) {
                Stat(title: "por dia", value: Fmt.money(t.cost(kWhDay)))
                Divider().frame(height: 30)
                Stat(title: "por mês", value: Fmt.money(t.cost(kWhDay * 30)))
                Divider().frame(height: 30)
                Stat(title: "por ano", value: Fmt.money(t.cost(kWhDay * 365)))
            }
            .padding(.top, 4)
        }
        .voltCard()
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let w = model.metrics.powerW, w > 1 { watts = w.rounded() }
        }
    }
}

// MARK: - Tarifa

private struct TariffSection: View {
    let model: PlugViewModel
    let edit: () -> Void

    var body: some View {
        @Bindable var t = model.tariff
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Tarifa")
                Spacer()
                Button("Editar", action: edit).font(.subheadline.weight(.semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.money(t.effectivePrice))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Volt.ink)
                    .contentTransition(.numericText(value: t.effectivePrice))
                Text("/ kWh").foregroundStyle(Volt.inkSoft)
            }
            Text("Base \(Fmt.money(t.pricePerKWh)) + bandeira \(Fmt.money(t.flag.surcharge))\(t.includesTaxes ? "" : " + \(Fmt.num(t.taxPercent, 0))% impostos")")
                .font(.caption).foregroundStyle(Volt.inkSoft)
            HStack(spacing: 6) {
                ForEach(TariffFlag.allCases) { f in
                    let sel = f == t.flag
                    HStack(spacing: 5) {
                        Circle().fill(flagColor(f)).frame(width: 8, height: 8)
                        Text(f.label).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(sel ? Volt.onInk : Volt.ink)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(sel ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
                    .onTapGesture { withAnimation(.snappy) { t.flag = f } }
                }
            }
            .sensoryFeedback(.selection, trigger: t.flag)
        }
        .voltCard()
    }
}

func flagColor(_ f: TariffFlag) -> Color {
    switch f {
    case .verde: return Volt.live
    case .amarela: return Volt.amber
    case .vermelha1: return Volt.fault
    case .vermelha2: return Color(red: 0.7, green: 0.1, blue: 0.15)
    }
}

struct TariffEditor: View {
    @Bindable var tariff: TariffSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Tarifa (TE + TUSD)")
                    Spacer()
                    TextField("0,85", value: $tariff.pricePerKWh, format: .number.precision(.fractionLength(2...5)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("R$/kWh").foregroundStyle(.secondary).font(.caption)
                }
                Toggle("Valor já inclui impostos", isOn: $tariff.includesTaxes)
                if !tariff.includesTaxes {
                    Stepper(value: $tariff.taxPercent, in: 0...60, step: 1) {
                        LabeledContent("ICMS + PIS/COFINS", value: "\(Fmt.num(tariff.taxPercent, 0))%")
                    }
                }
            } header: {
                Text("Tarifa")
            } footer: {
                Text("Copie da sua conta de luz. Se a conta mostrar o preço \"com tributos\", ative a opção acima.")
            }

            Section("Bandeira tarifária") {
                Picker("Bandeira", selection: $tariff.flag) {
                    ForEach(TariffFlag.allCases) { f in
                        Text("\(f.label)  +\(Fmt.money(f.surcharge))").tag(f)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Stepper(value: $tariff.billingDay, in: 1...28) {
                    LabeledContent("Dia da leitura", value: "\(tariff.billingDay)")
                }
            } header: {
                Text("Ciclo")
            }

            Section {
                LabeledContent("Preço efetivo", value: "\(Fmt.money(tariff.effectivePrice)) / kWh")
            }
        }
        .navigationTitle("Tarifa")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
        }
    }
}
