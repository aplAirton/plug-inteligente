import SwiftUI

// MARK: - Geometria

enum ChartMath {
    /// Curva cúbica monotônica (Fritsch–Carlson): suave e sem "overshoot" abaixo de zero.
    static func monotonePath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }

        let n = pts.count
        var dx = [CGFloat](repeating: 0, count: n - 1)
        var slope = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            dx[i] = pts[i + 1].x - pts[i].x
            slope[i] = dx[i] == 0 ? 0 : (pts[i + 1].y - pts[i].y) / dx[i]
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = slope[0]
        m[n - 1] = slope[n - 2]
        for i in 1..<(n - 1) {
            if slope[i - 1] * slope[i] <= 0 {
                m[i] = 0
            } else {
                let w1 = 2 * dx[i] + dx[i - 1], w2 = dx[i] + 2 * dx[i - 1]
                m[i] = (w1 + w2) / (w1 / slope[i - 1] + w2 / slope[i])
            }
        }
        for i in 0..<(n - 1) {
            let c1 = CGPoint(x: pts[i].x + dx[i] / 3, y: pts[i].y + m[i] * dx[i] / 3)
            let c2 = CGPoint(x: pts[i + 1].x - dx[i] / 3, y: pts[i + 1].y - m[i + 1] * dx[i] / 3)
            path.addCurve(to: pts[i + 1], control1: c1, control2: c2)
        }
        return path
    }

    /// Valor "redondo" acima do máximo, para a escala do eixo.
    static func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let exp = pow(10, floor(log10(v)))
        let f = v / exp
        let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let nice = steps.first { f <= $0 } ?? 10
        return nice * exp
    }
}

// MARK: - Linha ao vivo com scrubbing

struct LineSeriesChart: View {
    struct Point: Hashable {
        let x: Date
        let y: Double
    }

    let points: [Point]
    var color: Color = Volt.arc
    var unit: String = "W"
    var digits: Int = 0
    var height: CGFloat = 190
    var minY: Double? = nil
    var timeFormat: DateFormatter = Fmt.hourMinute

    @State private var scrubX: CGFloat?
    @State private var drawn: CGFloat = 0

    var body: some View {
        let ys = points.map(\.y)
        let lo = minY ?? 0
        let hi = ChartMath.niceCeil(max((ys.max() ?? 1) * 1.1, lo + 1))
        let lower = minY.map { _ in max(0, floor(((ys.min() ?? lo) - 2))) } ?? 0

        GeometryReader { geo in
            let w = geo.size.width - 34
            let h = geo.size.height - 18
            let t0 = points.first?.x.timeIntervalSince1970 ?? 0
            let t1 = max(points.last?.x.timeIntervalSince1970 ?? 1, t0 + 1)
            let map: (Point) -> CGPoint = { p in
                CGPoint(
                    x: CGFloat((p.x.timeIntervalSince1970 - t0) / (t1 - t0)) * w,
                    y: h - CGFloat((p.y - lower) / max(hi - lower, 0.001)) * h
                )
            }
            let pts = points.map(map)
            let line = ChartMath.monotonePath(pts)

            ZStack(alignment: .topLeading) {
                // grade + rótulos
                ForEach(0..<4) { i in
                    let v = lower + (hi - lower) * Double(3 - i) / 3
                    let y = h * CGFloat(i) / 3
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Volt.grid, style: StrokeStyle(lineWidth: 1, dash: i == 3 ? [] : [3, 4]))
                    Text(Fmt.num(v, v < 10 && v > 0 ? 1 : 0))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Volt.inkFaint)
                        .position(x: w + 18, y: y)
                }

                if pts.count > 1 {
                    // área
                    var area = line
                    let _ = {
                        area.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        area.addLine(to: CGPoint(x: pts.first!.x, y: h))
                        area.closeSubpath()
                    }()
                    area.fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                        .mask(alignment: .leading) { Rectangle().frame(width: w * drawn) }

                    line.trim(from: 0, to: drawn)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))

