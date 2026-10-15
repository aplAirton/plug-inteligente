import SwiftUI

struct SettingsTab: View {
    @Bindable var model: PlugViewModel
    @Binding var appearance: Appearance
    @State private var confirmErase = false
    @State private var editingTariff = false
    @State private var hourlyCSV: URL?
    @State private var readingsCSV: URL?

    var body: some View {
        @Bindable var tariff = model.tariff
        @Bindable var cloud = model.cloud
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        ConnectionChip(model: model)
                    } label: {
                        Label("Estado", systemImage: "wifi")
                    }
                    TextField("IP da tomada", text: $model.lanHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("local_key (16 caracteres)", text: $model.lanLocalKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        model.connectLAN()
                    } label: {
                        Label("Reconectar", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.lanHost.isEmpty || model.lanLocalKey.count != 16)
                } header: {
                    Text("Conexão Wi-Fi local")
                } footer: {
                    Text("Comunicação direta com a tomada (protocolo Tuya 3.5), sem nuvem. Reserve o IP no roteador para que ele não mude.")
                }

                Section {
                    LabeledContent("Estado") {
                        HStack(spacing: 6) {
                            if model.cloud.isSyncing { ProgressView().controlSize(.small) }
                            Text(model.cloud.status.label).font(.footnote).multilineTextAlignment(.trailing)
                        }
                    }
                    TextField("Access ID", text: $cloud.clientID)
                    SecureField("Access Secret", text: $cloud.secret)
                    TextField("Device ID", text: $cloud.deviceID)
                    Button {
                        model.syncCloud(force: true)
                    } label: {
                        Label("Sincronizar agora", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.cloud.isConfigured || model.cloud.isSyncing)
                    Button(role: .destructive) {
                        model.reimportCloud()
                    } label: {
                        Label("Reimportar últimos 7 dias", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!model.cloud.isConfigured || model.cloud.isSyncing)
                    if let note = cloud.statisticsNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Histórico na nuvem Tuya")
                } footer: {
                    Text("A Tuya registra o consumo 24 h por dia e guarda 7 dias. O app importa a cada abertura e a cada 10 min, acumulando tudo neste iPhone — inclusive quando o app esteve fechado.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                NotificationsSection(alerts: model.alerts)

                Section("Tarifa") {
                    Button {
                        editingTariff = true
                    } label: {
                        LabeledContent {
                            Text("\(Fmt.money(tariff.effectivePrice))/kWh").monospacedDigit()
                        } label: {
                            Label("Tarifa e bandeira", systemImage: "brazilianrealsign.circle")
                        }
                    }
                    .tint(Volt.ink)
                }

                Section {
                    Stepper(value: $tariff.alertWatts, in: 100...3600, step: 100) {
                        LabeledContent("Alerta de potência", value: "\(Fmt.num(tariff.alertWatts, 0)) W")
                    }
                    Stepper(value: $tariff.voltageMin, in: 90...230, step: 1) {
                        LabeledContent("Tensão mínima", value: "\(Fmt.num(tariff.voltageMin, 0)) V")
                    }
                    Stepper(value: $tariff.voltageMax, in: 110...260, step: 1) {
                        LabeledContent("Tensão máxima", value: "\(Fmt.num(tariff.voltageMax, 0)) V")
                    }
                } header: {
                    Text("Alertas")
                } footer: {
                    Text("Faixa adequada ANEEL para 220 V: 202–231 V (127 V: 117–133 V). Eventos aparecem em Agora → Atividade.")
                }

                Section("Aparência") {
                    Picker("Tema", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if let url = hourlyCSV {
                        ShareLink(item: url) { Label("Exportar consumo por hora (CSV)", systemImage: "tablecells") }
                    }
                    if let url = readingsCSV {
                        ShareLink(item: url) { Label("Exportar leituras (CSV)", systemImage: "waveform") }
                    }
                    Button(role: .destructive) {
                        confirmErase = true
                    } label: {
                        Label("Apagar histórico", systemImage: "trash")
                    }
                } header: {
                    Text("Dados")
                } footer: {
                    Text("Tudo fica guardado só neste iPhone. Leituras detalhadas são mantidas por 14 dias; o consumo por hora fica guardado para sempre. A coleta acontece com o app aberto ou em segundo plano recente — períodos sem o app aparecem como lacunas.")
                }

                Section("Avançado") {
                    NavigationLink { BluetoothView(model: model) } label: {
                        Label("Bluetooth (pareamento BLE)", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink { RawDPView(model: model) } label: {
                        Label("Data points brutos", systemImage: "list.number")
                    }
                    NavigationLink { LogView(model: model) } label: {
                        Label("Log de comunicação", systemImage: "text.alignleft")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { CircuitBackground() }
            .navigationTitle("Ajustes")
            .task {
                hourlyCSV = model.energy.exportHourlyCSV()
                readingsCSV = model.energy.exportReadingsCSV()
            }
            .confirmationDialog("Apagar todo o histórico de consumo?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Apagar", role: .destructive) { model.energy.eraseAll() }
            }
            .sheet(isPresented: $editingTariff) {
                NavigationStack { TariffEditor(tariff: model.tariff) }
            }
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothView: View {
    @Bindable var model: PlugViewModel
    @State private var confirmPair = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(model.state.label, systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative, isActive: model.state == .scanning)
                    Spacer()
                    if model.state == .scanning {
                        Button("Parar") { model.stopScan() }
                    } else {
                        Button("Buscar") { model.scanAll = true; model.startScan() }
                    }
                }
                ForEach(model.devices.sorted { $0.rssi > $1.rssi }) { d in
                    Button {
                        Task { await model.connect(to: d) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).foregroundStyle(Volt.ink)
                                Text(d.isBound ? "Vinculado" : "Livre").font(.caption)
                                    .foregroundStyle(d.isBound ? Volt.amber : Volt.live)
                            }
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(Volt.inkSoft)
                        }
                    }
                    .disabled(model.isBusy)
                }
                if let status = model.pairStatusText {
                    Text(status).font(.caption).foregroundStyle(Volt.inkSoft)
                }
            } header: {
                Text("Dispositivos")
            } footer: {
                Text("Com a tomada já no Wi-Fi, o Bluetooth é apenas um canal de reserva/diagnóstico.")
            }

            Section("Credenciais BLE") {
                TextField("local_key", text: $model.localKey)
                TextField("device_id", text: $model.virtualID)
                TextField("UUID (16)", text: $model.uuidOverride)
                TextField("Chave de pareamento (6)", text: $model.customPairKey)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())

            Section {
                Button("Refazer handshake") { Task { await model.runHandshake() } }
                    .disabled(!model.state.isConnected || model.isBusy)
                Button("Vincular (PAIR)") { confirmPair = true }
                    .disabled(model.handshake == nil || model.isBusy)
                Button("Desconectar BLE", role: .destructive) { model.client.disconnect() }
                    .disabled(!model.state.isConnected)
            }
        }
        .scrollContentBackground(.hidden)
        .background { CircuitBackground() }
        .navigationTitle("Bluetooth")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("PAIR troca a chave da tomada e pode tirá-la do Smart Life.", isPresented: $confirmPair, titleVisibility: .visible) {
            Button("Vincular mesmo assim", role: .destructive) { Task { await model.pair() } }
        }
    }
}

// MARK: - DPs brutos

private struct RawDPView: View {
    let model: PlugViewModel
    @State private var dpID = ""
    @State private var type: TuyaDPType = .bool
    @State private var value = ""

    var body: some View {
        List {
            Section("Últimos valores") {
                if model.sortedLatest.isEmpty {
                    Text("Nenhum DP recebido ainda").foregroundStyle(Volt.inkSoft)
                }
                ForEach(model.sortedLatest) { dp in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("DP \(dp.dpID)").font(.subheadline.monospaced().weight(.semibold))
                            Text(dp.type.label).font(.caption).foregroundStyle(Volt.inkSoft)
                            Spacer()
                            Text(dp.decoded).monospacedDigit()
                        }
                        if let hint = model.interpretation(for: dp) {
                            Text(hint).font(.caption).foregroundStyle(Volt.inkSoft)
                        }
                    }
                }
            }
            Section("Enviar DP") {
                TextField("ID", text: $dpID).keyboardType(.numberPad)
                Picker("Tipo", selection: $type) {
                    ForEach(TuyaDPType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Valor", text: $value)
                Button("Enviar") {
                    guard let id = UInt8(dpID) else { return }
                    Task { await model.sendRawDP(id: id, type: type, value: value) }
                }
                .disabled(!model.canControl || UInt8(dpID) == nil)
            }
        }
        .scrollContentBackground(.hidden)
        .background { CircuitBackground() }
        .navigationTitle("Data points")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Log

private struct LogView: View {
    let model: PlugViewModel

    var body: some View {
        List(model.logs.suffix(400).reversed()) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.timeString).font(.caption2.monospaced()).foregroundStyle(Volt.inkFaint)
                    Text(entry.title).font(.caption.weight(.medium)).foregroundStyle(color(entry.kind))
                }
                if let detail = entry.detail {
                    Text(detail).font(.caption2).foregroundStyle(Volt.inkSoft)
                }
                if let bytes = entry.bytes, !bytes.isEmpty {
                    Text(bytes.spacedHexString).font(.caption2.monospaced()).foregroundStyle(Volt.inkFaint).lineLimit(3)
                }
            }
            .textSelection(.enabled)
        }
        .listStyle(.plain)
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                if let url = model.exportLog() { ShareLink("Exportar", item: url) }
                Button("Limpar", role: .destructive) { model.clearLogs() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: return Volt.ink
        case .tx: return Volt.arc
        case .rx: return Volt.violet
        case .error: return Volt.fault
        case .success: return Volt.live
        }
    }
}

// MARK: - Notificações

private struct NotificationsSection: View {
    @Bindable var alerts: AlertSettings

    var body: some View {
        Section {
            ForEach(AlertSettings.Trigger.allCases) { t in
                Toggle(isOn: Binding(get: { alerts.isOn(t) }, set: { alerts.enabled[t] = $0 })) {
                    Label(t.title, systemImage: t.icon)
                }
                if alerts.isOn(t) {
                    detail(t)
                }
            }
            Button {
                Notifier.post(.switched, title: "Teste de notificação", body: "As notificações da tomada estão funcionando.", force: true)
            } label: {
                Label("Enviar notificação de teste", systemImage: "bell.badge")
            }
        } header: {
            Text("Notificações")
        } footer: {
            Text("Com o app fechado, o iOS acorda o app periodicamente (geralmente a cada 15–60 min) para importar da nuvem e avaliar os gatilhos — os avisos podem chegar com esse atraso.")
        }
    }

    @ViewBuilder
    private func detail(_ t: AlertSettings.Trigger) -> some View {
        switch t {
        case .sustainedHigh:
            Stepper(value: $alerts.sustainedWatts, in: 100...3500, step: 50) {
                LabeledContent("Acima de", value: "\(Fmt.num(alerts.sustainedWatts, 0)) W").font(.subheadline)
            }
            Stepper(value: $alerts.sustainedMinutes, in: 10...240, step: 10) {
                LabeledContent("Por mais de", value: Fmt.duration(alerts.sustainedMinutes * 60)).font(.subheadline)
            }
        case .forgottenOn:
            Stepper(value: $alerts.forgottenHours, in: 1...24, step: 1) {
                LabeledContent("Ligada há", value: "\(Fmt.num(alerts.forgottenHours, 0)) h").font(.subheadline)
            }
        case .standby:
            Stepper(value: $alerts.standbyWatts, in: 1...30, step: 1) {
                LabeledContent("Abaixo de", value: "\(Fmt.num(alerts.standbyWatts, 0)) W").font(.subheadline)
            }
        case .unusualDay:
            Stepper(value: $alerts.unusualFactor, in: 1.2...3, step: 0.1) {
                LabeledContent("Acima da média", value: "+\(Fmt.num((alerts.unusualFactor - 1) * 100, 0))%").font(.subheadline)
            }
        default:
            EmptyView()
        }
    }
}
