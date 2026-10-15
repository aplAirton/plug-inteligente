import SwiftUI

struct DeviceTab: View {
    let model: PlugViewModel
    @State private var editing: UsageProfile?
    @State private var scheduling: UsageProfile?
    @State private var renaming = false

    var body: some View {
        VoltScreen(title: model.tariff.deviceName) {
            DeviceHeader(model: model) { renaming = true }
            TodayPlan(model: model)
            SchedulesSection(model: model) { scheduling = $0 }
            ProfilesSection(model: model) { editing = $0 }
            QuickTimer(model: model)
            BehaviorSection(model: model)
            DiagnosticsSection(model: model)
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(model: model, profile: profile)
        }
        .sheet(item: $scheduling) { item in
            ScheduleEditor(model: model, item: item)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $renaming) {
            IdentitySheet(tariff: model.tariff)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Cabeçalho

private struct DeviceHeader: View {
    let model: PlugViewModel
    let rename: () -> Void

    var body: some View {
        let m = model.metrics
        let isOn = m.isOn ?? false
        HStack(spacing: 16) {
            Button(action: rename) {
                Image(systemName: model.tariff.applianceIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isOn ? Volt.arc : Volt.inkFaint)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill((isOn ? Volt.arc : Volt.inkFaint).opacity(0.14)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(isOn ? "Ligada" : (m.isOn == nil ? "—" : "Desligada"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isOn ? Volt.ink : Volt.inkSoft)
                    .contentTransition(.interpolate)
                HStack(spacing: 8) {
                    if let w = m.powerW {
                        Text("\(Fmt.num(w, w < 100 ? 1 : 0)) W").monospacedDigit()
                    }
                    ConnectionChip(model: model)
                }
                .font(.subheadline)
                .foregroundStyle(Volt.inkSoft)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { v in Task { await model.setSwitch(v) } }))
                .labelsHidden()
                .tint(Volt.arc)
                .scaleEffect(1.25)
                .disabled(!model.canControl)
        }
        .voltCard()
        .sensoryFeedback(.impact(weight: .medium), trigger: m.isOn)
        .animation(.snappy, value: isOn)
    }
}

// MARK: - Plano de hoje

private struct TodayPlan: View {
    let model: PlugViewModel

    var body: some View {
        let plan = model.profiles.todayPlan()
        let next = model.profiles.nextAction()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Hoje")
                Spacer()
                if let (date, on, profile) = next {
                    Text("\(on ? "Liga" : "Desliga") \(relative(date)) · \(profile.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(on ? Volt.live : Volt.fault)
                }
            }
            DayTimeline(plan: plan, showNow: true)
            if plan.allSatisfy({ $0 == nil }) {
                Text("Nenhum perfil ativo para hoje. A tomada fica como você deixar.")
                    .font(.footnote).foregroundStyle(Volt.inkSoft)
            }
        }
        .voltCard()
    }

    private func relative(_ d: Date) -> String {
        let cal = Calendar.current
        let time = Fmt.hourMinute.string(from: d)
        if cal.isDateInToday(d) { return "às \(time)" }
        if cal.isDateInTomorrow(d) { return "amanhã \(time)" }
        return "\(Fmt.weekdayShort.string(from: d)) \(time)"
    }
}

/// Faixa de 24 h: verde = ligada, vermelho = desligada, cinza = livre.
struct DayTimeline: View {
    let plan: [Bool?]
    var showNow = false
    var height: CGFloat = 26

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Volt.grid)
                    ForEach(segments, id: \.start) { seg in
                        Rectangle()
                            .fill(seg.on ? Volt.live : Volt.fault.opacity(0.75))
                            .frame(width: w * CGFloat(seg.end - seg.start) / 1440)
                            .offset(x: w * CGFloat(seg.start) / 1440)
                    }
                }
                .clipShape(Capsule())
                .overlay(alignment: .leading) {
                    if showNow {
                        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
                        let m = (now.hour ?? 0) * 60 + (now.minute ?? 0)
                        Capsule().fill(Volt.ink)
                            .frame(width: 3, height: height + 8)
                            .offset(x: w * CGFloat(m) / 1440 - 1.5)
                    }
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
            }
            .frame(height: height + 8)
            if height > 12 {
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text("\(h)h")
                        if h < 24 { Spacer() }
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Volt.inkFaint)
            }
        }
        .animation(.snappy, value: plan)
    }

    private struct Segment { let start: Int; let end: Int; let on: Bool }

    private var segments: [Segment] {
        var out: [Segment] = []
        var start = 0
        var current = plan.first ?? nil
        for m in 1...1440 {
            let v: Bool? = m < 1440 ? plan[m] : nil
            if v != current || m == 1440 {
                if let c = current { out.append(Segment(start: start, end: m, on: c)) }
                start = m
                current = v
            }
        }
        return out
    }
}