                    // ponto final pulsante
                    if let last = pts.last, scrubX == nil, drawn >= 1 {
                        PulseDot(color: color).position(last)
                    }
                }

                // eixo X
                if let a = points.first?.x, let b = points.last?.x {
                    HStack {
                        Text(timeFormat.string(from: a))
                        Spacer()
                        Text(timeFormat.string(from: a.addingTimeInterval(b.timeIntervalSince(a) / 2)))
                        Spacer()
                        Text(timeFormat.string(from: b))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Volt.inkFaint)
                    .frame(width: w)
                    .offset(y: h + 5)
                }

                // scrub
                if let sx = scrubX, !pts.isEmpty {
                    let idx = nearestIndex(pts, x: sx)
                    let p = pts[idx]
                    Path { path in path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: h)) }
                        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Circle().fill(color).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Volt.surface, lineWidth: 2))
                        .position(p)
                    Callout(
                        title: Fmt.num(points[idx].y, digits) + " " + unit,
                        subtitle: timeFormat.string(from: points[idx].x),
                        color: color
                    )
                    .fixedSize()
                    .position(x: min(max(p.x, 50), w - 50), y: -22)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrubX = min(max(v.location.x, 0), w) }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { scrubX = nil } }
            )
            .sensoryFeedback(.selection, trigger: scrubX.map { nearestIndex(pts, x: $0) })
        }
        .frame(height: height)
        .padding(.top, 28)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { drawn = 1 }
        }
    }

    private func nearestIndex(_ pts: [CGPoint], x: CGFloat) -> Int {
        var best = 0
        var dist = CGFloat.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() where abs(p.x - x) < dist {
            dist = abs(p.x - x)
            best = i
        }
        return best
    }
}

