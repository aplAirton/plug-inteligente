import SwiftUI
import SwiftData

struct LiveTab: View {
    let model: PlugViewModel

    var body: some View {
        VoltScreen(title: model.tariff.deviceName) {
            HStack {
                ConnectionChip(model: model)
                Spacer()
            }

            if model.lanState != .ready && model.metrics.powerW == nil && !PlugViewModel.isDemo {
                OfflineCard(model: model)
            }

            HeroGauge(model: model)
            LiveMetricsRow(model: model)
            RunRateSection(model: model)
            LiveChartCard(model: model)
            TodayCard(model: model)
            EventsCard(model: model)
        }
    }
}

// MARK: - Gauge principal + botão

private struct HeroGauge: View {
    let model: PlugViewModel
    @State private var pressing = false

    var body: some View {
        let m = model.metrics
        let watts = m.powerW ?? 0
        let isOn = m.isOn ?? false
        let scale = max(model.tariff.alertWatts, 500)
        // escala logarítmica suave: valores baixos ainda movem o ponteiro
        let fraction = watts <= 0 ? 0 : log10(1 + watts) / log10(1 + scale)

        VStack(spacing: 18) {
            PowerGauge(fraction: fraction, active: isOn, flowSpeed: min(watts / scale, 1)) {
                VStack(spacing: 2) {
                    Image(systemName: model.tariff.applianceIcon)
                        .font(.title3)
                        .foregroundStyle(isOn ? Volt.arc : Volt.inkFaint)
                        .symbolEffect(.bounce, value: isOn)
                        .padding(.bottom, 4)
                    Text(m.powerW.map { Fmt.num($0, $0 < 100 ? 1 : 0) } ?? "—")
                        .font(.system(size: 58, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Volt.ink)
                        .contentTransition(.numericText(value: watts))
                        .animation(.snappy, value: watts)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("watts").font(.footnote.weight(.semibold)).foregroundStyle(Volt.inkSoft)
                }
                .padding(.horizontal, 40)
            }
            .frame(width: 270, height: 270)
            .padding(.top, 6)

            Button {
                Task { await model.setSwitch(!isOn) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.headline.weight(.bold))
                    Text(m.isOn == nil ? "—" : (isOn ? "Ligada" : "Desligada"))
                        .font(.headline)
                        .contentTransition(.interpolate)
                }
                .foregroundStyle(isOn ? Volt.onInk : Volt.ink)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background {
                    Capsule()
                        .fill(isOn ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised))
                        .overlay(Capsule().strokeBorder(isOn ? Color.clear : Volt.stroke))
                }
                .scaleEffect(pressing ? 0.94 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!model.canControl)
            .opacity(model.canControl ? 1 : 0.5)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, pressing: { p in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressing = p }
            }, perform: {})
            .sensoryFeedback(.impact(weight: .heavy), trigger: m.isOn)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isOn)

            if let c = model.dpInt(9), c > 0 {
                Label("Desliga em \(Fmt.duration(Double(c)))", systemImage: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Volt.amber)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .voltCard(padding: 20, radius: 28)
    }
}

// MARK: - Tensão / corrente / energia

private struct LiveMetricsRow: View {
    let model: PlugViewModel

    var body: some View {
        let m = model.metrics
        let live = model.energy.live.suffix(60)
        HStack(spacing: 10) {
            MiniMetric(title: "Tensão", value: m.voltageV.map { Fmt.num($0) }, unit: "V",
                       color: Volt.violet, icon: "waveform.path", spark: live.map(\.volts))
            Divider().frame(height: 56)
            MiniMetric(title: "Corrente", value: m.currentA.map { Fmt.num($0, 2) }, unit: "A",
                       color: Volt.live, icon: "arrow.left.arrow.right", spark: live.map(\.amps))
            Divider().frame(height: 56)
            MiniMetric(title: "Fator", value: powerFactor(m).map { Fmt.num($0, 2) }, unit: "FP",
                       color: Volt.amber, icon: "angle", spark: [])
        }
        .voltCard()
    }

    /// FP aparente = P / (V·I). Útil para identificar cargas indutivas/fontes.
    private func powerFactor(_ m: PlugMetrics) -> Double? {
        guard let p = m.powerW, let v = m.voltageV, let a = m.currentA, v * a > 5 else { return nil }
        return min(p / (v * a), 1)
    }
}

private struct MiniMetric: View {
    let title: String
    let value: String?
    let unit: String
    let color: Color
    let icon: String
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(Volt.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).font(.caption2.weight(.semibold)).foregroundStyle(Volt.inkSoft)
            }
            Group {
                if spark.count > 2 {
                    Sparkline(values: spark, color: color.opacity(0.8))
                } else {
                    Capsule().fill(Volt.grid).frame(height: 2).frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: value)
    }
}

