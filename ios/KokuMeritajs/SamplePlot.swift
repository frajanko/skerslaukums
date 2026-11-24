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
    /// Modeļkoka augstums, m, un horizontālais attālums, no kura mērīts.
    var hM: Double? = nil
    var hDist: Double? = nil

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
    /// Iepriekšējo AR sesiju centri — pēc tiem atjauno koku pozīcijas, ja izsekošana tika atiestatīta.
    var pastCenters: [PlotCenter]? = nil
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
    var summary: PlotSummary { PlotSummary(counted, model: trees) }
}

/// Augstuma līkne pēc Näslunda: h = 1,3 + (d / (a + b·d))², d — cm, h — m.
/// Pielāgo ar lineāru regresiju: d / √(h − 1,3) = a + b·d.
struct HeightCurve {
    let a: Double
    let b: Double

    static func fit(_ pts: [(d: Double, h: Double)]) -> HeightCurve? {
        let p = pts.filter { $0.h > 1.4 && $0.d > 0 }
        guard p.count >= 3 else { return nil }
        let xs = p.map(\.d), ys = p.map { $0.d / sqrt($0.h - 1.3) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 1e-6 else { return nil }
        let b = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        return HeightCurve(a: my - b * mx, b: b)
    }

    func h(_ d: Double) -> Double? {
        let q = a + b * d
        guard q > 1e-6 else { return nil }
        return 1.3 + (d / q) * (d / q)
    }
}

/// Audzes rādītāji no ieskaitītajiem kokiem.
struct PlotSummary {
    struct Sp: Identifiable {
        let id: String
        let n: Int
        let nHa: Double
        let gHa: Double
        let dg: Double
        /// Sugas vidējais augstums (koka ar Dg augstums), m.
        let h: Double?
        let hNote: String?
        /// Krāja m³/ha = G · HF(H). Ja sugai nav modeļkoku — ar audzes H (`hFromStand`).
        var m: Double? = nil
        var hFromStand = false
        /// H ārpus veidaugstumu tabulas (9–40 m) — HF ekstrapolēts.
        var hfExtrapolated = false
    }

    let n: Int
    let nHa: Double
    let gHa: Double
    let dMean: Double?
    let dg: Double?
    let species: [Sp]
    /// Modeļkoku skaits.
    let models: Int
    /// Audzes vidējais augstums — sugu augstumi, svērti pēc G.
    let h: Double?
    /// Krāja, m³/ha (nil, ja nav neviena modeļkoka).
    var m: Double? {
        let v = species.compactMap(\.m)
        return v.isEmpty ? nil : v.reduce(0, +)
    }
    /// Krāja aprēķināta ar pieņēmumiem (audzes H kādai sugai vai H ārpus tabulas).
    var mApprox: Bool { species.contains { $0.m != nil && ($0.hFromStand || $0.hfExtrapolated) } }

    var composition: String {
        Calc.composition(Dictionary(uniqueKeysWithValues: species.map { ($0.id, $0.gHa) }))
    }

    /// `plots` — cik laukumos koki uzmērīti (nogabala vidējam);
    /// `model` — koki, starp kuriem meklē modeļkokus (arī neieskaitītie), pēc noklusējuma `trees`.
    init(_ trees: [PlotTree], plots: Int = 1, model: [PlotTree]? = nil) {
        let k = SampleArea.perHa / Double(max(1, plots))
        let modelTrees = (model ?? trees).filter { $0.hM != nil }
        n = trees.count
        nHa = Double(n) * k
        gHa = trees.reduce(0) { $0 + SampleArea.ba($1.dCm) } * k
        dMean = trees.isEmpty ? nil : trees.reduce(0) { $0 + $1.dCm } / Double(trees.count)
        dg = Self.dg(trees)
        models = modelTrees.count
        var sps = Dictionary(grouping: trees, by: \.species).map { sp, t in
            let dg = Self.dg(t) ?? 0
            let hh = Self.height(model: modelTrees.filter { $0.species == sp }, dg: dg)
            return Sp(id: sp, n: t.count, nHa: Double(t.count) * k,
                      gHa: t.reduce(0) { $0 + SampleArea.ba($1.dCm) } * k, dg: dg, h: hh?.0, hNote: hh?.1)
        }
        .sorted { $0.gHa > $1.gHa }

        let w = sps.compactMap { s in s.h.map { (s.gHa, $0) } }
        let gw = w.reduce(0) { $0 + $1.0 }
        let standH = gw > 0 ? w.reduce(0) { $0 + $1.0 * $1.1 } / gw : nil
        h = standH

        for i in sps.indices {
            guard let hUse = sps[i].h ?? standH, let hf = FormHeight.hf(species: sps[i].id, h: hUse) else { continue }
            sps[i].m = sps[i].gHa * hf
            sps[i].hFromStand = sps[i].h == nil
            sps[i].hfExtrapolated = !FormHeight.inTable(hUse)
        }
        species = sps
    }

