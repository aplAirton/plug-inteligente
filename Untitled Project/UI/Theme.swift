import SwiftUI
import UIKit

// MARK: - Paleta elétrica (claro/escuro)

extension Color {
    fileprivate init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    fileprivate init(hex: UInt32) { self.init(light: hex, dark: hex) }
}

enum Volt {
    static let canvas = Color(light: 0xF3F5FA, dark: 0x070B14)
    static let surface = Color(light: 0xFFFFFF, dark: 0x0F1524)
    static let surfaceRaised = Color(light: 0xE9EDF4, dark: 0x161E31)
    static let stroke = Color(light: 0xDDE3EC, dark: 0x1F2A42)
    static let grid = Color(light: 0xE3E8F0, dark: 0x1A2338)

    static let ink = Color(light: 0x0B1220, dark: 0xEEF3FF)
    /// Texto sobre `ink` (controles selecionados).
    static let onInk = Color(light: 0xFFFFFF, dark: 0x070B14)
    static let inkSoft = Color(light: 0x5B6579, dark: 0x8C98B3)
    static let inkFaint = Color(light: 0x99A3B8, dark: 0x56627D)

    static let arc = Color(light: 0x0090C8, dark: 0x2FD6FF)
    static let amber = Color(light: 0xE09A00, dark: 0xFFC53D)
    static let violet = Color(light: 0x6A4CF5, dark: 0x9C86FF)
    static let live = Color(light: 0x0FA968, dark: 0x3CF0A0)
    static let fault = Color(light: 0xE5484D, dark: 0xFF6369)
    static let money = Color(light: 0x17905B, dark: 0x5BE3A4)

    static func heat(_ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        if t < 0.5 { return arc.mix(with: amber, by: t * 2) }
        return amber.mix(with: fault, by: (t - 0.5) * 2)
    }
}

// MARK: - Componentes de superfície

/// Seção "aberta": conteúdo direto sobre o fundo, separado por respiro e linha fina.
struct VoltCard: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Volt.stroke).frame(height: 0.5)
            }
    }
}

extension View {
    func voltCard(padding: CGFloat = 16, radius: CGFloat = 22) -> some View {
        modifier(VoltCard(padding: padding, radius: radius))
    }

}

/// Fundo liso.
struct CircuitBackground: View {
    var body: some View {
        Volt.canvas.ignoresSafeArea()
    }
}

/// Cabeçalho de seção em caixa alta, discreto.
struct SectionLabel: View {
    let text: String
    var icon: String?
    var trailing: AnyView?

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.caption2.weight(.bold)).tracking(1.2)
        }
        .foregroundStyle(Volt.inkSoft)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Seletor em cápsula com indicador deslizante.
struct PillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Text(label(option))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(selected ? Volt.onInk : Volt.inkSoft)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            Capsule().fill(Volt.ink)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { selection = option }
                    }
            }
        }
        .padding(4)
        .background(Capsule().fill(Volt.surfaceRaised).overlay(Capsule().strokeBorder(Volt.stroke)))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Formatação

enum Fmt {
    static let brl: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    static func money(_ v: Double) -> String { brl.string(from: NSNumber(value: v)) ?? "R$ —" }

    static func num(_ v: Double, _ digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "pt_BR")))
    }

    /// kWh com casas adaptativas; abaixo de 1 kWh mostra Wh.
    static func energy(_ kwh: Double) -> (String, String) {
        if kwh < 1 { return (num(kwh * 1000, 0), "Wh") }
        return (num(kwh, kwh < 10 ? 2 : 1), "kWh")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }

    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE"
        return f
    }()

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM"
        return f
    }()

    static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