// MARK: - Perfis

private struct ProfilesSection: View {
    let model: PlugViewModel
    let edit: (UsageProfile) -> Void

    var body: some View {
        let store = model.profiles
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Perfis de uso")
                Spacer()
                Menu {
                    Button("Perfil em branco", systemImage: "plus") {
                        edit(UsageProfile(name: "Novo perfil", icon: "clock.fill", colorIndex: store.profiles.count,
                                          days: [1, 2, 3, 4, 5],
                                          events: [ScheduleEvent(minutes: 7 * 60, turnOn: true),
                                                   ScheduleEvent(minutes: 22 * 60, turnOn: false)]))
                    }
                    Section("Modelos") {
                        ForEach(UsageProfile.templates, id: \.name) { t in
                            Button(t.name, systemImage: t.icon) {
                                var copy = t
                                copy.id = UUID()
                                copy.events = t.events.map { ScheduleEvent(minutes: $0.minutes, turnOn: $0.turnOn) }
                                edit(copy)
                            }
                        }
                    }
                } label: {
                    Label("Novo", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Volt.ink))
                        .foregroundStyle(Volt.onInk)
                }
            }

            if !store.profiles.contains(where: { !$0.simple }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Crie rotinas de liga/desliga").font(.headline).foregroundStyle(Volt.ink)
                    Text("Ex.: desligar à noite e religar de manhã nos dias úteis. Os horários rodam na nuvem Tuya — funcionam mesmo com o iPhone desligado.")
                        .font(.footnote).foregroundStyle(Volt.inkSoft)
                }
                .padding(.vertical, 4)
            }

            let list = store.profiles.filter { !$0.simple }
            ForEach(list) { p in
                ProfileRow(model: model, profile: p) { edit(p) }
                if p.id != list.last?.id { Divider() }
            }

        }
        .voltCard()
    }
}

// MARK: - Agendamentos simples

private struct SchedulesSection: View {
    let model: PlugViewModel
    let edit: (UsageProfile) -> Void

    var body: some View {
        let list = model.profiles.profiles.filter(\.simple).sorted { $0.events.first?.minutes ?? 0 < $1.events.first?.minutes ?? 0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Agendamentos")
                Spacer()
                Button {
                    let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
                    let c = Calendar.current.dateComponents([.hour], from: next)
                    edit(UsageProfile(name: "", icon: "clock.fill", colorIndex: 0, days: [],
                                      events: [ScheduleEvent(minutes: (c.hour ?? 0) * 60, turnOn: !(model.metrics.isOn ?? false))],
                                      isSimple: true, onceDate: Date()))
                } label: {
                    Label("Agendar", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Volt.ink))
                        .foregroundStyle(Volt.onInk)
                }
                .buttonStyle(.plain)
            }
            if list.isEmpty {
                Text("Ligue ou desligue num horário — uma vez ou repetindo nos dias que escolher.")
                    .font(.footnote).foregroundStyle(Volt.inkSoft)
            }
            ForEach(list) { item in
                ScheduleRow(model: model, item: item) { edit(item) }
                if item.id != list.last?.id { Divider() }
            }
            if let err = model.profiles.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Volt.fault)
            }
        }
        .voltCard()
    }
}

private struct ScheduleRow: View {
    let model: PlugViewModel
    let item: UsageProfile
    let open: () -> Void