struct PulseDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.25 : 0.4)
                .opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Volt.surface, lineWidth: 2))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct Callout: View {
    let title: String
    let subtitle: String
    var color: Color = Volt.arc

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Volt.ink)
            Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(Volt.inkSoft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

// MARK: - Barras com média e seleção

struct BarItem: Identifiable, Hashable {
    let id: Date
    let label: String
    let value: Double
    var isToday = false
}

struct BarsChart: View {
    let items: [BarItem]
    @Binding var selection: Date?
    var color: Color = Volt.amber
    var height: CGFloat = 200
    var format: (Double) -> String
    var subtitle: (BarItem) -> String = { $0.label }
    /// Meta (mesma unidade dos valores) — linha tracejada.
    var target: Double? = nil

    @State private var grown = false

    var body: some View {
        let maxV = ChartMath.niceCeil(max(items.map(\.value).max() ?? 1, target ?? 0) * 1.08)
        let nonZero = items.filter { $0.value > 0 }
        let avg = nonZero.isEmpty ? 0 : nonZero.map(\.value).reduce(0, +) / Double(nonZero.count)

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height - 20
            let slot = w / CGFloat(max(items.count, 1))
            let barW = max(min(slot * 0.62, 26), 3)
            let avgY = h - CGFloat(avg / maxV) * h

            ZStack(alignment: .topLeading) {
                ForEach(0..<3) { i in
                    let y = h * CGFloat(i) / 2
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Volt.grid, style: StrokeStyle(lineWidth: 1, dash: i == 2 ? [] : [3, 4]))
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let bh = max(CGFloat(item.value / maxV) * h, item.value > 0 ? 3 : 1)
                    let selected = selection == item.id
                    let dim = selection != nil && !selected
                    RoundedRectangle(cornerRadius: min(barW / 2, 7), style: .continuous)
                        .fill(
                            item.isToday
                                ? AnyShapeStyle(Volt.arc)
                                : AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        )
                        .frame(width: barW, height: bh)
                        .scaleEffect(x: 1, y: grown ? 1 : 0.02, anchor: .bottom)
                        .opacity(dim ? 0.35 : 1)
                        .position(x: slot * (CGFloat(i) + 0.5), y: h - bh / 2)
                        .animation(.spring(response: 0.55, dampingFraction: 0.72).delay(Double(i) * 0.018), value: grown)
                        .animation(.easeOut(duration: 0.2), value: selection)
                }

                // linha da média
                if avg > 0 {
                    Path { p in p.move(to: CGPoint(x: 0, y: avgY)); p.addLine(to: CGPoint(x: w, y: avgY)) }
                        .stroke(Volt.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    HStack(spacing: 4) {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 12, y: 0)) }
                            .stroke(Volt.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                            .frame(width: 12, height: 1)
                        Text("média \(format(avg))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Volt.inkSoft)
                    }
                    .fixedSize()
                    .position(x: w - 50, y: -12)
                    .opacity(selection == nil ? 1 : 0)
                }

                if let target, target > 0 {
                    let ty = h - CGFloat(target / maxV) * h
                    Path { p in p.move(to: CGPoint(x: 0, y: ty)); p.addLine(to: CGPoint(x: w, y: ty)) }
                        .stroke(Volt.fault, style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
                    HStack(spacing: 4) {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 12, y: 0)) }
                            .stroke(Volt.fault, style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
                            .frame(width: 12, height: 1)
                        Text("meta \(format(target))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Volt.fault)
                    }
                    .fixedSize()
                    .position(x: 46, y: -12)
                    .opacity(selection == nil ? 1 : 0)
                }

                // rótulos do eixo X (espaçados)
                let stride = max(1, items.count / 7)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i % stride == 0 || i == items.count - 1 {
                        Text(item.label)
                            .font(.system(size: 9, weight: item.isToday ? .bold : .medium))
                            .foregroundStyle(item.isToday ? Volt.arc : Volt.inkFaint)
                            .position(x: slot * (CGFloat(i) + 0.5), y: h + 11)
                    }
                }

                if let sel = selection, let i = items.firstIndex(where: { $0.id == sel }) {
                    let item = items[i]
                    let bh = CGFloat(item.value / maxV) * h
                    Callout(title: format(item.value), subtitle: subtitle(item), color: color)
                        .fixedSize()
                        .position(x: min(max(slot * (CGFloat(i) + 0.5), 52), w - 52), y: max(h - bh - 24, -6))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let i = Int(v.location.x / slot)
                        guard items.indices.contains(i) else { return }
                        if selection != items[i].id { selection = items[i].id }
                    }
            )
            .sensoryFeedback(.selection, trigger: selection)
        }
        .frame(height: height)
        .padding(.top, 18)
        .onAppear { grown = true }
    }
}

// MARK: - Várias séries (dia × dia × média)

struct CompareSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let values: [Double]     // 24 valores
    var dashed = false
    /// Última hora real (dia atual). Depois dela os valores são previsão e a linha fica tracejada.
    var cutoff: Int? = nil
}

struct CompareChart: View {
    let series: [CompareSeries]
    var cumulative: Bool
    var height: CGFloat = 210

    @State private var scrub: Int?
    @State private var drawn: CGFloat = 0

    private func data(_ s: CompareSeries) -> [Double] {
        guard cumulative else { return s.values }
        var acc = 0.0
        return s.values.map { acc += $0; return acc }
    }

    var body: some View {
        let all = series.flatMap(data)
        let hi = ChartMath.niceCeil(max(all.max() ?? 1, 1))

        GeometryReader { geo in
            let w = geo.size.width - 30
            let h = geo.size.height - 18
            let pt: (Int, Double) -> CGPoint = { i, v in
                CGPoint(x: w * CGFloat(i) / 23, y: h - CGFloat(v / hi) * h)
            }

            ZStack(alignment: .topLeading) {
                ForEach(0..<4) { i in
                    let y = h * CGFloat(i) / 3
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Volt.grid, style: StrokeStyle(lineWidth: 1, dash: i == 3 ? [] : [3, 4]))
                    Text(axis(hi * Double(3 - i) / 3))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Volt.inkFaint)
                        .position(x: w + 16, y: y)
                }
                ForEach([0, 6, 12, 18, 23], id: \.self) { hr in
                    Text("\(hr)h")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Volt.inkFaint)
                        .position(x: w * CGFloat(hr) / 23, y: h + 10)
                }

