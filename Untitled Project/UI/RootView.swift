import SwiftUI
import UserNotifications

enum AppTab: String, CaseIterable {
    case live, usage, cost, device, settings
}

enum Appearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @State private var model = PlugViewModel.shared
    @State private var tab: AppTab = ContentView.launchTab
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            Tab("Agora", systemImage: "bolt.fill", value: .live) {
                LiveTab(model: model)
            }
            Tab("Consumo", systemImage: "chart.bar.xaxis", value: .usage) {
                UsageTab(model: model)
            }
            Tab("Custos", systemImage: "brazilianrealsign.circle.fill", value: .cost) {
                CostTab(model: model)
            }
            Tab("Tomada", systemImage: "powerplug.portrait.fill", value: .device) {
                DeviceTab(model: model)
            }
            Tab("Ajustes", systemImage: "gearshape.fill", value: .settings) {
                SettingsTab(model: model, appearance: $appearance)
            }
        }
        .tint(Volt.arc)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .preferredColorScheme(ContentView.launchScheme ?? appearance.scheme)
        .sensoryFeedback(.selection, trigger: tab)
        .onChange(of: phase) { _, new in
            switch new {
            case .active: model.resume()
            case .background: model.suspend()
            default: break
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--notiftest") {
                for _ in 0..<60 {
                    let st = await UNUserNotificationCenter.current().notificationSettings()
                    if st.authorizationStatus == .authorized { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                let st = await UNUserNotificationCenter.current().notificationSettings()
                print("[TUYA] NOTIF auth=\(st.authorizationStatus.rawValue) alert=\(st.alertSetting.rawValue)")
                try? await Task.sleep(for: .seconds(8))
                Notifier.post(.sustainedHigh, title: "Consumo alto há 1h", body: "\(model.tariff.deviceName) está acima de 800 W sem parar (teste).", force: true)
                try? await Task.sleep(for: .seconds(2))
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                print("[TUYA] NOTIF entregues=\(delivered.count) \(delivered.map(\.request.content.title))")
            } else if ProcessInfo.processInfo.arguments.contains("--timertest") {
                // Teste do fluxo real: agendamento recorrente → nuvem → remoção
                let p = UsageProfile(name: "teste", icon: "clock.fill", colorIndex: 0, days: Set(0...6),
                                     events: [ScheduleEvent(minutes: 3 * 60, turnOn: true)], isActive: true, isSimple: true)
                await model.profiles.upsert(p, cloud: model.cloud)
                print("[TUYA] TIMERTEST upsert ativo=\(model.profiles.profiles.first { $0.id == p.id }?.isActive ?? false) erro=\(model.profiles.lastError ?? "nenhum")")
                try? await Task.sleep(for: .seconds(20))
                await model.profiles.delete(p.id, cloud: model.cloud)
                print("[TUYA] TIMERTEST removido erro=\(model.profiles.lastError ?? "nenhum")")
            } else if ProcessInfo.processInfo.arguments.contains("--lantest") {
                await model.runLanTest()
            } else if ProcessInfo.processInfo.arguments.contains("--autotest") {
                await model.runAutotest()
            }
        }
    }

    // Argumentos de launch para testes visuais: --tab usage  --dark / --light
    private static var launchTab: AppTab {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let t = AppTab(rawValue: args[i + 1]) { return t }
        return .live
    }

    private static var launchScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--dark") { return .dark }
        if args.contains("--light") { return .light }
        return nil
    }
}

/// Container padrão das abas: navegação + fundo elétrico.
struct VoltScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--bottom") ? .bottom : ProcessInfo.processInfo.arguments.contains("--mid") ? .center : .top)
            .background { CircuitBackground() }
            .navigationTitle(title)
        }
    }
}

/// Indicador de conexão no topo das abas.
struct ConnectionChip: View {
    let model: PlugViewModel

    var body: some View {
        let (text, color, icon): (String, Color, String) = {
            switch model.lanState {
            case .ready: return ("Ao vivo", Volt.live, "dot.radiowaves.left.and.right")
            case .connecting, .negotiating: return ("Conectando", Volt.amber, "wifi")
            case .failed: return ("Reconectando", Volt.fault, "wifi.exclamationmark")
            case .idle: return (PlugViewModel.isDemo ? "Demonstração" : "Offline", Volt.inkSoft, "wifi.slash")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .symbolEffect(.variableColor.iterative, isActive: model.lanState == .connecting || model.lanState == .negotiating)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.3)))
        .animation(.snappy, value: text)
    }
}