    var body: some View {
        let ev = item.events.first
        let on = ev?.turnOn ?? true
        let syncing = model.profiles.syncing.contains(item.id)
        HStack(spacing: 14) {
            Text(ev?.timeString ?? "--:--")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(item.isActive ? Volt.ink : Volt.inkFaint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(on ? Volt.live : Volt.fault).frame(width: 7, height: 7)
                    Text(on ? "Ligar" : "Desligar").font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.isActive ? Volt.ink : Volt.inkSoft)
                }
                Text(item.daysSummary).font(.caption).foregroundStyle(Volt.inkSoft)
            }
            Spacer()
            if syncing {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { item.isActive },
                    set: { v in Task { await model.profiles.setActive(item.id, v, cloud: model.cloud) } }
                ))
                .labelsHidden()
                .tint(on ? Volt.live : Volt.fault)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

private struct ScheduleEditor: View {
    let model: PlugViewModel
    @State var item: UsageProfile
    @State private var time = Date()
    @State private var repeats = false
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private let dayLetters = ["D", "S", "T", "Q", "Q", "S", "S"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Ação", selection: Binding(
                        get: { item.events.first?.turnOn ?? true },
                        set: { item.events[0].turnOn = $0 })) {
                        Text("Ligar").tag(true)
                        Text("Desligar").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section {
                    Toggle("Repetir", isOn: $repeats.animation(.snappy))
                    if repeats {
                        HStack {
                            ForEach(0..<7, id: \.self) { d in
                                let on = item.days.contains(d)
                                Text(dayLetters[d])
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(on ? Volt.onInk : Volt.inkSoft)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(on ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
                                    .onTapGesture { if on { item.days.remove(d) } else { item.days.insert(d) } }
                                if d < 6 { Spacer(minLength: 0) }
                            }
                        }
                        .sensoryFeedback(.selection, trigger: item.days)
                        HStack(spacing: 8) {
                            chip("Todo dia", Set(0...6))
                            chip("Dias úteis", [1, 2, 3, 4, 5])
                            chip("Fim de semana", [0, 6])
                        }
                    } else {
                        LabeledContent("Executa", value: onceLabel)
                    }
                } footer: {
                    Text("Roda na nuvem Tuya: funciona com o iPhone desligado.")
                }

                if model.profiles.profiles.contains(where: { $0.id == item.id }) {
                    Section {
                        Button("Excluir agendamento", role: .destructive) {
                            Task {
                                await model.profiles.delete(item.id, cloud: model.cloud)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Agendamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Salvar") { save() }
                            .fontWeight(.semibold)
                            .disabled(repeats && item.days.isEmpty)
                    }
                }
            }
            .onAppear {
                time = item.events.first?.date ?? Date()
                repeats = !item.days.isEmpty
                if !repeats { item.days = [] }
            }
        }
    }

    /// Próxima ocorrência do horário (hoje se ainda não passou, senão amanhã).
    private var nextOnce: Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: time)
        let today = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: Date())!
        return today > Date() ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }

    private var onceLabel: String {
        let d = nextOnce
        return (Calendar.current.isDateInToday(d) ? "Hoje" : "Amanhã") + " às " + Fmt.hourMinute.string(from: d)
    }

    private func chip(_ label: String, _ set: Set<Int>) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(item.days == set ? Volt.onInk : Volt.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(item.days == set ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
            .onTapGesture { item.days = set }
    }

    private func save() {
        saving = true
        item.events[0].date = time
        if !repeats {
            item.days = []
            item.onceDate = nextOnce
        } else {
            item.onceDate = nil
        }
        let on = item.events[0].turnOn
        item.name = "\(on ? "Ligar" : "Desligar") às \(item.events[0].timeString)"
        item.isActive = true
        item.colorIndex = on ? 3 : 4
        Task {
            await model.profiles.upsert(item, cloud: model.cloud)
            saving = false
            dismiss()
        }
    }
}

private struct ProfileRow: View {
    let model: PlugViewModel
    let profile: UsageProfile
    let open: () -> Void