                ForEach(series) { s in
                    let all = data(s).enumerated().map { pt($0.offset, $0.element) }
                    let cut = s.cutoff.map { min(max($0, 0), 23) }
                    let pts = cut.map { Array(all[0...$0]) } ?? all
                    let path = ChartMath.monotonePath(pts)
                    if !s.dashed, let lastPt = pts.last {
                        var area = path
                        let _ = {
                            area.addLine(to: CGPoint(x: lastPt.x, y: h))
                            area.addLine(to: CGPoint(x: 0, y: h))
                            area.closeSubpath()
                        }()
                        area.fill(LinearGradient(colors: [s.color.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                            .mask(alignment: .leading) { Rectangle().frame(width: w * drawn) }
                    }
                    path.trim(from: 0, to: drawn)
                        .stroke(s.color, style: StrokeStyle(lineWidth: s.dashed ? 1.6 : 2.4, lineCap: .round,
                                                            dash: s.dashed ? [5, 4] : []))
                    // previsão do restante do dia
                    if let cut, cut < 23 {
                        ChartMath.monotonePath(Array(all[cut...]))
                            .stroke(s.color.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                            .opacity(drawn)
                        Circle().fill(s.color).frame(width: 7, height: 7).position(all[cut]).opacity(drawn)
                    }
                }

                if let i = scrub {
                    let x = w * CGFloat(i) / 23
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
                        .stroke(Volt.inkSoft.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    ForEach(series) { s in
                        Circle().fill(s.color).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Volt.surface, lineWidth: 1.5))
                            .position(pt(i, data(s)[i]))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(i)h – \(i + 1)h").font(.system(size: 10, weight: .bold)).foregroundStyle(Volt.inkSoft)
                        ForEach(series) { s in
                            HStack(spacing: 5) {
                                Circle().fill(s.color).frame(width: 6, height: 6)
                                Text(s.name + ((s.cutoff.map { i > $0 } ?? false) ? " (prev.)" : ""))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Volt.inkSoft)
                                Spacer(minLength: 8)
                                Text(axis(data(s)[i]) + (cumulative ? " kWh" : " Wh"))
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Volt.ink)
                            }
                        }
                    }
                    .padding(8)
                    .frame(width: 150)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                    .position(x: x < w / 2 ? min(x + 85, w - 75) : max(x - 85, 75), y: 40)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(Int((v.location.x / w * 23).rounded()), 0), 23) }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { scrub = nil } }
            )
            .sensoryFeedback(.selection, trigger: scrub)
        }
        .frame(height: height)
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { drawn = 1 } }
        .onChange(of: cumulative) {
            drawn = 0
            withAnimation(.easeOut(duration: 0.9)) { drawn = 1 }
        }
    }

    private func axis(_ v: Double) -> String {
        cumulative ? Fmt.num(v / 1000, 2) : Fmt.num(v, 0)
    }
}

// MARK: - Mapa de calor hora × dia

struct HeatmapChart: View {
    let days: [DayStat]          // mais antigo → mais recente
    @State private var selected: (Int, Int)?
    @State private var appeared = false