    /// Vidējais kvadrātiskais caurmērs (pēc šķērslaukuma).
    static func dg(_ t: [PlotTree]) -> Double? {
        t.isEmpty ? nil : sqrt(t.reduce(0) { $0 + $1.dCm * $1.dCm } / Double(t.count))
    }

    /// Koka ar caurmēru `dg` augstums: no augstuma līknes (≥ 3 modeļkoki ar caurmēru starpību ≥ 4 cm),
    /// citādi — modeļkoku augstumu vidējais.
    static func height(model: [PlotTree], dg: Double) -> (Double, String)? {
        let pts = model.compactMap { t in t.hM.map { (d: t.dCm, h: $0) } }
        guard !pts.isEmpty else { return nil }
        let hs = pts.map(\.h)
        let mean = hs.reduce(0, +) / Double(hs.count)
        let ds = pts.map(\.d)
        if pts.count >= 3, (ds.max()! - ds.min()!) >= 4,
           let c = HeightCurve.fit(pts), let h = c.h(dg),
           h > hs.min()! * 0.7, h < hs.max()! * 1.3 {
            return (h, "līkne, \(pts.count)")
        }
        return (mean, "vid., \(pts.count)")
    }
}

struct SampleStandGroup: Identifiable {
    let id: String
    var plots: [SamplePlot]
    var summary: PlotSummary {
        PlotSummary(plots.flatMap(\.counted), plots: plots.count, model: plots.flatMap(\.trees))
    }
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
        if let old = cur.center, old.session != session, cur.trees.contains(where: { $0.session == old.session }) {
            var pc = cur.pastCenters ?? []
            pc.removeAll { $0.session == old.session }
            pc.append(old)
            cur.pastCenters = pc
        }
        let c = PlotCenter(x: p.x, y: p.y, z: p.z, session: session)
        cur.center = c
        cur.drift = nil
        // Centrs pārlikts tajā pašā sesijā → attālumi jāpārrēķina.
        for i in cur.trees.indices where cur.trees[i].session == session {
            let d = Double(simd_length(SIMD2(cur.trees[i].x, cur.trees[i].z) - c.xz))
            cur.trees[i].dist = d
            cur.trees[i].counted = d <= SampleArea.radius
        }
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

    // MARK: Atjaunošana pēc AR izsekošanas zuduma

    func pastCenter(_ session: String) -> PlotCenter? {
        cur.pastCenters?.first { $0.session == session }
    }

    /// Koki no iepriekšējām sesijām, kuru pozīcijas var atjaunot.
    func unrecovered(session: String) -> [PlotTree] {
        cur.trees.filter { $0.session != session && pastCenter($0.session) != nil }
    }

    /// Kuri no neatjaunotajiem kokiem visvairāk atbilst jaunajam mērījumam (pēc attāluma no centra un D).
    func candidates(dCm: Double, pos: SIMD3<Float>, session: String) -> [PlotTree] {
        guard let c = center(session: session) else { return [] }
        let r = Double(simd_length(SIMD2(pos.x, pos.z) - c.xz))
        func score(_ t: PlotTree) -> Double {
            abs(t.dist - r) / 0.5 + abs(t.dCm - dCm) / max(2, 0.1 * t.dCm)
        }
        return Array(unrecovered(session: session).sorted { score($0) < score($1) }.prefix(4))
    }

    struct Recovery {
        let tree: PlotTree
        let moved: Int
        let rotDeg: Double
        /// Starpība starp veco un jauno attālumu no centra, m (pārbaudei).
        let dr: Double
    }

    /// Centrs ir atzīmēts no jauna (tas pats mietiņš), un koks `id` ir pārmērīts pozīcijā `pos`.
    /// No tā aprēķina pagriezienu starp veco un jauno AR koordinātu sistēmu un pārnes visus
    /// tās sesijas kokus uz pašreizējo.
    func recover(using id: UUID, dCm: Double, method: String?, pos: SIMD3<Float>, session: String) -> Recovery? {
        guard let c1 = center(session: session),
              let i = cur.trees.firstIndex(where: { $0.id == id }),
              let c0 = pastCenter(cur.trees[i].session) else { return nil }
        let old = cur.trees[i], s0 = old.session
        let v0 = SIMD2(old.x - c0.x, old.z - c0.z)
        let v1 = SIMD2(pos.x - c1.x, pos.z - c1.z)
        guard simd_length(v0) > 0.5, simd_length(v1) > 0.5 else { return nil }
        let th = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
        let cs = cos(th), sn = sin(th)
        var moved = 0
        for k in cur.trees.indices where cur.trees[k].session == s0 {
            let t = cur.trees[k]
            let v = SIMD2(t.x - c0.x, t.z - c0.z)
            cur.trees[k].x = c1.x + v.x * cs - v.y * sn
            cur.trees[k].z = c1.z + v.x * sn + v.y * cs
            cur.trees[k].y = t.y - c0.y + c1.y
            cur.trees[k].session = session
            moved += 1
        }
        // Pārmērītais koks — jaunais mērījums.
        let d = Double(simd_length(v1))
        cur.trees[i].x = pos.x; cur.trees[i].y = pos.y; cur.trees[i].z = pos.z
        cur.trees[i].dCm = dCm; cur.trees[i].dMethod = method
        cur.trees[i].dist = d; cur.trees[i].counted = d <= SampleArea.radius
        cur.pastCenters?.removeAll { $0.session == s0 }
        saveCur()
        var deg = Double(th) * 180 / .pi
        while deg > 180 { deg -= 360 }
        while deg <= -180 { deg += 360 }
        return Recovery(tree: cur.trees[i], moved: moved, rotDeg: deg, dr: abs(d - old.dist))
    }