    var body: some View {
        let syncing = model.profiles.syncing.contains(profile.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: profile.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(profile.color)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(profile.color.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body.weight(.semibold)).foregroundStyle(Volt.ink)
                    Text(profile.daysSummary + " · " + profile.sortedEvents.map { "\($0.turnOn ? "↑" : "↓")\($0.timeString)" }.joined(separator: " "))
                        .font(.caption.monospacedDigit()).foregroundStyle(Volt.inkSoft)
                        .lineLimit(1)
                }
                Spacer()
                if syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { profile.isActive },
                        set: { v in Task { await model.profiles.setActive(profile.id, v, cloud: model.cloud) } }
                    ))
                    .labelsHidden()
                    .tint(profile.color)
                }
            }
            DayTimeline(plan: (0..<1440).map { profile.state(atMinute: $0) }, height: 8)
                .opacity(profile.isActive ? 1 : 0.4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .sensoryFeedback(.success, trigger: profile.isActive)
    }
}

// MARK: - Editor de perfil

private struct ProfileEditor: View {
    let model: PlugViewModel
    @State var profile: UsageProfile
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var saving = false

    private let dayLetters = ["D", "S", "T", "Q", "Q", "S", "S"]
    private let icons = ["clock.fill", "moon.stars.fill", "sun.max.fill", "briefcase.fill", "house.fill",
                         "bed.double.fill", "bolt.slash.fill", "leaf.fill", "airplane", "gamecontroller.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome", text: $profile.name).font(.title3.weight(.semibold))
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(icons, id: \.self) { icon in
                                let sel = icon == profile.icon
                                Image(systemName: icon)
                                    .foregroundStyle(sel ? Volt.onInk : profile.color)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(sel ? AnyShapeStyle(profile.color) : AnyShapeStyle(profile.color.opacity(0.12))))
                                    .onTapGesture { profile.icon = icon }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    HStack {
                        ForEach(UsageProfile.palette.indices, id: \.self) { i in
                            Circle().fill(UsageProfile.palette[i])
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Volt.ink, lineWidth: profile.colorIndex == i ? 2.5 : 0))
                                .onTapGesture { profile.colorIndex = i }
                            if i < UsageProfile.palette.count - 1 { Spacer() }
                        }
                    }
                }

                Section("Dias") {
                    HStack {
                        ForEach(0..<7, id: \.self) { d in
                            let on = profile.days.contains(d)
                            Text(dayLetters[d])
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(on ? Volt.onInk : Volt.inkSoft)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(on ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
                                .onTapGesture {
                                    if on { profile.days.remove(d) } else { profile.days.insert(d) }
                                }
                            if d < 6 { Spacer(minLength: 0) }
                        }
                    }
                    .sensoryFeedback(.selection, trigger: profile.days)
                    HStack(spacing: 8) {
                        quickDays("Todos", Set(0...6))
                        quickDays("Úteis", [1, 2, 3, 4, 5])
                        quickDays("Fim de semana", [0, 6])
                    }
                }

                Section {
                    ForEach($profile.events) { $event in
                        HStack {
                            Picker("", selection: $event.turnOn) {
                                Text("Ligar").tag(true)
                                Text("Desligar").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            Spacer()
                            DatePicker("", selection: $event.date, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    .onDelete { profile.events.remove(atOffsets: $0) }
                    Button {
                        let last = profile.sortedEvents.last
                        profile.events.append(ScheduleEvent(minutes: min((last?.minutes ?? 420) + 120, 1439),
                                                            turnOn: !(last?.turnOn ?? false)))
                    } label: {
                        Label("Adicionar horário", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Horários")
                } footer: {
                    Text("Deslize para a esquerda para remover um horário.")
                }

                Section("Prévia do dia") {
                    DayTimeline(plan: (0..<1440).map { profile.state(atMinute: $0) })
                        .padding(.vertical, 6)
                    SavingsEstimate(model: model, profile: profile)
                }

                if model.profiles.profiles.contains(where: { $0.id == profile.id }) {
                    Section {
                        Button("Excluir perfil", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(profile.name.isEmpty ? "Perfil" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Salvar") {
                            saving = true
                            Task {
                                var p = profile
                                if !model.profiles.profiles.contains(where: { $0.id == p.id }) { p.isActive = true }
                                await model.profiles.upsert(p, cloud: model.cloud)
                                saving = false
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(profile.events.isEmpty || profile.days.isEmpty || profile.name.isEmpty)
                    }
                }
            }
            .confirmationDialog("Excluir \"\(profile.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Excluir", role: .destructive) {
                    Task {
                        await model.profiles.delete(profile.id, cloud: model.cloud)
                        dismiss()
                    }
                }
            }
        }
        .tint(profile.color)
    }

    private func quickDays(_ label: String, _ set: Set<Int>) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(profile.days == set ? Volt.onInk : Volt.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(profile.days == set ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
            .onTapGesture { profile.days = set }
    }
}

/// Economia estimada: consumo médio histórico nas horas em que o perfil desliga.
private struct SavingsEstimate: View {
    let model: PlugViewModel
    let profile: UsageProfile

    var body: some View {
        let days = model.energy.lastDays(7).filter { $0.coveredSeconds > 6 * 3600 }
        let hourAvgWh = (0..<24).map { h in days.isEmpty ? 0 : days.map { $0.hourly[h] }.reduce(0, +) / Double(days.count) }
        let offWhPerDay = (0..<1440).reduce(0.0) { acc, m in
            profile.state(atMinute: m) == false ? acc + hourAvgWh[m / 60] / 60 : acc
        }
        let kWhMonth = offWhPerDay / 1000 * Double(profile.days.count) / 7 * 30
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Desligada \(Fmt.duration(Double(profile.offMinutesPerDay * 60)))/dia")
                    .font(.subheadline.weight(.semibold))
                Text(days.isEmpty ? "Sem histórico suficiente para estimar" : "Pelo consumo médio dos últimos 7 dias")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !days.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(Fmt.money(model.tariff.cost(kWhMonth)))/mês")
                        .font(.headline.monospacedDigit()).foregroundStyle(Volt.money)
                    Text("\(Fmt.num(kWhMonth, 1)) kWh").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Temporizador rápido

private struct QuickTimer: View {
    let model: PlugViewModel
    @State private var minutes = 30
    private let presets = [5, 15, 30, 60, 120, 240]

    var body: some View {
        let isOn = model.metrics.isOn ?? false
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Temporizador rápido")
            if let end = model.countdownEnd, end > Date() {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    let remaining = max(end.timeIntervalSince(tl.date), 0)
                    HStack(spacing: 16) {
                        ProgressRing(fraction: model.countdownTotal > 0 ? remaining / model.countdownTotal : 0,
                                     color: Volt.amber, lineWidth: 6)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(countdown(remaining))
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Volt.ink)
                                .contentTransition(.numericText(countsDown: true))
                            Text(isOn ? "até desligar" : "até ligar").font(.caption).foregroundStyle(Volt.inkSoft)
                        }
                        Spacer()
                        Button("Cancelar", role: .destructive) { model.setCountdown(0) }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { m in
                        let sel = m == minutes
                        Text(m < 60 ? "\(m)m" : "\(m / 60)h")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(sel ? Volt.onInk : Volt.ink)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(sel ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
                            .onTapGesture { withAnimation(.snappy) { minutes = m } }
                    }
                }
                .sensoryFeedback(.selection, trigger: minutes)
                Button {
                    model.setCountdown(minutes * 60)
                } label: {
                    Text("\(isOn ? "Desligar" : "Ligar") em \(Fmt.duration(Double(minutes * 60)))")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(Volt.onInk)
                        .background(Capsule().fill(Volt.ink))
                }
                .buttonStyle(.plain)
                .disabled(!model.canControl)
                .opacity(model.canControl ? 1 : 0.4)
            }
        }
        .voltCard()
        .animation(.snappy, value: model.countdownEnd)
    }

    private func countdown(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - Comportamento

private struct BehaviorSection: View {
    let model: PlugViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Comportamento")
            Segmented(title: "Quando a energia voltar",
                      options: [("off", "Desligada"), ("on", "Ligada"), ("memory", "Como estava")],
                      current: model.dpString(38)) { model.setDP(38, $0) }
            Segmented(title: "Luz indicadora",
                      options: [("relay", "Mostra estado"), ("pos", "Localizar"), ("none", "Apagada")],
                      current: model.dpString(40)) { model.setDP(40, $0) }
            SwitchRow(title: "Trava infantil", detail: "Bloqueia o botão físico",
                      value: model.dpBool(41)) { model.setDP(41, $0) }
            SwitchRow(title: "Proteção de sobrecarga", detail: "Corta acima do limite de corrente",
                      value: model.dpBool(39)) { model.setDP(39, $0) }
        }
        .voltCard()
        .disabled(!model.canControl)
    }
}

private struct Segmented: View {
    let title: String
    let options: [(String, String)]
    let current: String?
    let set: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Volt.ink)
            HStack(spacing: 4) {
                ForEach(options, id: \.0) { value, label in
                    let sel = current == value
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(sel ? Volt.onInk : Volt.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(sel ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Color.clear)))
                        .contentShape(Rectangle())
                        .onTapGesture { set(value) }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Volt.surfaceRaised))
            .animation(.snappy, value: current)
            .sensoryFeedback(.selection, trigger: current)
        }
    }
}

private struct SwitchRow: View {
    let title: String
    let detail: String
    let value: Bool?
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Volt.ink)
                Text(detail).font(.caption).foregroundStyle(Volt.inkSoft)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { value ?? false }, set: set))
                .labelsHidden()
                .tint(Volt.arc)
                .opacity(value == nil ? 0.4 : 1)
        }
    }
}

