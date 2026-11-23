import SwiftUI
import Charts
import UserNotifications

// MARK: - Données

struct Current: Codable { var start: Date; var goal: Double }
struct Fast: Codable, Identifiable { var id = UUID(); var start: Date; var end: Date; var goal: Double
    var hours: Double { end.timeIntervalSince(start) / 3600 } }
struct Weigh: Codable, Identifiable { var id = UUID(); var date: Date; var kg: Double }

struct AppState: Codable {
    var goal = 16.0
    var current: Current?
    var fasts: [Fast] = []
    var weights: [Weigh] = []
    var water = 0
    var waterDay = ""
    var remind = 0 // minutes, 0 = désactivé
}

final class Store: ObservableObject {
    @Published var s: AppState { didSet { save() } }
    let waterGoal = 8

    init() {
        if let d = UserDefaults.standard.data(forKey: "state"),
           let v = try? JSONDecoder().decode(AppState.self, from: d) { s = v } else { s = AppState() }
        rolloverWater()
    }

    func save() {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "state") }
    }

    func rolloverWater() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let k = f.string(from: Date())
        if s.waterDay != k { s.waterDay = k; s.water = 0 }
    }

    func begin() {
        s.current = Current(start: Date(), goal: s.goal)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleGoal()
    }

    func end() {
        guard let c = s.current else { return }
        s.fasts.append(Fast(start: c.start, end: Date(), goal: c.goal))
        s.current = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["goal"])
    }

    func scheduleGoal() {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["goal"])
        guard let cur = s.current else { return }
        let delay = cur.start.addingTimeInterval(cur.goal * 3600).timeIntervalSinceNow
        guard delay > 1 else { return }
        let m = UNMutableNotificationContent()
        m.title = "Objectif atteint"
        m.body = "Vous avez jeûné \(String(format: "%g", cur.goal)) h. Bravo !"
        m.sound = .default
        c.add(UNNotificationRequest(identifier: "goal", content: m,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
    }

    func scheduleWater() {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["water"])
        guard s.remind > 0 else { return }
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let m = UNMutableNotificationContent()
        m.title = "Hydratation"
        m.body = "Pensez à boire un verre d’eau."
        m.sound = .default
        c.add(UNNotificationRequest(identifier: "water", content: m,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(s.remind * 60), repeats: true)))
    }
}

// MARK: - Outils

func hms(_ t: TimeInterval) -> String {
    let s = Int(max(0, t)); return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}
func hm(_ t: TimeInterval) -> String {
    let m = Int((t / 60).rounded()); return "\(m / 60) h \(String(format: "%02d", m % 60))"
}
func phase(_ h: Double) -> String {
    switch h {
    case ..<4: return "Digestion : le dernier repas est encore en cours d’absorption."
    case ..<12: return "Glycémie en baisse : les réserves de sucre commencent à servir."
    case ..<16: return "Transition : le corps puise davantage dans les graisses."
    case ..<24: return "Brûlage des graisses : jeûne bien établi."
    default: return "Jeûne prolongé : pensez à bien vous hydrater."
    }
}

// MARK: - Écrans

struct FastView: View {
    @EnvironmentObject var st: Store
    @State private var confirmEnd = false
    let presets: [Double] = [12, 16, 18, 20, 23]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if st.s.current == nil {
                        HStack {
                            ForEach(presets, id: \.self) { g in
                                Button("\(Int(g)) h") { st.s.goal = g }
                                    .buttonStyle(.bordered)
                                    .tint(st.s.goal == g ? Color.teal : Color.gray)
                            }
                        }
                        Stepper("Durée : \(st.s.goal, specifier: "%g") h", value: $st.s.goal, in: 1...72, step: 0.5)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in ring(now: ctx.date) }
                    Button(st.s.current == nil ? "Commencer le jeûne" : "Terminer le jeûne") {
                        if st.s.current == nil { st.begin() } else { confirmEnd = true }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                    if st.s.current != nil {
                        DatePicker("Heure de début", selection: Binding(
                            get: { st.s.current?.start ?? Date() },
                            set: { st.s.current?.start = $0; st.scheduleGoal() }), in: ...Date())
                    }
                }
                .padding()
            }
            .navigationTitle("Jeûne")
            .alert("Terminer ce jeûne ?", isPresented: $confirmEnd) {
                Button("Terminer", role: .destructive) { st.end() }
                Button("Annuler", role: .cancel) {}
            }
        }
    }

    func ring(now: Date) -> some View {
        let goal = (st.s.current?.goal ?? st.s.goal) * 3600
        let el = st.s.current.map { now.timeIntervalSince($0.start) } ?? 0
        let p = min(1, el / goal)
        let sub = st.s.current == nil ? "Objectif : \(String(format: "%g", st.s.goal)) h"
            : (el >= goal ? "Objectif atteint, +\(hm(el - goal))" : "Reste \(hm(goal - el))")
        return VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 16)
                Circle().trim(from: 0, to: p)
                    .stroke(el >= goal ? Color.orange : Color.teal, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    Text(hms(el)).font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(sub).foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, height: 280)
            Text(st.s.current == nil ? "Choisissez une durée, puis lancez le chronomètre." : phase(el / 3600))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

