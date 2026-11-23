import ARKit
import CoreLocation
import Metal
import RealityKit
import SwiftUI

// MARK: - Formulas (tās pašas, kas PWA calc.js)

enum Calc {
    /// sin(θ/2), kur θ — kritiskais leņķis; BAF = 10 000·sin²(θ/2).
    /// Slīpuma korekcija: koks skaitās, ja horizontālais attālums ≤ R.
    static func critSin(baf: Double, slopeDeg: Double) -> Double {
        sqrt(baf) / 100 * cos(slopeDeg * .pi / 180)
    }

    static func critAngleDeg(_ baf: Double) -> Double {
        2 * asin(sqrt(baf) / 100) * 180 / .pi
    }

    /// Atstarpe starp mērlīnijām / prizmas nobīde, ja F — fokusa attālums tajās pašās vienībās.
    static func gaugeWidth(F: Double, sinHalf s: Double) -> Double {
        2 * F * tan(asin(min(0.5, s)))
    }

    /// Robežattālums (horizontāli līdz stumbra centram), m.
    static func maxDistance(dCm: Double, baf: Double) -> Double {
        0.5 * dCm / sqrt(baf)
    }

    /// Sastāva formula pēc šķērslaukuma daļām desmitdaļās, piem. „6P3E1B+A”.
    static func composition(_ ba: [String: Double]) -> String {
        let order = Species.all.map(\.id)
        let entries = ba.filter { $0.value > 0 }
            .sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
        let total = entries.reduce(0) { $0 + $1.value }
        guard total > 0 else { return "—" }
        struct Part { let k: String; let x: Double; var n: Int; let rem: Double; let i: Int }
        var parts: [Part] = entries.enumerated().map { (i, e) in
            let x = e.value / total * 10
            let n = Int(x.rounded(.down))
            return Part(k: e.key, x: x, n: n, rem: x - Double(n), i: i)
        }
        var left = 10 - parts.reduce(0) { $0 + $1.n }
        let byRem = parts.indices.sorted { parts[$0].rem != parts[$1].rem ? parts[$0].rem > parts[$1].rem : $0 < $1 }
        for idx in byRem where left > 0 {
            parts[idx].n += 1
            left -= 1
        }
        parts.sort { $0.n != $1.n ? $0.n > $1.n : ($0.x != $1.x ? $0.x > $1.x : $0.i < $1.i) }
        let main = parts.filter { $0.n > 0 }.map { "\($0.n)\($0.k)" }.joined()
        let plus = parts.filter { $0.n == 0 }.map { "+\($0.k)" }.joined()
        return main + plus
    }

    struct Stats { var n = 0; var mean = 0.0; var sd = 0.0; var se = 0.0; var ci = 0.0; var ciRel = 0.0 }

    /// Studenta t (95 %, divpusējs) brīvības pakāpēm 1..30.
    private static let t95: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                                        2.201, 2.179, 2.16, 2.145, 2.131, 2.12, 2.11, 2.101, 2.093, 2.086,
                                        2.08, 2.074, 2.069, 2.064, 2.06, 2.056, 2.052, 2.048, 2.045, 2.042]

    static func stats(_ v: [Double]) -> Stats {
        let n = v.count
        guard n > 0 else { return Stats() }
        let mean = v.reduce(0, +) / Double(n)
        guard n > 1 else { return Stats(n: n, mean: mean) }
        let sd = sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1))
        let se = sd / sqrt(Double(n))
        let t = n - 1 <= 30 ? t95[n - 2] : 1.96
        let ci = t * se
        return Stats(n: n, mean: mean, sd: sd, se: se, ci: ci, ciRel: mean > 0 ? ci / mean * 100 : 0)
    }
}

// MARK: - Kopīgie mērlīniju / prizmas parametri (lieto AR rinda, renderētājs un SwiftUI)

final class Gauge {
    static let shared = Gauge()
    static let bandFrac: Float = 0.12

    private let lock = NSLock()
    private var fy: Float = 0, imgW: Float = 1920, imgH: Float = 1440
    private var pitch: Float = 0
    private var prism = false, baf: Float = 2, slopeCorr = true, zoom: Float = 1

    func setCamera(_ cam: ARCamera) {
        lock.lock(); defer { lock.unlock() }
        fy = cam.intrinsics.columns.1.y
        imgW = Float(cam.imageResolution.width)
        imgH = Float(cam.imageResolution.height)
    }

    func setPitch(_ p: Float) {
        lock.lock(); pitch = p; lock.unlock()
    }

    func setBasal(prism: Bool, baf: Int, slopeCorr: Bool, zoom: Int) {
        lock.lock(); defer { lock.unlock() }
        self.prism = prism; self.baf = Float(baf); self.slopeCorr = slopeCorr; self.zoom = Float(zoom)
    }

