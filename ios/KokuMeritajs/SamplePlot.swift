import CoreLocation
import RealityKit
import SwiftUI
import simd

// MARK: - Parauglaukums ar fiksētu rādiusu (12,62 m ≈ 500 m²)

enum TreeStatus {
    case inside, border, outside
    var title: String {
        switch self {
        case .inside: return "iekšā"
        case .border: return "robežkoks"
        case .outside: return "ārā"
        }
    }
}

enum SampleArea {
    static let radius = 12.62
    /// Robežkoki: ±30 cm no robežas (AR izsekošanas nobīdes dēļ ieteicams pārbaudīt ar mērlenti).
    static let border = 0.3
    static var area: Double { .pi * radius * radius }
    static var perHa: Double { 10_000 / area }

    static func status(_ r: Double) -> TreeStatus {
        abs(r - radius) <= border ? .border : (r < radius ? .inside : .outside)
    }

    /// Stumbra šķērslaukums, m².
    static func ba(_ dCm: Double) -> Double { .pi * (dCm / 200) * (dCm / 200) }
}

struct PlotTree: Codable, Identifiable, Hashable {
    var id = UUID()
    var no: Int
    var species: String
    var dCm: Double
    var dMethod: String?
    /// Horizontāli no centra līdz stumbra asij, m.
    var dist: Double
    /// Ieskaitīts laukumā (pēc noklusējuma — ja dist ≤ R; robežkokiem var mainīt).
    var counted: Bool
    // AR pozīcija (stumbra ass 1,3 m augstumā) — derīga tikai sesijā `session`.
    var x: Float
    var y: Float
    var z: Float
    var session: String

    var status: TreeStatus { SampleArea.status(dist) }
}

struct PlotCenter: Codable, Hashable {
    var x: Float
    var y: Float
    var z: Float
    var session: String
    var xz: SIMD2<Float> { SIMD2(x, z) }
    var pos: SIMD3<Float> { SIMD3(x, y, z) }
}

struct CurrentSample: Codable, Hashable {
    var no = 1
    var center: PlotCenter? = nil
    var lat: Double? = nil
    var lon: Double? = nil
    var acc: Double? = nil
    var drift: Double? = nil
    var trees: [PlotTree] = []
}

struct SamplePlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var stand: String
    var no: Int
    var date: Date
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var drift: Double?
    var trees: [PlotTree]

    var counted: [PlotTree] { trees.filter(\.counted) }
    var summary: PlotSummary { PlotSummary(counted) }
}

/// Audzes rādītāji no ieskaitītajiem kokiem.
struct PlotSummary {
    struct Sp: Identifiable {
        let id: String
        let n: Int
        let nHa: Double
        let gHa: Double
        let dg: Double
    }

    let n: Int
    let nHa: Double
    let gHa: Double
    let dMean: Double?
    let dg: Double?
    let species: [Sp]

    var composition: String {
        Calc.composition(Dictionary(uniqueKeysWithValues: species.map { ($0.id, $0.gHa) }))
    }

    /// `plots` — cik laukumos koki uzmērīti (nogabala vidējam).
    init(_ trees: [PlotTree], plots: Int = 1) {
        let k = SampleArea.perHa / Double(max(1, plots))
        n = trees.count
        nHa = Double(n) * k
        gHa = trees.reduce(0) { $0 + SampleArea.ba($1.dCm) } * k
        dMean = trees.isEmpty ? nil : trees.reduce(0) { $0 + $1.dCm } / Double(trees.count)
        dg = Self.dg(trees)
        species = Dictionary(grouping: trees, by: \.species).map { sp, t in
            Sp(id: sp, n: t.count, nHa: Double(t.count) * k,
               gHa: t.reduce(0) { $0 + SampleArea.ba($1.dCm) } * k, dg: Self.dg(t) ?? 0)
        }
        .sorted { $0.gHa > $1.gHa }
    }

    /// Vidējais kvadrātiskais caurmērs (pēc šķērslaukuma).
    static func dg(_ t: [PlotTree]) -> Double? {
        t.isEmpty ? nil : sqrt(t.reduce(0) { $0 + $1.dCm * $1.dCm } / Double(t.count))
    }
}

struct SampleStandGroup: Identifiable {
    let id: String
    var plots: [SamplePlot]
    var summary: PlotSummary { PlotSummary(plots.flatMap(\.counted), plots: plots.count) }
}