struct WeightView: View {
    @EnvironmentObject var st: Store
    @State private var input = ""

    var body: some View {
        NavigationStack {
            let sorted = st.s.weights.sorted { $0.date > $1.date }
            List {
                Section {
                    HStack {
                        TextField("Poids en kg", text: $input).keyboardType(.decimalPad)
                        Button("Ajouter") {
                            if let v = Double(input.replacingOccurrences(of: ",", with: ".")), v > 20, v < 400 {
                                st.s.weights.append(Weigh(date: Date(), kg: v)); input = ""
                            }
                        }.buttonStyle(.borderedProminent).tint(.teal)
                    }
                }
                if sorted.count > 1 {
                    Section("Évolution") {
                        Chart(sorted.reversed()) { w in
                            LineMark(x: .value("Date", w.date), y: .value("kg", w.kg))
                            PointMark(x: .value("Date", w.date), y: .value("kg", w.kg))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .foregroundStyle(Color.teal)
                        .frame(height: 180)
                    }
                }
                Section("Pesées") {
                    ForEach(sorted) { w in
                        HStack {
                            Text("\(w.kg, specifier: "%.1f") kg").fontWeight(.semibold)
                            Spacer()
                            Text(w.date, style: .date).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { sorted[$0].id }
                        st.s.weights.removeAll { ids.contains($0.id) }
                    }
                }
            }
            .navigationTitle("Poids")
        }
    }
}

struct WaterView: View {
    @EnvironmentObject var st: Store

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Text("\(st.s.water) / \(st.waterGoal) verres").font(.title.bold())
                        ProgressView(value: min(1, Double(st.s.water) / Double(st.waterGoal))).tint(.teal)
                        HStack(spacing: 30) {
                            Button { if st.s.water > 0 { st.s.water -= 1 } } label: { Image(systemName: "minus.circle").font(.largeTitle) }
                            Button { st.s.water += 1 } label: { Image(systemName: "plus.circle.fill").font(.largeTitle) }
                        }.buttonStyle(.plain).foregroundStyle(Color.teal)
                    }.frame(maxWidth: .infinity)
                }
                Section {
                    Picker("Rappel", selection: $st.s.remind) {
                        Text("Désactivé").tag(0)
                        Text("Toutes les 30 min").tag(30)
                        Text("Toutes les heures").tag(60)
                        Text("Toutes les 2 h").tag(120)
                    }
                } footer: { Text("Le rappel est une vraie notification, même appli fermée. Il se répète toute la journée.") }
            }
            .navigationTitle("Hydratation")
            .onAppear { st.rolloverWater() }
            .onChange(of: st.s.remind) { _ in st.scheduleWater() }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var st: Store

    var body: some View {
        NavigationStack {
            let fasts = st.s.fasts.sorted { $0.end > $1.end }
            let ok = fasts.filter { $0.hours >= $0.goal }.count
            let avg = fasts.isEmpty ? "–" : hm(fasts.map { $0.hours * 3600 }.reduce(0, +) / Double(fasts.count))
            List {
                Section {
                    HStack {
                        stat("\(fasts.count)", "terminés"); stat(avg, "durée moyenne"); stat("\(ok)", "objectifs atteints")
                    }
                }
                Section("10 derniers jeûnes (heures)") {
                    if fasts.isEmpty { Text("Terminez un jeûne pour voir le graphique.").foregroundStyle(.secondary) }
                    else {
                        Chart(Array(fasts.prefix(10).reversed())) { f in
                            BarMark(x: .value("Fin", f.end, unit: .day), y: .value("Heures", f.hours))
                                .foregroundStyle(f.hours >= f.goal ? Color.orange : Color.teal)
                        }.frame(height: 180)
                    }
                }
                Section("Historique") {
                    ForEach(fasts) { f in
                        VStack(alignment: .leading) {
                            Text(hm(f.hours * 3600)).fontWeight(.semibold).foregroundColor(f.hours >= f.goal ? .orange : .primary)
                            Text("\(f.start.formatted(date: .abbreviated, time: .shortened)) · objectif \(f.goal, specifier: "%g") h")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { fasts[$0].id }
                        st.s.fasts.removeAll { ids.contains($0.id) }
                    }
                }
            }
            .navigationTitle("Bilan")
        }
    }

    func stat(_ v: String, _ l: String) -> some View {
        VStack { Text(v).font(.title3.bold()); Text(l).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            FastView().tabItem { Label("Jeûne", systemImage: "timer") }
            WeightView().tabItem { Label("Poids", systemImage: "scalemass") }
            WaterView().tabItem { Label("Eau", systemImage: "drop") }
            StatsView().tabItem { Label("Bilan", systemImage: "chart.bar") }
        }.tint(.teal)
    }
}

@main
struct JeuneApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store) }
    }
}