    var body: some View {
        let maxWh = max(days.flatMap(\.hourly).max() ?? 1, 1)
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("").frame(width: 30)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h)h").font(.system(size: 9, weight: .medium)).foregroundStyle(Volt.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(days.enumerated()), id: \.element.id) { r, day in
                HStack(spacing: 3) {
                    Text(Fmt.weekdayShort.string(from: day.day).prefix(3).capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Calendar.current.isDateInToday(day.day) ? Volt.arc : Volt.inkSoft)
                        .frame(width: 27, alignment: .leading)
                    ForEach(0..<24, id: \.self) { c in
                        let v = day.hourly[c]
                        let t = v / maxWh
                        let isSel = selected.map { $0 == (r, c) } ?? false
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(v <= 0.05 ? Volt.grid : Volt.heat(t).opacity(0.25 + 0.75 * t))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if isSel { RoundedRectangle(cornerRadius: 3).stroke(Volt.ink, lineWidth: 1.5) }
                            }
                            .scaleEffect(appeared ? 1 : 0.2)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(r * 24 + c) * 0.002), value: appeared)
                            .onTapGesture {
                                withAnimation(.snappy) { selected = isSel ? nil : (r, c) }
                            }
                    }
                }
            }
            HStack {
                if let (r, c) = selected {
                    let day = days[r]
                    Text("\(Fmt.dayMonth.string(from: day.day)), \(c)h–\(c + 1)h")
                        .font(.caption.weight(.semibold)).foregroundStyle(Volt.ink)
                    Text(Fmt.num(day.hourly[c], 0) + " Wh")
                        .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Volt.amber)
                } else {
                    Text("Toque numa célula").font(.caption).foregroundStyle(Volt.inkFaint)
                }
                Spacer()
                HStack(spacing: 2) {
                    Text("menos").font(.system(size: 9)).foregroundStyle(Volt.inkFaint)
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Volt.heat(Double(i) / 4).opacity(0.25 + 0.75 * Double(i) / 4))
                            .frame(width: 10, height: 10)
                    }
                    Text("mais").font(.system(size: 9)).foregroundStyle(Volt.inkFaint)
                }
            }
            .padding(.top, 4)
            .animation(.snappy, value: selected.map { $0.0 * 100 + $0.1 })
        }
        .sensoryFeedback(.selection, trigger: selected.map { $0.0 * 100 + $0.1 })
        .onAppear { appeared = true }
    }
}

// MARK: - Gauge com fluxo de corrente

struct PowerGauge<Center: View>: View {
    let fraction: Double     // 0...1
    let active: Bool
    var flowSpeed: Double    // 0...1 (velocidade das "cargas")
    var lineWidth: CGFloat = 16
    @ViewBuilder var center: () -> Center

    private let start: Double = 0.125     // 135°
    private let sweep: Double = 0.75      // 270°

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Volt.grid, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))

            // marcações
            ForEach(0...30, id: \.self) { i in
                let major = i % 5 == 0
                Capsule()
                    .fill(Volt.inkFaint.opacity(major ? 0.7 : 0.35))
                    .frame(width: major ? 2 : 1, height: major ? 8 : 4)
                    .offset(y: -1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .rotationEffect(.degrees(-135 + Double(i) * 9))
                    .padding(lineWidth + 6)
            }

            Circle()
                .trim(from: 0, to: sweep * max(min(fraction, 1), 0.001))
                .stroke(
                    AngularGradient(colors: [Volt.arc, Volt.violet, Volt.amber, Volt.fault],
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .opacity(active ? 1 : 0.35)
                .rotationEffect(.degrees(135))
                .animation(.spring(response: 0.9, dampingFraction: 0.8), value: fraction)

            center()
        }
    }
}

// MARK: - Anel (orçamento etc.)

struct ProgressRing: View {
    let fraction: Double
    var color: Color = Volt.money
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Volt.grid, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(fraction > 1 ? Volt.fault : color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 1, dampingFraction: 0.8), value: fraction)
        }
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    var color: Color = Volt.arc

    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0
            let hi = max((values.max() ?? 1), lo + 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - CGFloat((v - lo) / (hi - lo))))
            }
            ChartMath.monotonePath(pts)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