final class SamplePlotModel: ObservableObject {
    @Published private(set) var plots: [SamplePlot] = []
    @Published private(set) var cur = CurrentSample()

    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var plotsURL: URL { dir.appendingPathComponent("parauglaukumi.json") }
    private var curURL: URL { dir.appendingPathComponent("parauglaukums.json") }

    init() {
        if let d = try? Data(contentsOf: plotsURL), let p = try? JSONDecoder().decode([SamplePlot].self, from: d) { plots = p }
        if let d = try? Data(contentsOf: curURL), let c = try? JSONDecoder().decode(CurrentSample.self, from: d) { cur = c }
    }

    private func savePlots() {
        if let d = try? JSONEncoder().encode(plots) { try? d.write(to: plotsURL, options: .atomic) }
    }

    private func saveCur() {
        if let d = try? JSONEncoder().encode(cur) { try? d.write(to: curURL, options: .atomic) }
    }

    func center(session: String) -> PlotCenter? {
        cur.center?.session == session ? cur.center : nil
    }

    func setCenter(_ p: SIMD3<Float>, session: String, location: CLLocation?) {
        cur.center = PlotCenter(x: p.x, y: p.y, z: p.z, session: session)
        cur.drift = nil
        if cur.lat == nil || cur.trees.isEmpty, let l = location {
            cur.lat = l.coordinate.latitude
            cur.lon = l.coordinate.longitude
            cur.acc = l.horizontalAccuracy
        }
        saveCur()
    }

    func setDrift(_ d: Double) {
        cur.drift = d
        saveCur()
    }

    enum AddResult {
        case added(PlotTree)
        case replaced(PlotTree)
        var tree: PlotTree {
            switch self {
            case .added(let t), .replaced(let t): return t
            }
        }
    }

    /// Pievieno izmērītu koku. Ja tuvumā jau ir izmērīts koks (tas pats stumbrs) — aizstāj to.
    func addTree(dCm: Double, method: String?, pos: SIMD3<Float>, species: String, session: String) -> AddResult? {
        guard let c = center(session: session) else { return nil }
        let xz = SIMD2(pos.x, pos.z)
        let dist = Double(simd_length(xz - c.xz))
        let same = cur.trees.firstIndex { t in
            t.session == session
                && simd_length(SIMD2(t.x, t.z) - xz) < max(0.1, Float(0.5 * max(dCm, t.dCm) / 100))
        }
        if let i = same {
            var t = cur.trees[i]
            t.dCm = dCm; t.dMethod = method; t.dist = dist; t.counted = dist <= SampleArea.radius
            t.species = species; t.x = pos.x; t.y = pos.y; t.z = pos.z
            cur.trees[i] = t
            saveCur()
            return .replaced(t)
        }
        let t = PlotTree(no: (cur.trees.map(\.no).max() ?? 0) + 1, species: species, dCm: dCm, dMethod: method,
                         dist: dist, counted: dist <= SampleArea.radius,
                         x: pos.x, y: pos.y, z: pos.z, session: session)
        cur.trees.append(t)
        saveCur()
        return .added(t)
    }

    func toggle(_ id: UUID) {
        guard let i = cur.trees.firstIndex(where: { $0.id == id }) else { return }
        cur.trees[i].counted.toggle()
        saveCur()
    }

    func deleteTree(_ id: UUID) {
        cur.trees.removeAll { $0.id == id }
        saveCur()
    }

    @discardableResult
    func undoLast() -> PlotTree? {
        guard let t = cur.trees.popLast() else { return nil }
        saveCur()
        return t
    }

    func setNo(_ no: Int) {
        guard no > 0 else { return }
        cur.no = no
        saveCur()
    }

    func discardCurrent() {
        cur = CurrentSample(no: cur.no)
        saveCur()
    }

    @discardableResult
    func finish(stand: String) -> SamplePlot? {
        guard !cur.trees.isEmpty else { return nil }
        let p = SamplePlot(stand: stand, no: cur.no, date: Date(), lat: cur.lat, lon: cur.lon, acc: cur.acc,
                           drift: cur.drift, trees: cur.trees)
        plots.append(p)
        savePlots()
        cur = CurrentSample(no: cur.no + 1)
        saveCur()
        return p
    }

    func delete(_ id: UUID) {
        plots.removeAll { $0.id == id }
        savePlots()
    }

