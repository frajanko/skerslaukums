import SwiftUI
import RealityKit
import ARKit

@main
struct KokuMeritajsApp: App {
    @StateObject private var store = TreeStore()
    @StateObject private var measurer = Measurer()
    @StateObject private var basal = BasalModel()
    @StateObject private var location = LocationProvider()
    @StateObject private var samples = SamplePlotModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            Group {
                if Measurer.lidarAvailable {
                    RootView()
                } else {
                    Text("Šim telefonam nav LiDAR skenera.\nVajadzīgs iPhone Pro modelis.")
                        .multilineTextAlignment(.center).padding()
                }
            }
            .environmentObject(store)
            .environmentObject(measurer)
            .environmentObject(basal)
            .environmentObject(location)
            .environmentObject(samples)
            .preferredColorScheme(.dark)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                location.start()
            }
        }
    }
}

// MARK: - AR skats (viens visai lietotnei — sesija nepārstartējas, pārslēdzot režīmus)

struct ARContainer: UIViewRepresentable {
    let measurer: Measurer

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.renderCallbacks.postProcess = Prism.postProcess
        measurer.attach(v)
        return v
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Tēmēklis tieši ekrāna (= kameras attēla) centrā.
struct Crosshair: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = 30, gap: CGFloat = 6
            var p = Path()
            p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
            p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
            p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
            p.addEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            ctx.stroke(p, with: .color(.black.opacity(0.6)), lineWidth: 3)
            ctx.stroke(p, with: .color(.white), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Galvenais ekrāns

struct RootView: View {
    @EnvironmentObject var m: Measurer
    @EnvironmentObject var basal: BasalModel
    @EnvironmentObject var store: TreeStore
    @AppStorage("tab") private var tab = "basal"
    @State private var showData = false
    @State private var showHelp = false
    @State private var windowFrame: CGRect = .zero
    @State private var panelFrame: CGRect = .zero

    private var isBasal: Bool { tab == "basal" }

    /// Kur ekrānā (no augšas) ir tēmēšanas punkts = kameras attēla centrs (tur mēra LiDAR).
    /// Šķērslaukumā — starp augšējām pogām un prizmas logu; kokiem un parauglaukumā — starp augšējo
    /// joslu un pogu paneli, lai panelis neaizsedz tēmēkli.
    private func aimY(_ H: CGFloat) -> CGFloat {
        if isBasal {
            guard windowFrame.height > 0 else { return H * 0.34 }
            return max(H * 0.22, (150 + windowFrame.minY) / 2)
        }
        guard panelFrame.height > 0 else { return H * 0.3 }
        return max(H * 0.2, min(H / 2, (110 + panelFrame.minY) / 2))
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let W = geo.size.width, H = geo.size.height
                let y = aimY(H)
                // AR skats ir garāks par ekrānu un pabīdīts uz augšu, lai tā centrs būtu pie `y`.
                let arH = 2 * max(y, H - y)
                let arFrame = CGRect(x: 0, y: y - arH / 2, width: W, height: arH)
                let _ = Gauge.shared.setARFrame(arFrame)
                ARContainer(measurer: m)
                    .frame(width: W, height: arH)
                    .position(x: W / 2, y: y)
                if isBasal {
                    Reticle().position(x: W / 2, y: y)
                } else {
                    Crosshair().frame(width: 90, height: 90).position(x: W / 2, y: y)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                topBar
                if isBasal { BasalTopRow(pose: m.pose) }
                if tab == "plot" {
                    HStack { Spacer(); PlotMiniMap(pose: m.pose) }
                }
                if let w = m.live.warning {
                    pill(w, .orange)
                }
                Spacer()
                if let f = basal.flash, isBasal {
                    Text(f.text).font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(f.color).shadow(color: .black, radius: 4)
                        .transition(.opacity)
                }
                if isBasal {
                    PrismWindow(pose: m.pose)
                    BasalPanel()
                } else if tab == "plot" {
                    PlotPanel().reportFrame(PanelFrameKey.self)
                } else {
                    TreePanel().reportFrame(PanelFrameKey.self)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onPreferenceChange(WindowFrameKey.self) { r in
            windowFrame = r
            Gauge.shared.setWindow(r)
        }
        .onPreferenceChange(PanelFrameKey.self) { r in
            // Mazas izmaiņas ignorē, lai AR skats nedrebētu.
            if abs(r.minY - panelFrame.minY) > 4 || panelFrame.height == 0 { panelFrame = r }
        }
        .onAppear(perform: syncActive)
        .onChange(of: tab) { syncActive() }
        .onReceive(m.pose.$heading) { h in
            if let h, let p = m.pose.pitch { basal.markCoverage(heading: h, pitch: p) }
        }
        .sheet(isPresented: $showData) { DataView(tab: isBasal ? "plots" : (tab == "plot" ? "samples" : "trees")) }
        .sheet(isPresented: $showHelp) { HelpView() }
    }

    private func syncActive() {
        m.active = !isBasal
        basal.active = isBasal
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle").font(.title2) }
            Picker("Režīms", selection: $tab) {
                Text("Šķērslaukums").tag("basal")
                Text("Koki").tag("trees")
                Text("Paraugl.").tag("plot")
            }
            .pickerStyle(.segmented)
            .disabled(m.busy)
            Button { showData = true } label: {
                Image(systemName: "list.bullet")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }
}

/// Koku / parauglaukuma pogu paneļa rāmis ekrānā (globālās koordinātās).
struct PanelFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

extension View {
    func reportFrame<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGRect {
        background(GeometryReader { g in Color.clear.preference(key: key, value: g.frame(in: .global)) })
    }
}

func pill(_ s: String, _ c: Color) -> some View {
    Text(s).font(.subheadline.bold()).padding(.horizontal, 12).padding(.vertical, 6)
        .background(c.opacity(0.85), in: Capsule()).foregroundStyle(.black)
}

/// Sugu izvēle; `counts` — šķērslaukuma skaitījums pa sugām (ja ir).
struct SpeciesChips: View {
    @Binding var species: String
    var counts: [String: Double] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Species.all) { s in
                    let sel = s.id == species
                    Button { species = s.id } label: {
                        HStack(spacing: 4) {
                            Text(s.name)
                            if let n = counts[s.id], n > 0 {
                                Text(fmtN(n)).font(.caption.bold())
                                    .padding(.horizontal, 5)
                                    .background(sel ? Color.black.opacity(0.2) : Color.green.opacity(0.8), in: Capsule())
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(sel ? Color.green : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(sel ? Color.black : Color.white)
                }
            }
        }
    }
}

// MARK: - Koku panelis (caurmērs, augstums)

struct TreePanel: View {
    @EnvironmentObject var m: Measurer
    @EnvironmentObject var store: TreeStore
    @AppStorage("species") private var species = "P"
    @AppStorage("stand") private var stand = ""
    @AppStorage("dOnly") private var dOnly = false

    private var standCount: Int { store.trees.filter { $0.stand == stand }.count }

    var body: some View {
        VStack(spacing: 10) {
            // Fiksētas rindas — panelis nemaina augstumu, pogas nekustas.
            VStack(spacing: 2) {
                FixedLines(1, .system(size: 28, weight: .bold, design: .rounded)) {
                    if m.busy {
                        ProgressView(value: m.progress).tint(.green).padding(.horizontal, 20)
                    } else {
                        Text(m.live.main.isEmpty ? " " : m.live.main)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(m.live.good ? Color.green : Color.white)
                    }
                }
                FixedLines(2, .footnote) {
                    Text(m.busy ? "Mēra… turi tēmēkli uz stumbra" : m.live.detail)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                FixedLines(2, .footnote.bold()) {
                    Text(m.message ?? " ").font(.footnote.bold()).foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Text("Nogabals \(stand.isEmpty ? "—" : stand)").font(.caption).foregroundStyle(.secondary)
                valueBox(m.tree.dSamples.count > 1 ? "D, cm (vid. \(m.tree.dSamples.count))" : "D, cm",
                         m.tree.dCm.map { fmt($0, 1) } ?? "—")
                if dOnly {
                    valueBox("Koki", "\(standCount)")
                } else {
                    valueBox("H, m", m.tree.hM.map { fmt($0, 1) } ?? "—")
                }
            }
            Text(m.tree.dInfo ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)

            SpeciesChips(species: $species)

            HStack(spacing: 8) {
                if dOnly {
                    Text("Tikai caurmēri, bez augstuma")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    Picker("Mērījums", selection: $m.mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Button { dOnly.toggle() } label: {
                    Text("Tikai D").font(.subheadline.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(dOnly ? Color.green : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(dOnly ? Color.black : Color.white)
                }
            }
            .disabled(m.busy)

            if dOnly { dOnlyButtons } else { dhButtons }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
        .onAppear { m.diameterOnly = dOnly }
        .onChange(of: dOnly) {
            m.diameterOnly = dOnly
            m.resetTree()
        }
    }

    /// Caurmērs + augstums: notīrīt · mērīt · saglabāt.
    private var dhButtons: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { m.resetTree() } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 50)
            }
            .buttonStyle(.bordered)

            Button { m.act() } label: {
                Text(m.mode.action).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            .disabled(m.busy)

            Button { save() } label: {
                Image(systemName: "square.and.arrow.down").frame(width: 44, height: 50)
            }
            .buttonStyle(.bordered)
            .disabled(m.tree.dCm == nil && m.tree.hM == nil)
        }
    }

    /// Tikai caurmēri: „Mērīt caurmēru” vienmēr sāk jaunu koku (iepriekšējais nesaglabātais tiek izmests);
    /// „Mērīt vēlreiz” pievieno mērījumu tam pašam kokam un rēķina vidējo; saglabā tikai ar „Saglabāt”.
    private var dOnlyButtons: some View {
        let n = m.tree.dSamples.count
        return VStack(spacing: 8) {
            // Rinda redzama vienmēr (bez mērījuma — neaktīva), lai pogas nelēkā.
            Group {
                HStack(spacing: 10) {
                    Button { m.measureAgain() } label: {
                        VStack(spacing: 0) {
                            Text("Mērīt vēlreiz").font(.headline)
                            Text("šo pašu koku → vidējais").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)

                    Button { save() } label: {
                        VStack(spacing: 0) {
                            Text("Saglabāt").font(.headline)
                            Text(m.tree.dCm.map { "D \(fmt($0, 1)) cm" + (n > 1 ? " (vid. \(n))" : "") } ?? "vispirms izmēri").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                }
                .disabled(m.busy || m.tree.dCm == nil)
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { m.resetTree() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 50)
                }
                .buttonStyle(.bordered)
                .disabled(m.tree.dCm == nil || m.busy)

                Button { m.act() } label: {
                    VStack(spacing: 0) {
                        Text("Mērīt caurmēru").font(.headline)
                        if m.tree.dCm != nil {
                            Text("jauns koks — šis netiks saglabāts").font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(m.busy)
            }
        }
    }

    private func save() {
        var t = m.tree
        if dOnly { t.hM = nil; t.hDist = nil }
        let r = store.add(t, species: species, stand: stand)
        Haptics.ok()
        var msg = "Saglabāts #\(r.no) \(Species.name(r.species))"
        if let d = r.dCm { msg += " · D \(fmt(d, 1)) cm" }
        if t.dSamples.count > 1 { msg += " (vid. no \(t.dSamples.count))" }
        m.resetTree(message: msg)
    }
}

// MARK: - Dati: laukumi un koki

struct DataView: View {
    @EnvironmentObject var store: TreeStore
    @EnvironmentObject var basal: BasalModel
    @EnvironmentObject var m: Measurer
    @EnvironmentObject var samples: SamplePlotModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stand") private var stand = ""
    @State var tab: String
    @State private var confirmClear = false
    @State private var share: ShareItem? = nil

    private struct SpeciesSummary: Identifiable {
        let id: String
        let count: Int
        let meanD: Double?
        let meanH: Double?
    }

    private var treeSummary: [SpeciesSummary] {
        Dictionary(grouping: store.trees, by: \.species)
            .map { (k, v) in
                let ds = v.compactMap(\.dCm), hs = v.compactMap(\.hM)
                return SpeciesSummary(id: k, count: v.count,
                                      meanD: ds.isEmpty ? nil : ds.reduce(0, +) / Double(ds.count),
                                      meanH: hs.isEmpty ? nil : hs.reduce(0, +) / Double(hs.count))
            }
            .sorted { $0.count > $1.count }
    }

    private var isPlots: Bool { tab == "plots" }
    private var isSamples: Bool { tab == "samples" }
    private var isEmpty: Bool {
        isPlots ? basal.plots.isEmpty : (isSamples ? samples.plots.isEmpty : store.trees.isEmpty)
    }
    private var countText: String {
        isPlots ? "\(basal.plots.count) laukumus" : (isSamples ? "\(samples.plots.count) parauglaukumus" : "\(store.trees.count) kokus")
    }

    private func exportURLs() -> [URL] {
        if isPlots { return [writeTemp("skerslaukums", basal.csv())].compactMap { $0 } }
        if isSamples {
            return [writeTemp("parauglaukumi", samples.csvSummary()),
                    writeTemp("parauglaukumi_koki", samples.csvTrees())].compactMap { $0 }
        }
        return [writeTemp("koki", store.csv())].compactMap { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nogabals") {
                    TextField("piem. 12-5", text: $stand)
                }
                if isPlots { plotSections } else if isSamples { sampleSections } else { treeSections }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Gatavs") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("Dati", selection: $tab) {
                        Text("Šķērsl.").tag("plots")
                        Text("Paraugl.").tag("samples")
                        Text("Koki").tag("trees")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            let urls = exportURLs()
                            share = urls.isEmpty ? nil : ShareItem(urls: urls)
                        } label: { Label("Eksportēt CSV", systemImage: "square.and.arrow.up") }
                            .disabled(isEmpty)
                        Button(role: .destructive) { confirmClear = true } label: { Label("Dzēst visus", systemImage: "trash") }
                            .disabled(isEmpty)
                        Divider()
                        Button { m.restart(); dismiss() } label: { Label("Atiestatīt AR izsekošanu", systemImage: "arrow.triangle.2.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Dzēst visus \(countText)?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Dzēst visus", role: .destructive) {
                    if isPlots { basal.deleteAll() } else if isSamples { samples.deleteAll() } else { store.deleteAll() }
                }
            }
            .sheet(item: $share) { s in ShareSheet(items: s.urls) }
        }
    }

    @ViewBuilder private var plotSections: some View {
        if basal.plots.isEmpty {
            Section { Text("Vēl nav saglabātu laukumu. Saskaiti kokus un spied „Saglabāt laukumu”.").foregroundStyle(.secondary) }
        }
        ForEach(basal.standGroups) { g in
            Section {
                let st = Calc.stats(g.plots.map(\.G))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Ḡ \(fmt(st.mean, 1)) m²/ha").font(.headline)
                        Spacer()
                        Text(Calc.composition(g.meanBA)).font(.headline)
                    }
                    Text("Laukumi: \(st.n)" + (st.n > 1 ? " · ±\(fmt(st.ci, 1)) m²/ha (95 %, \(fmt(st.ciRel, 0)) %)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(g.plots) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Nr. \(p.no) · BAF \(p.baf)").font(.subheadline.bold())
                            Text(p.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("G \(fmt(p.G, 1))").bold().monospacedDigit()
                            Text("\(fmtN(p.n)) koki · \(Calc.composition(p.ba))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Dzēst", role: .destructive) { basal.delete(p.id) }
                    }
                }
            } header: {
                Text("Nogabals \(g.id.isEmpty ? "—" : g.id)")
            }
        }
    }

    @ViewBuilder private var sampleSections: some View {
        if samples.plots.isEmpty {
            Section { Text("Vēl nav saglabātu parauglaukumu. Cilnē „Paraugl.” atzīmē centru, izmēri kokus un saglabā laukumu.").foregroundStyle(.secondary) }
        }
        ForEach(samples.standGroups) { g in
            Section {
                SummaryRows(s: g.summary, ci: Calc.stats(g.plots.map { $0.summary.gHa }))
                ForEach(g.plots) { p in
                    let s = p.summary
                    NavigationLink {
                        SamplePlotDetail(plot: p)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Nr. \(p.no) · \(s.n) koki").font(.subheadline.bold())
                                Text(p.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("G \(fmt(s.gHa, 1))" + (s.m.map { " · M \(fmt($0, 0))" } ?? "")).bold().monospacedDigit()
                                Text("Dg \(s.dg.map { fmt($0, 1) } ?? "—") · \(s.composition)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Dzēst", role: .destructive) { samples.delete(p.id) }
                    }
                }
            } header: {
                Text("Nogabals \(g.id.isEmpty ? "—" : g.id) · R \(fmt(SampleArea.radius, 2)) m")
            }
        }
    }

    @ViewBuilder private var treeSections: some View {
        if !store.trees.isEmpty {
            Section("Kopsavilkums") {
                ForEach(treeSummary) { s in
                    HStack {
                        Text(Species.name(s.id)).frame(width: 110, alignment: .leading)
                        Text("\(s.count) gab.").frame(width: 60, alignment: .leading)
                        Spacer()
                        Text("D̄ \(s.meanD.map { fmt($0, 1) } ?? "—")  H̄ \(s.meanH.map { fmt($0, 1) } ?? "—")")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
        Section("Koki (\(store.trees.count))") {
            ForEach(store.trees.reversed()) { t in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(t.stand.isEmpty ? "" : t.stand + " · ")#\(t.no) \(Species.name(t.species))").font(.headline)
                        Text(t.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("D \(t.dCm.map { fmt($0, 1) } ?? "—") cm").monospacedDigit()
                        Text("H \(t.hM.map { fmt($0, 1) } ?? "—") m").monospacedDigit()
                    }
                }
                .swipeActions {
                    Button("Dzēst", role: .destructive) { store.delete([t.id]) }
                }
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Palīdzība

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        Text("Šķērslaukums").font(.title3.bold())
                        Text("Bitterliha metode. Nostājies laukuma centrā un griezies ap telefonu, nevis ap sevi. Novieto apaļo tēmēkli uz stumbra 1,3 m augstumā.")
                        Text("**Prizmas logs** (virs pogām) rāda tēmēkļa apkārtni palielinātu: augšējā pusē reālais stumbrs, apakšējā — nobīdīts par kritisko leņķi. Nobīdītais gabals vēl pārklājas ar stumbru augšā → **+1**, malas tieši sakrīt → **+½**, starp tiem sprauga → neskaita. 🔍 maina palielinājumu.")
                        Text("**Līnijas:** logā divas līnijas; stumbrs platāks par atstarpi → +1, vienāds → +½, šaurāks → neskaita.")
                        Text("Pirms skaitīšanas izvēlies sugu. Aplis augšā pa labi rāda, cik no pilna apgrieziena jau apskatīts. G = koku skaits × BAF (m²/ha).")
                        Text("Kalibrēt nevajag — ARKit zina kameras precīzos parametrus. Slīpuma korekcija ņem telefona slīpumu no AR izsekošanas.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Group {
                        Text("Koki").font(.title3.bold())
                        Text("**Caurmērs.** Stāvi 1–3 m no koka, novieto tēmēkli stumbra vidū **1,3 m augstumā** (pēc acs). Baltās līnijas rāda, kur lietotne redz stumbra malas — tām jāsakrīt ar stumbru. Spied „Mērīt caurmēru” un sekundi turi telefonu mierīgi. Izmērītās malas paliek kā zaļas līnijas.")
                        Text("Metode „aplis” — LiDAR punktiem pielāgots riņķis; „malas” — pēc stumbra leņķiskā platuma. Lielākai precizitātei mērot nedaudz pakustini telefonu pa kreisi–pa labi.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("**Augstums.** Atkāpies tik tālu, lai redzi galotni (attālums ≈ koka augstums ir labākais). Telefons pats seko, cik tālu esi aizgājis. Notēmē galotni un spied „Atzīmēt galotni”. Augstumu skaita no zemes, ko pieņem 1,3 m zem caurmēra mērīšanas vietas.")
                        Text("**Tikai caurmēri.** Ieslēdz „Tikai D” — augstumu nemēra. Pēc mērījuma: „Saglabāt” — koks saglabājas ar izvēlēto sugu; „Mērīt vēlreiz” — vēl viens mērījums tam pašam kokam, rāda vidējo (ja stumbrs ir cits, vidējo nerēķina); „Mērīt caurmēru” — jauns koks, iepriekšējais netiek saglabāts. Tā var arī tikai apskatīt caurmēru un iet tālāk.")
                        Text("Izvēlies sugu un spied ⤓, lai saglabātu koku. Sarakstā (augšā pa labi) — laukumi, koki, kopsavilkums un CSV eksports.")
                    }
                    Group {
                        Text("Parauglaukums").font(.title3.bold())
                        Text("Apļveida laukums ar rādiusu **12,62 m** (500 m²). Iesprauž mietiņu laukuma centrā, tēmē uz tā pamatni un spied „Atzīmēt centru”. AR skatā parādās oranža robeža — gredzens pie zemes un 1,3 m augstumā, ar mietiņiem ik 15°.")
                        Text("Ej no koka pie koka un mēri caurmērus (izvēlies sugu pirms mērīšanas). Kamēr tēmē, redzams stumbra attālums no centra. Izmērītos stumbrus apņem gredzens: **zaļš** — ieskaitīts, **dzeltens** — robežkoks (±30 cm), **pelēks** — ārpus laukuma. Ja to pašu koku izmēri vēlreiz, mērījums tiek aizstāts.")
                        Text("Attālumu mēra horizontāli līdz stumbra asij, tāpēc slīpumā korekcija nav vajadzīga. AR izsekošana ejot nedaudz „aizpeld”: atgriezies pie mietiņa un ⋯ → „Pārbaudīt centra nobīdi”. Ja nobīde liela, robežkokus pārbaudi ar mērlenti un sarakstā pieskaries kokam, lai to ieskaitītu vai izslēgtu.")
                        Text("**Mini-karte** (augšā pa labi) rāda laukumu no augšas: oranža robeža, centrs (+), koki (zaļš / dzeltens / pelēks, sarkans aplis — modeļkoks) un tu (zils punkts). Karte pagriežas līdzi telefonam — tas, uz ko skaties, vienmēr ir uz augšu. Pieskaries kartei, lai to palielinātu (ar koku numuriem).")
                        Text("**Modeļkoki.** Pēc caurmēra spied „Augstums #N (modeļkoks)” (vai sarakstā velc koku pa labi → „Augstums”), atkāpies, tēmē galotni un spied „Atzīmēt galotni”. Sugas augstumu aprēķina koka ar Dg caurmēru: ja sugai ir ≥ 3 modeļkoki ar dažādiem caurmēriem — no augstuma līknes (Näslunds), citādi — modeļkoku vidējais. Audzes H — sugu augstumi, svērti pēc G. Ieteicami 3–5 modeļkoki katrai galvenajai sugai, tievi un resni.")
                        Text("**Krāja** M = G · HF, kur veidaugstumu HF ņem no tabulas „Veidaugstumi (H·f)” pēc sugas un H (9–40 m, starp veseliem metriem interpolē). Liepa, kļava u.c. — kā baltalksnis. Ja sugai nav modeļkoku, lieto audzes H (rāda „≈”); ārpus 9–40 m HF ekstrapolē.")
                        Text("**Ja AR izsekošana pazūd** (atiestatīšana, lietotne aizvērta): atzīmē centru no jauna uz tā paša mietiņa un pārmēri vienu jau izmērītu koku — vēlams tālāk no centra. Lietotne piedāvās, kurš koks tas varētu būt; pēc izvēles visu iepriekš izmērīto koku pozīcijas tiek pagrieztas atpakaļ vietā. „Attāluma starpība” rāda, cik labi sakrīt (līdz ~30 cm ir labi).")
                        Text("Sarakstā (☰ ar numuriem) — laukuma rādītāji: N/ha, G m²/ha, D̄, Dg, sastāvs. „Saglabāt laukumu” — un nākamais laukums. Datu sarakstā — nogabala vidējie rādītāji no visiem laukumiem un CSV eksports.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Group {
                        Text("Padomi").font(.headline)
                        Text("• LiDAR redz līdz ~5 m; caurmēram labākais 1–2 m.\n• Ja rādās „Inicializē”, lēnām pakustini telefonu.\n• Ja marķieri vairs nesakrīt ar koku, sarakstā ⋯ → „Atiestatīt AR izsekošanu”.\n• Pirmajos mērījumos salīdzini ar dastu, mērlenti un prizmu.")
                    }
                }
                .padding()
            }
            .navigationTitle("Kā mērīt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Aizvērt") { dismiss() } } }
        }
    }
}