    func setHeight(_ id: UUID, h: Double?, dist: Double?) {
        guard let i = cur.trees.firstIndex(where: { $0.id == id }) else { return }
        cur.trees[i].hM = h
        cur.trees[i].hDist = dist
        saveCur()
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
                    "attalums_no_centra_m", "ieskaitits", "robezkoks", "D_metode", "H_m", "H_attalums_m"]
        var rows: [String] = []
        for p in plots {
            for t in p.trees {
                rows.append([p.stand, String(p.no), df.string(from: p.date), tf.string(from: p.date),
                             Self.num(p.lat, 6), Self.num(p.lon, 6), String(t.no), t.species, Self.num(t.dCm, 1),
                             Self.num(t.dist, 2), t.counted ? "jā" : "nē", t.status == .border ? "jā" : "nē",
                             t.dMethod ?? "", Self.num(t.hM, 1), Self.num(t.hDist, 1)]
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
                    "radiuss_m", "centra_nobide_m", "koki", "N_ha", "G_m2_ha", "D_vid_cm", "Dg_cm", "H_m", "modelkoki", "M_m3_ha", "sastavs"]
            + sp.map { "G_\($0)" } + sp.map { "M_\($0)" }
        let rows = plots.map { p -> String in
            let s = p.summary
            let g = Dictionary(uniqueKeysWithValues: s.species.map { ($0.id, $0.gHa) })
            let mv = Dictionary(uniqueKeysWithValues: s.species.map { ($0.id, $0.m) })
            let r = [p.stand, String(p.no), df.string(from: p.date), tf.string(from: p.date),
                     Self.num(p.lat, 6), Self.num(p.lon, 6), Self.num(p.acc, 0), Self.num(SampleArea.radius, 2),
                     Self.num(p.drift, 2), String(s.n), Self.num(s.nHa, 0), Self.num(s.gHa, 1),
                     Self.num(s.dMean, 1), Self.num(s.dg, 1), Self.num(s.h, 1), String(s.models), Self.num(s.m, 0), s.composition]
                + sp.map { Self.num(g[$0] ?? 0, 1) } + sp.map { Self.num(mv[$0] ?? nil, 0) }
            return r.map(csvCell).joined(separator: ";")
        }
        return "\u{FEFF}" + ([head.joined(separator: ";")] + rows).joined(separator: "\r\n")
    }
}

// MARK: - Ieteicamie modeļkoki

/// Sugas augstums = koka ar Dg caurmēru augstums, tāpēc par modeļkokiem iesaka kokus ar caurmēru
/// vistuvāk sugas Dg. Galvenajām sugām (≥ 20 % no G) — 3 modeļkoki, piemistrojumam — 1.
struct ModelAdvice: Identifiable {
    let species: String
    let dg: Double
    let have: Int
    let target: Int
    let trees: [PlotTree]
    var id: String { species }
}

extension SamplePlotModel {
    var modelAdvice: [ModelAdvice] {
        let counted = cur.trees.filter(\.counted)
        let total = counted.reduce(0) { $0 + SampleArea.ba($1.dCm) }
        guard total > 0 else { return [] }
        return Dictionary(grouping: counted, by: \.species).compactMap { sp, t -> (ModelAdvice, Double)? in
            // Kamēr koku maz, Dg vēl mainās — iesaka tikai, kad sugai ir ≥ 3 koki vai laukumā ≥ 10.
            guard t.count >= 3 || counted.count >= 10, let dg = PlotSummary.dg(t) else { return nil }
            let g = t.reduce(0) { $0 + SampleArea.ba($1.dCm) }
            let target = g / total >= 0.2 ? 3 : 1
            let have = cur.trees.filter { $0.species == sp && $0.hM != nil }.count
            let need = max(0, target - have)
            let pick = t.filter { $0.hM == nil }
                .sorted { abs($0.dCm - dg) < abs($1.dCm - dg) }
                .prefix(need)
            return (ModelAdvice(species: sp, dg: dg, have: have, target: target, trees: Array(pick)), g)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var recommendedIDs: Set<UUID> { Set(modelAdvice.flatMap { $0.trees.map(\.id) }) }
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
    func drawPlot(center: SIMD3<Float>?, trees: [PlotTree], recommended: Set<UUID> = []) {
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
            if recommended.contains(t.id) {
                // Ieteicams modeļkoks: otrs, gaiši zils gredzens nedaudz augstāk.
                let r = ModelEntity(mesh: m, materials: [Self.mat(.systemCyan, 0.95)])
                r.position = SIMD3(t.x, t.y + 0.15, t.z)
                anchor.addChild(r)
            }
            if let h = t.hM {
                // Modeļkoks: sarkans stabs no zemes līdz galotnei.
                let base = t.y - Self.breastHeight
                let pole = ModelEntity(mesh: .generateCylinder(height: Float(h), radius: 0.012),
                                       materials: [Self.mat(.systemRed, 0.55)])
                pole.position = SIMD3(t.x, base + Float(h) / 2, t.z)
                anchor.addChild(pole)
                let top = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [Self.mat(.systemRed, 0.8)])
                top.position = SIMD3(t.x, base + Float(h), t.z)
                anchor.addChild(top)
            }
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

    private enum Pending: Equatable { case none, markCenter, checkCenter, recover, height(UUID) }
    @State private var pending: Pending = .none
    /// Pēdējais izmērītais koks — tam var uzreiz izmērīt augstumu.
    @State private var lastTree: UUID? = nil
    @State private var showTrees = false
    @State private var confirmDiscard = false

    /// Pārmērīts koks, kuru jāsasaista ar kādu no agrāk izmērītajiem.
    private struct RecoverMeasure {
        let dCm: Double
        let method: String?
        let pos: SIMD3<Float>
        let r: Double
        let candidates: [PlotTree]
    }
    @State private var recoverAsk: RecoverMeasure? = nil

    private var center: PlotCenter? { sp.center(session: m.sessionID) }
    private var lost: Bool { sp.cur.center != nil && center == nil }
    private var aimingCenter: Bool { center == nil || pending == .markCenter || pending == .checkCenter }
    private var unrecovered: [PlotTree] { sp.unrecovered(session: m.sessionID) }
    private var counted: [PlotTree] { sp.cur.trees.filter(\.counted) }
    private var heightTree: PlotTree? {
        if case .height(let id) = pending { return sp.cur.trees.first { $0.id == id } }
        return nil
    }
    /// Pēdējais koks, ja tam var mērīt augstumu (ir AR pozīcija šajā sesijā).
    private var lastForHeight: PlotTree? {
        guard let id = lastTree, let t = sp.cur.trees.first(where: { $0.id == id }), t.session == m.sessionID else { return nil }
        return t
    }

    var body: some View {
        let sum = PlotSummary(counted, model: sp.cur.trees)
        VStack(spacing: 10) {
            status

            VStack(spacing: 4) {
                Text("Nogabals \(stand.isEmpty ? "—" : stand) · laukums Nr. \(sp.cur.no)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    valueBox("Koki", "\(counted.count)")
                    valueBox("G m²/ha", sum.n > 0 ? fmt(sum.gHa, 1) : "—")
                    valueBox("Dg cm", sum.dg.map { fmt($0, 1) } ?? "—")
                    valueBox("H m", sum.h.map { fmt($0, 1) } ?? "—")
                    valueBox("M m³/ha", sum.m.map { (sum.mApprox ? "≈" : "") + fmt($0, 0) } ?? "—")
                }
            }

            SpeciesChips(species: $species,
                         counts: Dictionary(grouping: counted, by: \.species).mapValues { Double($0.count) })

            HStack(spacing: 10) {
                Menu {
                    Button { if let t = lastForHeight { startHeight(t) } } label: {
                        Label("Augstums pēdējam kokam", systemImage: "arrow.up.to.line")
                    }
                    .disabled(lastForHeight == nil)
                    Button { undo() } label: { Label("Atsaukt pēdējo koku", systemImage: "arrow.uturn.backward") }
                        .disabled(sp.cur.trees.isEmpty)
                    Button { pending = .checkCenter } label: { Label("Pārbaudīt centra nobīdi", systemImage: "scope") }
                        .disabled(center == nil)
                    Button { pending = .markCenter } label: { Label("Atzīmēt centru no jauna", systemImage: "mappin.and.ellipse") }
                    Button { pending = .recover } label: {
                        Label("Atjaunot pēc zināma koka", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(center == nil || unrecovered.isEmpty)
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
                .buttonStyle(.borderedProminent).tint(aimingCenter ? .orange : (heightTree != nil ? .blue : .green))

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
        .onChange(of: m.heightCount) { heightMeasured() }
        .confirmationDialog("Kurš no agrāk izmērītajiem kokiem tas ir?",
                            isPresented: Binding(get: { recoverAsk != nil }, set: { if !$0 { recoverAsk = nil } }),
                            titleVisibility: .visible, presenting: recoverAsk) { r in
            ForEach(r.candidates) { t in
                Button("#\(t.no) \(Species.name(t.species)) · D \(fmt(t.dCm, 1)) · \(fmt(t.dist, 1)) m") {
                    doRecover(r, t)
                }
            }
            Button("Jauns koks — pievienot") { addMeasured(r.dCm, r.method, r.pos) }
            Button("Atcelt", role: .cancel) {}
        } message: { r in
            Text("Izmērīts: D \(fmt(r.dCm, 1)) cm, \(fmt(r.r, 1)) m no centra")
        }
        .sheet(isPresented: $showTrees) { PlotTreesView(onHeight: { t in startHeight(t) }) }
        .confirmationDialog("Dzēst laukuma Nr. \(sp.cur.no) centru un \(sp.cur.trees.count) kokus?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Dzēst un sākt no jauna", role: .destructive) {
                sp.discardCurrent()
                m.resetTree()
                pending = .none
                lastTree = nil
            }
        }
    }

    /// Statusa laukums ar fiksētām rindām (virsraksts · rādījums · 2 rindas detaļu · darbība · 2 rindas ziņojuma),
    /// lai panelis nemaina augstumu un pogas nekustas.
    private var status: some View {
        VStack(spacing: 2) {
            FixedLines(1, .subheadline.bold()) {
                if m.busy {
                    Text("Mēra… turi tēmēkli uz stumbra").font(.subheadline.bold())
                } else if aimingCenter {
                    Text(lost && pending == .none ? "AR izsekošana atiestatīta" : " ")
                        .font(.subheadline.bold()).foregroundStyle(.orange)
                } else if let t = heightTree {
                    Text("Modeļkoks #\(t.no) \(Species.name(t.species)) — augstums")
                        .font(.subheadline.bold()).foregroundStyle(.cyan)
                } else if pending == .recover {
                    Text("Pārmēri jau izmērītu koku (vēlams tālāk no centra)")
                        .font(.subheadline.bold()).foregroundStyle(.orange)
                }
            }
            FixedLines(1, .system(size: 28, weight: .bold, design: .rounded)) {
                if m.busy {
                    ProgressView(value: m.progress).tint(.green).padding(.horizontal, 20)
                } else if aimingCenter {
                    Text(pending == .checkCenter ? "Pārbaudi centru" : "Atzīmē laukuma centru")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                } else {
                    Text(m.live.main.isEmpty ? " " : m.live.main)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(m.live.good ? Color.green : Color.white)
                }
            }
            FixedLines(2, .footnote) {
                Text(detailText).font(.footnote).foregroundStyle(.secondary)
            }
            FixedLines(1, .footnote.bold()) { actionRow }
            FixedLines(2, .footnote.bold()) {
                Text(m.message ?? " ").font(.footnote.bold()).foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var detailText: String {
        if m.busy { return " " }
        if aimingCenter {
            var s = "Tēmē uz centra mietiņa pamatni (1–3 m) un spied pogu"
            if lost && pending == .none { s += "; tad pārmēri vienu jau izmērītu koku" }
            return s
        }
        if heightTree != nil && m.live.detail.isEmpty { return "Atkāpies (ideāli ~ koka augstuma attālumā), tēmē galotni" }
        return m.live.detail
    }

    @ViewBuilder private var actionRow: some View {
        if m.busy {
            Text(" ")
        } else if aimingCenter {
            if pending != .none { Button("Atcelt") { pending = .none } } else { Text(" ") }
        } else if heightTree != nil {
            Button("Atcelt augstumu") { cancelHeight() }
        } else if pending == .recover {
            Button("Atcelt atjaunošanu") { pending = .none }
        } else {
            HStack(spacing: 14) {
                if let t = lastForHeight {
                    Button {
                        startHeight(t)
                    } label: {
                        Label(t.hM != nil ? "Pārmērīt augstumu #\(t.no)"
                                : (sp.recommendedIDs.contains(t.id) ? "Augstums #\(t.no) — ieteicams modeļkoks"
                                   : "Augstums #\(t.no) (modeļkoks)"),
                              systemImage: sp.recommendedIDs.contains(t.id) ? "star.fill" : "arrow.up.to.line")
                    }
                }
                if !unrecovered.isEmpty {
                    Button { pending = .recover } label: {
                        Text("\(unrecovered.count) bez AR pozīcijas · ").foregroundStyle(.orange) + Text("Atjaunot")
                    }
                }
                if lastForHeight == nil && unrecovered.isEmpty { Text(" ") }
            }
        }
    }

    private var actionTitle: String {
        switch pending {
        case .checkCenter: return "Pārbaudīt centru"
        case .markCenter: return "Atzīmēt centru"
        case .recover: return "Pārmērīt zināmu koku"
        case .height: return "Atzīmēt galotni"
        case .none: return center == nil ? "Atzīmēt centru" : "Mērīt caurmēru"
        }
    }

    private func redraw() {
        let c = center
        m.plotCenter = c?.xz
        m.drawPlot(center: c?.pos, trees: sp.cur.trees, recommended: sp.recommendedIDs)
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
                pending = .none
            } else {
                sp.setCenter(p, session: m.sessionID, location: location.recent)
                if sp.unrecovered(session: m.sessionID).isEmpty {
                    m.message = "Centrs atzīmēts — mēri kokus"
                    pending = .none
                } else {
                    m.message = "Centrs atzīmēts — tagad pārmēri vienu jau izmērītu koku"
                    pending = .recover
                }
            }
            Haptics.ok()
        }
    }

    private func treeMeasured() {
        guard let d = m.tree.dCm, let a = m.tree.axisXZ, let y = m.tree.dY else { return }
        let pos = SIMD3(a.x, y, a.y)
        if pending == .recover, let c = center {
            let cand = sp.candidates(dCm: d, pos: pos, session: m.sessionID)
            if !cand.isEmpty {
                recoverAsk = RecoverMeasure(dCm: d, method: m.tree.dMethod, pos: pos,
                                            r: Double(simd_length(SIMD2(pos.x, pos.z) - c.xz)), candidates: cand)
                return
            }
            pending = .none
        }
        addMeasured(d, m.tree.dMethod, pos)
    }

    private func doRecover(_ r: RecoverMeasure, _ t: PlotTree) {
        guard let res = sp.recover(using: t.id, dCm: r.dCm, method: r.method, pos: r.pos, session: m.sessionID) else {
            m.message = "Neizdevās — koks ir par tuvu centram. Izvēlies koku tālāk no mietiņa."
            Haptics.fail()
            return
        }
        pending = .none
        lastTree = res.tree.id
        var s = "Atjaunots pēc #\(res.tree.no): \(res.moved) koki, pagrieziens \(fmt(res.rotDeg, 0))°"
        s += "\nattāluma starpība \(fmt(res.dr * 100, 0)) cm"
        if res.dr > SampleArea.border {
            s += " — liela! Pārbaudi koku un centru."
            Haptics.fail()
        } else {
            Haptics.ok()
        }
        m.message = s
    }

    private func addMeasured(_ d: Double, _ method: String?, _ pos: SIMD3<Float>) {
        guard let r = sp.addTree(dCm: d, method: method, pos: pos,
                                 species: species, session: m.sessionID) else {
            m.message = "Vispirms atzīmē laukuma centru"
            return
        }
        let t = r.tree
        lastTree = t.id
        var s = "#\(t.no) \(Species.name(t.species)) · D \(fmt(t.dCm, 1)) cm · \(fmt(t.dist, 1)) m — \(t.status.title)"
        if case .replaced = r { s = "Pārmērīts " + s }
        if !t.counted { s += " (neskaita)" }
        if t.status == .border { s += "\npārbaudi ar mērlenti; sarakstā var ieskaitīt/izslēgt" }
        m.message = s
    }

    private func startHeight(_ t: PlotTree) {
        guard t.session == m.sessionID else {
            m.message = "Kokam #\(t.no) nav AR pozīcijas — vispirms atjauno centru"
            Haptics.fail()
            return
        }
        m.setHeightTarget(axis: SIMD2(t.x, t.z), dY: t.y)
        pending = .height(t.id)
        m.message = nil
    }

    private func cancelHeight() {
        pending = .none
        m.mode = .diameter
    }

    private func heightMeasured() {
        guard case .height(let id) = pending, let h = m.tree.hM else { return }
        sp.setHeight(id, h: h, dist: m.tree.hDist)
        pending = .none
        m.mode = .diameter
        let no = sp.cur.trees.first { $0.id == id }?.no
        m.message = "Modeļkoks #\(no.map(String.init) ?? "?") · H \(fmt(h, 1)) m"
    }

    private func undo() {
        if let t = sp.undoLast() {
            if heightTree == nil, case .height = pending { cancelHeight() }
            if lastTree == t.id { lastTree = nil }
            m.resetTree()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { m.message = "Atsaukts #\(t.no)" }
        }
    }
}

func valueBox(_ title: String, _ value: String) -> some View {
    VStack(spacing: 0) {
        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
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
        HStack {
            Text("H \(s.h.map { fmt($0, 1) + " m" } ?? "—")")
            Spacer()
            Text("modeļkoki: \(s.models)")
        }
        .font(.subheadline).monospacedDigit()
        HStack {
            Text("M \(s.m.map { (s.mApprox ? "≈ " : "") + fmt($0, 0) + " m³/ha" } ?? "— (vajag modeļkokus)")")
                .font(.headline)
            Spacer()
        }
        .monospacedDigit()
        ForEach(s.species) { x in
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(Species.name(x.id)).frame(width: 100, alignment: .leading)
                    Text("\(x.n) gab.").frame(width: 55, alignment: .leading)
                    Spacer()
                    Text("G \(fmt(x.gHa, 1)) · Dg \(fmt(x.dg, 1))")
                }
                HStack {
                    if let h = x.h {
                        Text("H \(fmt(h, 1)) m (\(x.hNote ?? ""))")
                    } else if x.hFromStand {
                        Text("H — audzes H")
                    }
                    Spacer()
                    if let m = x.m {
                        Text("M \(fmt(m, 0)) m³/ha" + (x.hfExtrapolated ? " (ārpus tab.)" : ""))
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct PlotTreeRow: View {
    let t: PlotTree
    var recommended = false
    var body: some View {
        HStack {
            Circle()
                .fill(!t.counted ? Color.gray : (t.status == .border ? Color.yellow : Color.green))
                .frame(width: 10, height: 10)
            Text("#\(t.no) \(Species.name(t.species))")
            if recommended {
                Label("modeļkoks", systemImage: "star.fill")
                    .font(.caption.bold()).foregroundStyle(.cyan)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("D \(fmt(t.dCm, 1)) cm" + (t.hM.map { " · H \(fmt($0, 1)) m" } ?? "")).monospacedDigit()
                Text("\(fmt(t.dist, 2)) m · \(t.status.title)\(t.counted ? "" : ", neskaita")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pašreizējā laukuma koki, rādītāji un saglabāšana.
struct PlotTreesView: View {
    var onHeight: (PlotTree) -> Void = { _ in }
    @EnvironmentObject var sp: SamplePlotModel
    @EnvironmentObject var m: Measurer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stand") private var stand = ""
    private var recommended: Set<UUID> { sp.recommendedIDs }

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
                let advice = sp.modelAdvice
                if advice.contains(where: { !$0.trees.isEmpty }) {
                    Section {
                        ForEach(advice.filter { !$0.trees.isEmpty }) { a in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(Species.name(a.species)) — Dg \(fmt(a.dg, 1)) cm · modeļkoki \(a.have)/\(a.target)")
                                    .font(.subheadline.bold())
                                HStack(spacing: 8) {
                                    ForEach(a.trees) { t in
                                        Button {
                                            dismiss(); onHeight(t)
                                        } label: {
                                            Label("#\(t.no) · D \(fmt(t.dCm, 1))", systemImage: "arrow.up.to.line")
                                                .font(.caption.bold())
                                        }
                                        .buttonStyle(.bordered).tint(.cyan)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Ieteicamie modeļkoki")
                    } footer: {
                        Text("Sugas augstums ir koka ar Dg caurmēru augstums — tāpēc iesaka kokus ar caurmēru vistuvāk Dg. Galvenajām sugām 3, piemistrojumam 1. Ja koks nav piemērots (nolūzusi galotne, nav redzama), izvēlies citu līdzīga resnuma. Pieskaries — mērīt augstumu.")
                    }
                }
                Section("Rādītāji (R = \(fmt(SampleArea.radius, 2)) m)") {
                    SummaryRows(s: PlotSummary(sp.cur.trees.filter(\.counted), model: sp.cur.trees))
                }
                Section {
                    ForEach(sp.cur.trees.reversed()) { t in
                        PlotTreeRow(t: t, recommended: recommended.contains(t.id))
                            .contentShape(Rectangle())
                            .onTapGesture { sp.toggle(t.id) }
                            .swipeActions { Button("Dzēst", role: .destructive) { sp.deleteTree(t.id) } }
                            .swipeActions(edge: .leading) {
                                Button("Augstums") { dismiss(); onHeight(t) }.tint(.blue)
                                if t.hM != nil {
                                    Button("Bez H") { sp.setHeight(t.id, h: nil, dist: nil) }.tint(.gray)
                                }
                            }
                    }
                } header: {
                    Text("Koki (\(sp.cur.trees.count))")
                } footer: {
                    Text("Pieskaries kokam, lai to ieskaitītu vai izslēgtu (piem. robežkoku pēc pārbaudes ar mērlenti). Velc pa labi — modeļkoka augstums.")
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

// MARK: - Mini-karte (skats no augšas; telefona virziens vienmēr uz augšu)

struct PlotMiniMap: View {
    @EnvironmentObject var sp: SamplePlotModel
    @EnvironmentObject var m: Measurer
    @ObservedObject var pose: Pose
    @AppStorage("plotMapBig") private var big = false

    var body: some View {
        if let c = sp.center(session: m.sessionID) {
            let S: CGFloat = big ? 250 : 130
            let trees = sp.cur.trees.filter { $0.session == m.sessionID }
            let rec = sp.recommendedIDs
            let me = pose.pos
            let dist = me.map { Double(simd_length($0 - c.xz)) }
            VStack(spacing: 3) {
                Canvas { ctx, size in
                    draw(ctx, size: size, c: c.xz, trees: trees, rec: rec, me: me, headingDeg: pose.mapHeading)
                }
                .frame(width: S, height: S)
                .contentShape(Circle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { big.toggle() } }
                .accessibilityLabel("Parauglaukuma karte")
                if let d = dist {
                    Text(d <= SampleArea.radius ? "līdz centram \(fmt(d, 1)) m" : "ārpus laukuma · \(fmt(d, 1)) m")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(d <= SampleArea.radius ? Color.white : Color.orange)
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, c: SIMD2<Float>, trees: [PlotTree], rec: Set<UUID>,
                      me: SIMD2<Float>?, headingDeg: Double) {
        let W = size.width, H = size.height
        let mid = CGPoint(x: W / 2, y: H / 2)
        let rMax = min(W, H) / 2 - 3
        let k = (rMax - 6) / CGFloat(SampleArea.radius)      // punkti uz metru

        // Pagrieziens: telefona skatīšanās virziens (f) = uz augšu, labā puse (r) = pa labi.
        let h = headingDeg * .pi / 180
        let f = SIMD2(Float(sin(h)), Float(-cos(h)))
        let r = SIMD2(Float(cos(h)), Float(sin(h)))
        func pt(_ p: SIMD2<Float>, clamp: Bool = false) -> CGPoint {
            let v = p - c
            var x = CGFloat(simd_dot(v, r)) * k, y = -CGFloat(simd_dot(v, f)) * k
            if clamp {
                let l = (x * x + y * y).squareRoot(), lim = rMax - 5
                if l > lim { x *= lim / l; y *= lim / l }
            }
            return CGPoint(x: mid.x + x, y: mid.y + y)
        }
        func circle(_ p: CGPoint, _ rad: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad))
        }

        ctx.fill(circle(mid, rMax), with: .color(.black.opacity(0.55)))
        for ring in [5.0, 10.0] {
            ctx.stroke(circle(mid, CGFloat(ring) * k), with: .color(.white.opacity(0.15)), lineWidth: 1)
        }
        ctx.stroke(circle(mid, CGFloat(SampleArea.radius) * k), with: .color(.orange), lineWidth: 2)

        var cross = Path()
        cross.move(to: CGPoint(x: mid.x - 5, y: mid.y)); cross.addLine(to: CGPoint(x: mid.x + 5, y: mid.y))
        cross.move(to: CGPoint(x: mid.x, y: mid.y - 5)); cross.addLine(to: CGPoint(x: mid.x, y: mid.y + 5))
        ctx.stroke(cross, with: .color(.orange), lineWidth: 2)

        for t in trees {
            let p = pt(SIMD2(t.x, t.z), clamp: true)
            let rad = CGFloat(2.5 + min(t.dCm, 60) / 15) * (big ? 1.3 : 1)
            let col: Color = !t.counted ? .gray : (t.status == .border ? .yellow : .green)
            ctx.fill(circle(p, rad), with: .color(col))
            if t.hM != nil {
                ctx.stroke(circle(p, rad + 2), with: .color(.red), lineWidth: 1.5)
            } else if rec.contains(t.id) {
                ctx.stroke(circle(p, rad + 2.5), with: .color(.cyan), lineWidth: 2)
            }
            if big {
                ctx.draw(Text("\(t.no)").font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: p.x + rad + 6, y: p.y - rad - 3))
            }
        }

        if let me {
            let p = pt(me, clamp: true)
            var cone = Path()
            cone.move(to: p)
            cone.addLine(to: CGPoint(x: p.x - 14, y: p.y - 28))
            cone.addLine(to: CGPoint(x: p.x + 14, y: p.y - 28))
            cone.closeSubpath()
            ctx.fill(cone, with: .color(.blue.opacity(0.3)))
            ctx.fill(circle(p, 5.5), with: .color(.white))
            ctx.fill(circle(p, 4), with: .color(.blue))
        }
    }
}

/// Satura vieta, kas vienmēr aizņem `lines` teksta rindu augstumu (saturs tiek uzlikts virsū un
/// nemaina izkārtojumu) — lai paneļi nelēkā, mainoties ziņojumiem.
struct FixedLines<Content: View>: View {
    let lines: Int
    let font: Font
    let content: Content

    init(_ lines: Int, _ font: Font, @ViewBuilder content: () -> Content) {
        self.lines = lines
        self.font = font
        self.content = content()
    }

    var body: some View {
        Text(Array(repeating: "Ag", count: lines).joined(separator: "\n"))
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay {
                content
                    .lineLimit(lines)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
    }
}