// MARK: - Diagnóstico

private struct DiagnosticsSection: View {
    let model: PlugViewModel

    var body: some View {
        let fault = model.dpInt(26) ?? 0
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Diagnóstico")
            HStack(spacing: 8) {
                Circle().fill(fault == 0 ? Volt.live : Volt.fault).frame(width: 8, height: 8)
                Text(fault == 0 ? "Sem falhas" : "Falha reportada (código \(fault))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Volt.ink)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Modelo", "AMG-T01 · 16 A")
                row("Conexão", model.lanHost.isEmpty ? "—" : "\(model.lanHost) · Tuya 3.5")
                row("Nuvem", model.cloud.isConfigured ? model.cloud.status.label : "Não configurada")
                row("Calibração", [22, 23, 24, 25].compactMap { model.dpInt(UInt8($0)).map(String.init) }.joined(separator: " · "))
                if let first = model.energy.firstRecord {
                    row("Histórico desde", first.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "pt_BR"))))
                }
            }
        }
        .voltCard()
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.caption).foregroundStyle(Volt.inkSoft)
            Text(v.isEmpty ? "—" : v).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Volt.ink)
        }
    }
}

// MARK: - Nome e ícone

private struct IdentitySheet: View {
    @Bindable var tariff: TariffSettings
    @Environment(\.dismiss) private var dismiss

    static let icons = [
        "powerplug.fill", "tv.fill", "refrigerator.fill", "washer.fill", "air.conditioner.horizontal.fill",
        "fan.fill", "lamp.desk.fill", "lightbulb.fill", "laptopcomputer", "desktopcomputer",
        "heater.vertical.fill", "microwave.fill", "oven.fill", "dishwasher.fill", "cup.and.saucer.fill",
        "gamecontroller.fill", "printer.fill", "wifi.router.fill", "bolt.car.fill", "drop.fill",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") { TextField("Nome", text: $tariff.deviceName) }
                Section("O que está ligado nela") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            let sel = icon == tariff.applianceIcon
                            Image(systemName: icon)
                                .font(.title3)
                                .foregroundStyle(sel ? Volt.onInk : Volt.ink)
                                .frame(width: 50, height: 50)
                                .background(Circle().fill(sel ? AnyShapeStyle(Volt.ink) : AnyShapeStyle(Volt.surfaceRaised)))
                                .onTapGesture { tariff.applianceIcon = icon }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Identificação")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