    /// Fokusa attālums skatam ar izmēru w×h (portrets, attēls aizpilda ekrānu), tajās pašās vienībās.
    /// Kameras attēls ir guļus (piem. 1920×1440), portretā ekrāna horizontāle = attēla vertikāle.
    func focal(viewW: Float, viewH: Float) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard fy > 0 else { return nil }
        return fy * max(viewW / imgH, viewH / imgW)
    }

    /// Prizmas nobīde un joslas augstums renderētā attēla pikseļos (pirms digitālās tālummaiņas).
    func prismParams(texW: Int, texH: Int) -> (shift: Int, bandH: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard prism, fy > 0 else { return nil }
        let F = Double(fy * max(Float(texW) / imgH, Float(texH) / imgW))
        let s = Calc.critSin(baf: Double(baf), slopeDeg: slopeCorr ? Double(pitch) : 0)
        let shift = Int(Calc.gaugeWidth(F: F, sinHalf: s).rounded())
        let bandH = Int((Float(texH) * Self.bandFrac / zoom).rounded())
        return (shift, bandH)
    }
}

/// Virtuālā prizma: josla ekrāna vidū ar attēlu, nobīdītu par kritisko leņķi.
enum Prism {
    static func postProcess(_ ctx: ARView.PostProcessContext) {
        let src = ctx.sourceColorTexture, dst = ctx.targetColorTexture
        guard let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, to: dst)
        blit.endEncoding()

        guard let p = Gauge.shared.prismParams(texW: src.width, texH: src.height) else { return }
        let W = src.width, H = src.height
        let y0 = max(0, H / 2 - p.bandH / 2)
        let h = min(p.bandH, H - y0)
        guard p.shift > 0, p.shift < W, h > 0,
              let b2 = ctx.commandBuffer.makeBlitCommandEncoder() else { return }
        b2.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: y0, z: 0),
                sourceSize: MTLSize(width: W - p.shift, height: h, depth: 1),
                to: dst, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: p.shift, y: y0, z: 0))
        b2.endEncoding()
    }
}

// MARK: - Laukumi

struct Plot: Codable, Identifiable, Hashable {
    var id = UUID()
    var stand: String
    var no: Int
    var date: Date
    var baf: Int
    var counts: [String: Double]
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var slopeCorr: Bool
    var cover: Int?

    var n: Double { counts.values.reduce(0, +) }
    var G: Double { n * Double(baf) }
    var ba: [String: Double] { counts.mapValues { $0 * Double(baf) } }
}

struct CurrentPlot: Codable {
    struct Tally: Codable { var sp: String; var v: Double }
    var no = 1
    var counts: [String: Double] = [:]
    var hist: [Tally] = []
    var cover: Set<Int> = []
    var n: Double { counts.values.reduce(0, +) }
}

struct StandGroup: Identifiable {
    let id: String          // nogabals
    var plots: [Plot]
    /// Vidējais šķērslaukums pa sugām (sastāva formulai).
    var meanBA: [String: Double] {
        var r: [String: Double] = [:]
        for p in plots { for (k, v) in p.ba { r[k, default: 0] += v / Double(plots.count) } }
        return r
    }
}

struct Flash: Equatable {
    let text: String
    let color: Color
    let id = UUID()
}

final class BasalModel: ObservableObject {
    static let bafs = [1, 2, 3, 4]
    static let zooms = [1, 2, 3]

    @Published private(set) var plots: [Plot] = []
    @Published private(set) var cur = CurrentPlot()
    @Published private(set) var baf: Int { didSet { ud.set(baf, forKey: "b.baf"); pushGauge() } }
    @Published var prism: Bool { didSet { ud.set(prism, forKey: "b.prism"); pushGauge() } }
    @Published var slopeCorr: Bool { didSet { ud.set(slopeCorr, forKey: "b.slope"); pushGauge() } }
    @Published var zoom: Int { didSet { ud.set(zoom, forKey: "b.zoom"); pushGauge() } }
    @Published var flash: Flash? = nil

    /// Šķērslaukuma režīms redzams (prizma zīmējas tikai tad).
    var active = false { didSet { pushGauge() } }

    private let ud = UserDefaults.standard
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var plotsURL: URL { dir.appendingPathComponent("laukumi.json") }
    private var curURL: URL { dir.appendingPathComponent("laukums.json") }

    init() {
        let d = UserDefaults.standard   // self.ud vēl nedrīkst lietot
        baf = d.object(forKey: "b.baf") as? Int ?? 2
        prism = d.object(forKey: "b.prism") as? Bool ?? true
        slopeCorr = d.object(forKey: "b.slope") as? Bool ?? true
        zoom = d.object(forKey: "b.zoom") as? Int ?? 2
        if let d = try? Data(contentsOf: plotsURL), let p = try? JSONDecoder().decode([Plot].self, from: d) { plots = p }
        if let d = try? Data(contentsOf: curURL), let c = try? JSONDecoder().decode(CurrentPlot.self, from: d) { cur = c }
        pushGauge()
    }