// MARK: - Se continuar assim

private struct RunRateSection: View {
    let model: PlugViewModel
    @State private var unit: Unit = .hour

    enum Unit: String, CaseIterable {
        case minute, hour, day
        var label: String {
            switch self {
            case .minute: return "/min"
            case .hour: return "/hora"
            case .day: return "/dia"
            }
        }
        var hours: Double {
            switch self {
            case .minute: return 1.0 / 60
            case .hour: return 1
            case .day: return 24
            }
        }
    }

    var body: some View {
        let _ = model.energy.revision
        let t = model.tariff
        let watts = model.metrics.powerW ?? 0
        let kWh = watts / 1000 * unit.hours
        let cost = t.cost(kWh)
        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let todayKWh = model.energy.day(now).kWh
        let todayClose = t.cost(todayKWh + watts / 1000 * endOfDay.timeIntervalSince(now) / 3600)
        let monthly = t.cost(watts / 1000 * 24 * 30)
        let dailyBudget = t.monthlyBudget > 0 ? t.monthlyBudget / 30 : nil

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Se continuar assim")
                Spacer()
                PillPicker(options: Unit.allCases, selection: $unit) { $0.label }
                    .frame(width: 200)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(cost < 0.1 ? String(format: "R$ %.4f", cost).replacingOccurrences(of: ".", with: ",") : Fmt.money(cost))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Volt.money)
                    .contentTransition(.numericText(value: cost))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit.label).font(.title3.weight(.semibold)).foregroundStyle(Volt.inkSoft)
                Spacer()
                let (v, u) = Fmt.energy(kWh)
                Text("\(v) \(u)").font(.subheadline.monospacedDigit()).foregroundStyle(Volt.inkSoft)
            }
            .animation(.snappy, value: unit)
            HStack(spacing: 0) {
                Stat(title: "hoje fecha em", value: Fmt.money(todayClose))
                Divider().frame(height: 28)
                Stat(title: "em 30 dias", value: Fmt.money(monthly))
                if let dailyBudget {
                    Divider().frame(height: 28)
                    Stat(title: "meta diária", value: Fmt.money(dailyBudget))
                }
            }
            if let dailyBudget, watts > 0 {
                let ratio = t.cost(watts / 1000 * 24) / dailyBudget
                Text(ratio > 1
                     ? "Neste ritmo o dia custa \(Fmt.num(ratio, 1))× a meta diária."
                     : "Neste ritmo o dia fica em \(Fmt.num(ratio * 100, 0))% da meta diária.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ratio > 1 ? Volt.fault : Volt.live)
            }
        }
        .voltCard()
    }
}

// MARK: - Gráfico ao vivo

private struct LiveChartCard: View {
    let model: PlugViewModel
    @State private var range: Range = .live

    enum Range: String, CaseIterable {
        case live, hour, day
        var label: String {
            switch self {
            case .live: return "15 min"
            case .hour: return "1 h"
            case .day: return "24 h"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Potência", icon: "waveform")
                Spacer()
            }
            PillPicker(options: Range.allCases, selection: $range) { $0.label }

            let pts = points
            if pts.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(Volt.inkFaint)
                        .symbolEffect(.pulse)
                    Text("Coletando leituras…").font(.footnote).foregroundStyle(Volt.inkSoft)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                LineSeriesChart(points: pts, color: Volt.arc, unit: "W", digits: 1)
                    .id(range)
                    .transition(.opacity)
            }
        }
        .voltCard()
        .animation(.easeInOut(duration: 0.25), value: range)
    }

    private var points: [LineSeriesChart.Point] {
        _ = model.energy.revision
        switch range {
        case .live:
            return model.energy.live.map { .init(x: $0.date, y: $0.watts) }
        case .hour:
            return model.energy.readings(since: Date().addingTimeInterval(-3600)).map { .init(x: $0.date, y: $0.watts) }
                + (model.energy.live.last.map { [.init(x: $0.date, y: $0.watts)] } ?? [])
        case .day:
            let rs = model.energy.readings(since: Date().addingTimeInterval(-86_400))
            return downsample(rs.map { .init(x: $0.date, y: $0.watts) }, to: 180)
        }
    }

    private func downsample(_ pts: [LineSeriesChart.Point], to n: Int) -> [LineSeriesChart.Point] {
        guard pts.count > n else { return pts }
        let bucket = Double(pts.count) / Double(n)
        return (0..<n).map { i in
            let slice = pts[Int(Double(i) * bucket)..<min(Int(Double(i + 1) * bucket), pts.count)]
            let avg = slice.map(\.y).reduce(0, +) / Double(max(slice.count, 1))
            return .init(x: slice.last!.x, y: avg)
        }
    }
}