    func deleteAll() {
        plots = []
        savePlots()
    }

    var standGroups: [SampleStandGroup] {
        var order: [String] = []
        var m: [String: [SamplePlot]] = [:]
        for p in plots {
            if m[p.stand] == nil { order.append(p.stand) }
            m[p.stand, default: []].append(p)
        }
        return order.map { SampleStandGroup(id: $0, plots: m[$0]!) }
    }

    // MARK: CSV

    private static func formatters() -> (DateFormatter, DateFormatter) {
        let df = DateFormatter(); df.locale = Locale(identifier: "lv_LV"); df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "lv_LV"); tf.dateFormat = "HH:mm:ss"
        return (df, tf)
    }

    private static func num(_ x: Double?, _ d: Int) -> String { x.map { fmt($0, d) } ?? "" }

    /// Visi uzmērītie koki (arī neieskaitītie).
    func csvTrees() -> String {
        let (df, tf) = Self.formatters()
        let head = ["nogabals", "laukums", "datums", "laiks", "platums", "garums", "koks_nr", "suga", "D_cm",
                    "attalums_no_centra_m", "ieskaitits", "robezkoks", "D_metode"]
        var rows: [String] = []
        for p in plots {
            for t in p.trees {
                rows.append([p.stand, String(p.no), df.string(from: p.date), tf.string(from: p.date),
                             Self.num(p.lat, 6), Self.num(p.lon, 6), String(t.no), t.species, Self.num(t.dCm, 1),
                             Self.num(t.dist, 2), t.counted ? "jā" : "nē", t.status == .border ? "jā" : "nē",
                             t.dMethod ?? ""]
                    .map(csvCell).joined(separator: ";"))
            }
        }
        return "\u{FEFF}" + ([head.joined(separator: ";")] + rows).joined(separator: "\r\n")
    }

    /// Viena rinda katram laukumam.
    func csvSummary() -> String {
        let (df, tf) = Self.formatters()
        let sp = Species.all.map(\.id)
        let head = ["nogabals", "laukums", "datums", "laiks", "platums", "garums", "gps_precizitate_m",
                    "radiuss_m", "centra_nobide_m", "koki", "N_ha", "G_m2_ha", "D_vid_cm", "Dg_cm", "sastavs"]
            + sp.map { "G_\($0)" }
        let rows = plots.map { p -> String in
            let s = p.summary
            let g = Dictionary(uniqueKeysWithValues: s.species.map { ($0.id, $0.gHa) })
            let r = [p.stand, String(p.no), df.string(from: p.date), tf.string(from: p.date),
                     Self.num(p.lat, 6), Self.num(p.lon, 6), Self.num(p.acc, 0), Self.num(SampleArea.radius, 2),
                     Self.num(p.drift, 2), String(s.n), Self.num(s.nHa, 0), Self.num(s.gHa, 1),
                     Self.num(s.dMean, 1), Self.num(s.dg, 1), s.composition]
                + sp.map { Self.num(g[$0] ?? 0, 1) }
            return r.map(csvCell).joined(separator: ";")
        }
        return "\u{FEFF}" + ([head.joined(separator: ";")] + rows).joined(separator: "\r\n")
    }
}

// MARK: - AR: laukuma robeža un izmērītie koki

extension Measurer {
    private static var ringMesh: MeshResource?

    /// Vertikāla josla (gredzens) ap Y asi — redzama no abām pusēm.
    static func band(radius r: Float, height h: Float, segments n: Int) -> MeshResource? {
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for i in 0...n {
            let a = Float(i) / Float(n) * 2 * .pi
            let x = r * cos(a), z = r * sin(a)
            pos.append(SIMD3(x, -h / 2, z))
            pos.append(SIMD3(x, h / 2, z))
        }
        for i in 0..<n {
            let b = UInt32(2 * i)
            idx += [b, b + 1, b + 2, b + 1, b + 3, b + 2]
            idx += [b, b + 2, b + 1, b + 1, b + 2, b + 3]
        }
        var d = MeshDescriptor(name: "band")
        d.positions = MeshBuffers.Positions(pos)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }

    /// Uzzīmē laukuma robežu (gredzeni pie zemes un 1,3 m augstumā, mietiņi ik 15°) un
    /// gredzenus ap izmērītajiem stumbriem. `center == nil` — notīra.
    func drawPlot(center: SIMD3<Float>?, trees: [PlotTree]) {
        guard let view = arView else { return }
        if let a = plotAnchor { view.scene.removeAnchor(a) }
        plotAnchor = nil
        guard let c = center else { return }

        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        let R = Float(SampleArea.radius)
        let orange = Self.mat(.systemOrange, 0.85)

        if Self.ringMesh == nil { Self.ringMesh = Self.band(radius: R, height: 0.05, segments: 240) }
        if let ring = Self.ringMesh {
            for dy: Float in [0.03, Self.breastHeight] {
                let e = ModelEntity(mesh: ring, materials: [orange])
                e.position = c + SIMD3(0, dy, 0)
                anchor.addChild(e)
            }
        }
        let post = MeshResource.generateCylinder(height: 2, radius: 0.012)
        for i in 0..<24 {
            let a = Float(i) * .pi / 12
            let e = ModelEntity(mesh: post, materials: [Self.mat(.systemOrange, 0.6)])
            e.position = c + SIMD3(R * cos(a), 1, R * sin(a))
            anchor.addChild(e)
        }
        let pole = ModelEntity(mesh: .generateCylinder(height: 1.8, radius: 0.025), materials: [orange])
        pole.position = c + SIMD3(0, 0.9, 0)
        anchor.addChild(pole)

        for t in trees where t.session == sessionID {
            let color: UIColor = !t.counted ? .systemGray : (t.status == .border ? .systemYellow : .systemGreen)
            guard let m = Self.band(radius: Float(t.dCm / 200) + 0.02, height: 0.06, segments: 48) else { continue }
            let e = ModelEntity(mesh: m, materials: [Self.mat(color, 0.9)])
            e.position = SIMD3(t.x, t.y, t.z)
            anchor.addChild(e)
        }
        view.scene.addAnchor(anchor)
        plotAnchor = anchor
    }
}

// MARK: - Panelis

struct PlotPanel: View {
    @EnvironmentObject var m: Measurer
    @EnvironmentObject var sp: SamplePlotModel
    @EnvironmentObject var location: LocationProvider
    @AppStorage("species") private var species = "P"
    @AppStorage("stand") private var stand = ""

    private enum Pending { case none, markCenter, checkCenter }
    @State private var pending: Pending = .none
    @State private var showTrees = false
    @State private var confirmDiscard = false

    private var center: PlotCenter? { sp.center(session: m.sessionID) }
    private var lost: Bool { sp.cur.center != nil && center == nil }
    private var aimingCenter: Bool { center == nil || pending != .none }
    private var counted: [PlotTree] { sp.cur.trees.filter(\.counted) }

    var body: some View {
        let sum = PlotSummary(counted)
        VStack(spacing: 10) {
            status

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nog. \(stand.isEmpty ? "—" : stand)")
                    Text("Nr. \(sp.cur.no)")
                }
                .font(.caption).foregroundStyle(.secondary)
                valueBox("Koki", "\(counted.count)")
                valueBox("G, m²/ha", sum.n > 0 ? fmt(sum.gHa, 1) : "—")
                valueBox("Dg, cm", sum.dg.map { fmt($0, 1) } ?? "—")
            }

            SpeciesChips(species: $species,
                         counts: Dictionary(grouping: counted, by: \.species).mapValues { Double($0.count) })