    private func pushGauge() {
        Gauge.shared.setBasal(prism: active && prism, baf: baf, slopeCorr: slopeCorr, zoom: zoom)
    }

    private func savePlots() {
        if let d = try? JSONEncoder().encode(plots) { try? d.write(to: plotsURL, options: .atomic) }
    }

    private func saveCur() {
        if let d = try? JSONEncoder().encode(cur) { try? d.write(to: curURL, options: .atomic) }
    }

    func show(_ text: String, _ color: Color) {
        let f = Flash(text: text, color: color)
        withAnimation(.easeOut(duration: 0.1)) { flash = f }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if self.flash?.id == f.id { withAnimation(.easeIn(duration: 0.2)) { self.flash = nil } }
        }
    }

    // MARK: Skaitīšana

    /// BAF nosaka skaitīšanas leņķi, tāpēc mainot BAF, laukuma skaitījums sākas no jauna.
    func setBaf(_ b: Int) {
        guard b != baf else { return }
        if cur.n > 0 {
            cur.counts = [:]
            cur.hist = []
            cur.cover = []
            saveCur()
        }
        baf = b
        show("BAF \(b)", .white)
    }

    func add(_ v: Double, species sp: String) {
        cur.counts[sp, default: 0] += v
        cur.hist.append(.init(sp: sp, v: v))
        saveCur()
        Haptics.tap()
        show("\(v == 0.5 ? "+½" : "+1") \(Species.name(sp))", v == 0.5 ? .yellow : .green)
    }

    func undo() {
        guard let h = cur.hist.popLast() else { return }
        let left = (cur.counts[h.sp] ?? 0) - h.v
        cur.counts[h.sp] = left > 0 ? left : nil
        saveCur()
        show("−\(h.v == 0.5 ? "½" : "1") \(Species.name(h.sp))", .red)
    }

    func setNo(_ no: Int) {
        guard no > 0 else { return }
        cur.no = no
        saveCur()
    }

    func markCoverage(heading: Double, pitch: Double) {
        guard active, abs(pitch) <= 40 else { return }
        let bin = Int(heading / 5) % 72
        if cur.cover.insert(bin).inserted { saveCur() }
    }

    var coverDeg: Int { cur.cover.count * 5 }

    func savePlot(stand: String, location: CLLocation?) {
        let p = Plot(stand: stand, no: cur.no, date: Date(), baf: baf, counts: cur.counts,
                     lat: location?.coordinate.latitude, lon: location?.coordinate.longitude,
                     acc: location?.horizontalAccuracy, slopeCorr: slopeCorr, cover: coverDeg)
        plots.append(p)
        savePlots()
        cur = CurrentPlot(no: cur.no + 1)
        saveCur()
        Haptics.ok()
        show("Saglabāts: G = \(fmt(p.G, 1))", .green)
    }

    func delete(_ id: UUID) {
        plots.removeAll { $0.id == id }
        savePlots()
    }

    func deleteAll() {
        plots = []
        savePlots()
    }

    var standGroups: [StandGroup] {
        var order: [String] = []
        var m: [String: [Plot]] = [:]
        for p in plots {
            if m[p.stand] == nil { order.append(p.stand) }
            m[p.stand, default: []].append(p)
        }
        return order.map { StandGroup(id: $0, plots: m[$0]!) }
    }

    // MARK: CSV (tādas pašas kolonnas kā PWA)

    func csv() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "lv_LV"); df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "lv_LV"); tf.dateFormat = "HH:mm:ss"
        func num(_ x: Double?, _ d: Int) -> String { x.map { fmt($0, d) } ?? "" }
        let sp = Species.all.map(\.id)
        let head = ["nogabals", "laukums", "datums", "laiks", "platums", "garums", "gps_precizitate_m", "BAF",
                    "slipuma_korekcija", "kalibrets", "apgriezts_gradi"] + sp + ["koki_kopa", "G_m2_ha", "sastavs"]
        let rows = plots.map { p -> String in
            var r = [p.stand, String(p.no), df.string(from: p.date), tf.string(from: p.date),
                     num(p.lat, 6), num(p.lon, 6), num(p.acc, 0), String(p.baf),
                     p.slopeCorr ? "jā" : "nē", "jā", p.cover.map { String($0) } ?? ""]
            r += sp.map { num(p.counts[$0] ?? 0, 1) }
            r += [num(p.n, 1), num(p.G, 1), Calc.composition(p.ba)]
            return r.map(csvCell).joined(separator: ";")
        }
        return "\u{FEFF}" + ([head.joined(separator: ";")] + rows).joined(separator: "\r\n")
    }
}

// MARK: - GPS laukuma koordinātām

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var last: CLLocation?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: mgr.startUpdatingLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways {
            m.startUpdatingLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        last = locs.last
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    /// Pēdējā atrašanās vieta, ja ne vecāka par 3 min.
    var recent: CLLocation? {
        guard let l = last, -l.timestamp.timeIntervalSinceNow < 180 else { return nil }
        return l
    }
}