// MARK: - Hoje

private struct TodayCard: View {
    let model: PlugViewModel

    var body: some View {
        let _ = model.energy.revision
        let today = model.energy.day(Date())
        let yesterday = model.energy.day(Date().addingTimeInterval(-86_400))
        let (value, unit) = Fmt.energy(today.kWh)
        let delta = yesterday.kWh > 0.001 ? (today.kWh - yesterday.kWh) / yesterday.kWh : nil

        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Hoje", icon: "sun.max.fill")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Volt.ink)
                    .contentTransition(.numericText())
                Text(unit).font(.headline).foregroundStyle(Volt.inkSoft)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.money(model.tariff.cost(today.kWh)))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Volt.money)
                        .contentTransition(.numericText())
                    if let delta {
                        Label("\(Fmt.num(abs(delta) * 100, 0))% vs ontem",
                              systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(delta > 0 ? Volt.fault : Volt.live)
                    }
                }
            }
            HStack(spacing: 0) {
                Stat(title: "Pico", value: today.peakWatts > 0 ? "\(Fmt.num(today.peakWatts, 0)) W" : "—")
                Divider().frame(height: 28)
                Stat(title: "Ligada", value: Fmt.duration(today.onSeconds))
                Divider().frame(height: 28)
                Stat(title: "Média", value: today.coveredSeconds > 60 ? "\(Fmt.num(today.kWh * 1000 / (today.coveredSeconds / 3600), 0)) W" : "—")
            }
            HourStrip(hourly: today.hourly)
        }
        .voltCard()
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Volt.ink)
                .contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(Volt.inkSoft)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Faixa de 24 mini barras com o perfil do dia.
private struct HourStrip: View {
    let hourly: [Double]

    var body: some View {
        let maxV = max(hourly.max() ?? 1, 1)
        let now = Calendar.current.component(.hour, from: Date())
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(h == now ? Volt.arc : (h < now ? Volt.amber.opacity(0.4 + 0.6 * hourly[h] / maxV) : Volt.grid))
                        .frame(height: max(3, 34 * hourly[h] / maxV))
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                Text("0h"); Spacer(); Text("12h"); Spacer(); Text("23h")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Volt.inkFaint)
        }
        .animation(.spring, value: hourly)
    }
}

// MARK: - Eventos

struct EventsCard: View {
    let model: PlugViewModel
    var limit = 5

    var body: some View {
        let _ = model.energy.revision
        let events = model.energy.events(limit: limit)
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Atividade", icon: "list.bullet")
            if events.isEmpty {
                Text("Nenhum evento ainda").font(.footnote).foregroundStyle(Volt.inkFaint)
            }
            ForEach(events, id: \.persistentModelID) { e in
                HStack(spacing: 12) {
                    Image(systemName: e.eventKind.icon)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(color(e.eventKind))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(color(e.eventKind).opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.eventKind.title).font(.subheadline.weight(.semibold)).foregroundStyle(Volt.ink)
                        if !e.detail.isEmpty {
                            Text(e.detail).font(.caption).foregroundStyle(Volt.inkSoft)
                        }
                    }
                    Spacer()
                    Text(e.date.formatted(.relative(presentation: .named).locale(Locale(identifier: "pt_BR"))))
                        .font(.caption2).foregroundStyle(Volt.inkFaint)
                }
            }
        }
        .voltCard()
    }

    private func color(_ k: PlugEvent.Kind) -> Color {
        switch k {
        case .switchedOn, .connected: return Volt.live
        case .switchedOff: return Volt.inkSoft
        case .disconnected, .overload: return Volt.fault
        case .peak: return Volt.amber
        case .voltage: return Volt.violet
        case .timer: return Volt.arc
        }
    }
}

// MARK: - Offline

private struct OfflineCard: View {
    let model: PlugViewModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Volt.amber)
                .symbolEffect(.pulse)
            Text(model.lanHost.isEmpty ? "Configure a conexão" : "Tomada fora de alcance")
                .font(.headline).foregroundStyle(Volt.ink)
            Text(model.lanHost.isEmpty
                 ? "Informe o IP e a local_key em Ajustes → Conexão."
                 : "Verifique se o iPhone está na mesma rede Wi-Fi que a tomada.")
                .font(.footnote).foregroundStyle(Volt.inkSoft).multilineTextAlignment(.center)
            if !model.lanHost.isEmpty {
                Button("Tentar agora") { model.connectLAN() }
                    .buttonStyle(.borderedProminent)
                    .tint(Volt.arc)
            }
        }
        .frame(maxWidth: .infinity)
        .voltCard(padding: 20)
    }
}