            HStack(spacing: 10) {
                Menu {
                    Button { undo() } label: { Label("Atsaukt pēdējo koku", systemImage: "arrow.uturn.backward") }
                        .disabled(sp.cur.trees.isEmpty)
                    Button { pending = .checkCenter } label: { Label("Pārbaudīt centra nobīdi", systemImage: "scope") }
                        .disabled(center == nil)
                    Button { pending = .markCenter } label: { Label("Atzīmēt centru no jauna", systemImage: "mappin.and.ellipse") }
                    Divider()
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Label("Sākt laukumu no jauna", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 50)
                }
                .buttonStyle(.bordered)

                Button { act() } label: {
                    Text(actionTitle).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(aimingCenter ? .orange : .green)

                Button { showTrees = true } label: {
                    Image(systemName: "list.number").frame(width: 44, height: 50)
                }
                .buttonStyle(.bordered)
            }
            .disabled(m.busy)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
        .onAppear {
            m.diameterOnly = true
            m.resetTree()
            redraw()
        }
        .onDisappear {
            m.plotCenter = nil
            m.drawPlot(center: nil, trees: [])
        }
        .onChange(of: sp.cur) { redraw() }
        .onChange(of: m.sessionID) { redraw() }
        .onChange(of: m.diameterCount) { treeMeasured() }
        .sheet(isPresented: $showTrees) { PlotTreesView() }
        .confirmationDialog("Dzēst laukuma Nr. \(sp.cur.no) centru un \(sp.cur.trees.count) kokus?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Dzēst un sākt no jauna", role: .destructive) {
                sp.discardCurrent()
                m.resetTree()
                pending = .none
            }
        }
    }

    @ViewBuilder private var status: some View {
        VStack(spacing: 2) {
            if m.busy {
                ProgressView(value: m.progress).tint(.green)
                Text("Mēra… turi tēmēkli uz stumbra").font(.headline)
            } else if aimingCenter {
                Text(pending == .checkCenter ? "Pārbaudi centru" : "Atzīmē laukuma centru")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Tēmē uz centra mietiņa pamatni (1–3 m) un spied pogu")
                    .font(.footnote).foregroundStyle(.secondary)
                if lost && pending == .none {
                    Text("AR izsekošana atiestatīta — centrs jāatzīmē no jauna. Izmērītie koki saglabājas.")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if pending != .none {
                    Button("Atcelt") { pending = .none }.font(.footnote)
                }
            } else {
                Text(m.live.main.isEmpty ? " " : m.live.main)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(m.live.good ? Color.green : Color.white)
                Text(m.live.detail).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let msg = m.message {
                Text(msg).font(.footnote.bold()).foregroundStyle(.yellow).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionTitle: String {
        switch pending {
        case .checkCenter: return "Pārbaudīt centru"
        case .markCenter: return "Atzīmēt centru"
        case .none: return center == nil ? "Atzīmēt centru" : "Mērīt caurmēru"
        }
    }

    private func redraw() {
        let c = center
        m.plotCenter = c?.xz
        m.drawPlot(center: c?.pos, trees: sp.cur.trees)
    }

    private func act() {
        guard aimingCenter else { m.act(); return }
        let checking = pending == .checkCenter
        m.aimNow { p, cam in
            guard let p, let cam else {
                m.message = "LiDAR neredz zemi — tēmē uz mietiņa pamatni 1–3 m attālumā"
                Haptics.fail()
                return
            }
            guard cam.y - p.y > 0.5 else {
                m.message = "Tēmē uz zemi pie mietiņa pamatnes"
                Haptics.fail()
                return
            }
            if checking, let c = center {
                let d = Double(simd_length(SIMD2(p.x, p.z) - c.xz))
                sp.setDrift(d)
                m.message = "Centra nobīde \(fmt(d * 100, 0)) cm" + (d > SampleArea.border ? " — robežkokus pārbaudi ar mērlenti" : "")
            } else {
                sp.setCenter(p, session: m.sessionID, location: location.recent)
                m.message = "Centrs atzīmēts — mēri kokus"
            }
            pending = .none
            Haptics.ok()
        }
    }

    private func treeMeasured() {
        guard let d = m.tree.dCm, let a = m.tree.axisXZ, let y = m.tree.dY else { return }
        guard let r = sp.addTree(dCm: d, method: m.tree.dMethod, pos: SIMD3(a.x, y, a.y),
                                 species: species, session: m.sessionID) else {
            m.message = "Vispirms atzīmē laukuma centru"
            return
        }
        let t = r.tree
        var s = "#\(t.no) \(Species.name(t.species)) · D \(fmt(t.dCm, 1)) cm · \(fmt(t.dist, 1)) m — \(t.status.title)"
        if case .replaced = r { s = "Pārmērīts " + s }
        if !t.counted { s += " (neskaita)" }
        if t.status == .border { s += "\npārbaudi ar mērlenti; sarakstā var ieskaitīt/izslēgt" }
        m.message = s
    }

    private func undo() {
        if let t = sp.undoLast() {
            m.resetTree()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { m.message = "Atsaukts #\(t.no)" }
        }
    }
}

func valueBox(_ title: String, _ value: String) -> some View {
    VStack(spacing: 0) {
        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        Text(value).font(.title3.bold().monospacedDigit())
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
}

// MARK: - Rādītāji un koku saraksts

struct SummaryRows: View {
    let s: PlotSummary
    var ci: Calc.Stats? = nil

    var body: some View {
        HStack {
            Text("G \(fmt(s.gHa, 1)) m²/ha").font(.headline)
            Spacer()
            Text(s.composition).font(.headline)
        }
        if let ci, ci.n > 1 {
            Text("±\(fmt(ci.ci, 1)) m²/ha (95 %, \(fmt(ci.ciRel, 0)) %) · \(ci.n) laukumi")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Text("N \(fmt(s.nHa, 0))/ha")
            Spacer()
            Text("D̄ \(s.dMean.map { fmt($0, 1) } ?? "—") · Dg \(s.dg.map { fmt($0, 1) } ?? "—") cm")
        }
        .font(.subheadline).monospacedDigit()
        ForEach(s.species) { x in
            HStack {
                Text(Species.name(x.id)).frame(width: 100, alignment: .leading)
                Text("\(x.n) gab.").frame(width: 55, alignment: .leading)
                Spacer()
                Text("G \(fmt(x.gHa, 1)) · Dg \(fmt(x.dg, 1))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct PlotTreeRow: View {
    let t: PlotTree
    var body: some View {
        HStack {
            Circle()
                .fill(!t.counted ? Color.gray : (t.status == .border ? Color.yellow : Color.green))
                .frame(width: 10, height: 10)
            Text("#\(t.no) \(Species.name(t.species))")
            Spacer()
            VStack(alignment: .trailing) {
                Text("D \(fmt(t.dCm, 1)) cm").monospacedDigit()
                Text("\(fmt(t.dist, 2)) m · \(t.status.title)\(t.counted ? "" : ", neskaita")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pašreizējā laukuma koki, rādītāji un saglabāšana.
struct PlotTreesView: View {
    @EnvironmentObject var sp: SamplePlotModel
    @EnvironmentObject var m: Measurer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stand") private var stand = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Laukums") {
                    TextField("Nogabals, piem. 12-5", text: $stand)
                    Stepper("Laukuma Nr. \(sp.cur.no)", value: Binding(get: { sp.cur.no }, set: { sp.setNo($0) }), in: 1...999)
                    if let d = sp.cur.drift {
                        Text("Centra nobīde \(fmt(d * 100, 0)) cm").foregroundStyle(d > SampleArea.border ? .orange : .secondary)
                    }
                }
                Section("Rādītāji (R = \(fmt(SampleArea.radius, 2)) m)") {
                    SummaryRows(s: PlotSummary(sp.cur.trees.filter(\.counted)))
                }
                Section {
                    ForEach(sp.cur.trees.reversed()) { t in
                        PlotTreeRow(t: t)
                            .contentShape(Rectangle())
                            .onTapGesture { sp.toggle(t.id) }
                            .swipeActions { Button("Dzēst", role: .destructive) { sp.deleteTree(t.id) } }
                    }
                } header: {
                    Text("Koki (\(sp.cur.trees.count))")
                } footer: {
                    Text("Pieskaries kokam, lai to ieskaitītu vai izslēgtu (piem. robežkoku pēc pārbaudes ar mērlenti).")
                }
                Section {
                    Button {
                        if let p = sp.finish(stand: stand) {
                            m.resetTree()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                m.message = "Laukums Nr. \(p.no) saglabāts · G \(fmt(p.summary.gHa, 1)) m²/ha"
                            }
                            Haptics.ok()
                            dismiss()
                        }
                    } label: {
                        Label("Saglabāt laukumu Nr. \(sp.cur.no)", systemImage: "checkmark.circle.fill").font(.headline)
                    }
                    .disabled(sp.cur.trees.isEmpty)
                }
            }
            .navigationTitle("Parauglaukums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gatavs") { dismiss() } } }
        }
    }
}

/// Saglabāta laukuma koki (no datu saraksta).
struct SamplePlotDetail: View {
    let plot: SamplePlot
    var body: some View {
        List {
            Section("Rādītāji") { SummaryRows(s: plot.summary) }
            Section("Koki (\(plot.trees.count))") {
                ForEach(plot.trees) { PlotTreeRow(t: $0) }
            }
            if let d = plot.drift {
                Section { Text("Centra nobīde \(fmt(d * 100, 0)) cm") }
            }
        }
        .navigationTitle("Laukums Nr. \(plot.no)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
