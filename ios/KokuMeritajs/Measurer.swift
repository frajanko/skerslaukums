import ARKit
import RealityKit
import SwiftUI
import simd

enum Mode: Int, CaseIterable, Identifiable {
    case diameter, height
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .diameter: return "1 Caurmērs"
        case .height: return "2 Augstums"
        }
    }
    var action: String {
        switch self {
        case .diameter: return "Mērīt caurmēru"
        case .height: return "Atzīmēt galotni"
        }
    }
}

/// Dzīvie rādījumi ekrānā (atjaunojas ~10× sekundē).
struct LiveInfo {
    var main: String = ""
    var detail: String = ""
    var good: Bool = false
    var warning: String? = nil
}

/// Pašreizējā koka mērījumi.
struct TreeMeasure {
    var dY: Float? = nil                   // pasaules augstums, kur mērīts D (pieņemam 1,3 m virs zemes)
    var axisXZ: SIMD2<Float>? = nil        // stumbra ass
    var edges: (SIMD2<Float>, SIMD2<Float>)? = nil   // stumbra malas, ko redzēja telefons
    var dCm: Double? = nil
    var dMethod: String? = nil
    var dInfo: String? = nil
    var hM: Double? = nil
    var hDist: Double? = nil
    /// Atsevišķie caurmēra mērījumi (cm) un stumbra ass katrā — „Mērīt vēlreiz” tos vidējo.
    var dSamples: [Double] = []
    var axisSamples: [SIMD2<Double>] = []
    var isEmpty: Bool { dCm == nil && hM == nil }
}

/// Telefona virziens (šķērslaukuma režīmam): slīpums un pagrieziens.
final class Pose: ObservableObject {
    /// Grādi virs (+) / zem (−) horizonta.
    @Published var pitch: Double? = nil
    /// Grādi pulksteņrādītāja virzienā, relatīvi pret AR sesijas sākumu (kompass nav vajadzīgs).
    @Published var heading: Double? = nil
}

final class Measurer: NSObject, ObservableObject, ARSessionDelegate {
    static var lidarAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    @Published var mode: Mode = .diameter {
        didSet {
            let m = mode
            q.async { self.modeQ = m }
            if m != .diameter { showLive(nil, y: 0) }
        }
    }
    @Published var live = LiveInfo()
    @Published var tree = TreeMeasure()
    @Published var message: String? = nil
    @Published var busy = false
    @Published var progress: Double = 0
    /// Palielinās pēc katra veiksmīga caurmēra mērījuma (lai skats var to automātiski saglabāt).
    @Published var diameterCount = 0
    /// Palielinās pēc katras atzīmētas galotnes.
    @Published var heightCount = 0
    /// „Tikai caurmēri”: pēc caurmēra nepāriet uz augstumu.
    var diameterOnly = false
    /// AR koordinātu sistēmas identifikators: mainās, startējot lietotni un atiestatot izsekošanu.
    /// Saglabātās AR pozīcijas der tikai tajā pašā sesijā.
    @Published private(set) var sessionID = UUID().uuidString
    /// Parauglaukuma centrs (X, Z) — dzīvajos rādījumos rāda attālumu no tā.
    var plotCenter: SIMD2<Float>? = nil {
        didSet { let c = plotCenter; q.async { self.plotCenterQ = c } }
    }
    let pose = Pose()

    /// Koku režīms ieslēgts. Šķērslaukuma režīmā LiDAR stumbra meklēšana nav vajadzīga.
    var active = true {
        didSet {
            let a = active
            q.async { self.activeQ = a }
            if !a { showLive(nil, y: 0) }
        }
    }

    /// Krūšaugstums, m.
    static let breastHeight: Float = 1.3

    private let q = DispatchQueue(label: "koku.ar", qos: .userInitiated)
    private(set) weak var arView: ARView?
    var plotAnchor: AnchorEntity? = nil

    // Stāvoklis, kuru lieto tikai rindā `q`:
    private var modeQ: Mode = .diameter
    private var activeQ = true
    private var plotCenterQ: SIMD2<Float>? = nil
    private var treeQ = TreeMeasure()
    private var last: DepthSnapshot? = nil
    private var frameNo = 0
    private var capture: Capture? = nil

    private struct Capture {
        var y0: Float
        var aim: SIMD3<Float>
        var frames = 0
        var points: [SIMD2<Double>] = []
        var edgeD: [Double] = []
        var edgeC: [SIMD2<Double>] = []
        var nearest: [Double] = []
        /// Atkārtots mērījums tam pašam kokam (vidējos ar iepriekšējo).
        var again = false
        static let total = 45
    }

    // MARK: - Sesija

    func attach(_ view: ARView) {
        arView = view
        view.session.delegateQueue = q
        view.session.delegate = self
        start()
    }

    func start() {
        guard let s = arView?.session else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            cfg.frameSemantics.insert(.smoothedSceneDepth)
        }
        s.run(cfg)
    }

    /// Pilna sesijas atiestatīšana (ja izsekošana „aizpeldējusi”).
    func restart() {
        guard let s = arView?.session else { return }
        let cfg = s.configuration ?? ARWorldTrackingConfiguration()
        s.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        sessionID = UUID().uuidString
        resetTree()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // izpildās rindā q
        frameNo += 1
        if frameNo % 30 == 1 { Gauge.shared.setCamera(frame.camera) }
        if frameNo % 3 == 0 { publishPose(frame.camera) }

        guard activeQ || capture != nil else {
            if frameNo % 15 == 0 {
                publishLive(LiveInfo(warning: trackingWarning(frame.camera.trackingState)))
            }
            return
        }

        guard let snap = DepthSnapshot(frame: frame) else {
            if frameNo % 30 == 0 {
                publishLive(LiveInfo(main: "Nav LiDAR datu", detail: "", good: false, warning: nil))
            }
            return
        }
        last = snap

        if capture != nil {
            stepCapture(snap)
        } else if frameNo % 6 == 0 {
            updateLive(snap)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.message = "AR kļūda: \(error.localizedDescription)" }
    }

    private func publishPose(_ cam: ARCamera) {
        let c = cam.transform.columns.2
        let dir = -SIMD3(c.x, c.y, c.z)          // kamera skatās pa −Z
        let pitch = Double(asin(max(-1, min(1, dir.y)))) * 180 / .pi
        Gauge.shared.setPitch(Float(pitch))
        var heading: Double? = nil
        if simd_length(SIMD2(dir.x, dir.z)) > 0.2 {
            let h = Double(atan2(dir.x, -dir.z)) * 180 / .pi
            heading = (h + 360).truncatingRemainder(dividingBy: 360)
        }
        DispatchQueue.main.async {
            self.pose.pitch = pitch
            self.pose.heading = heading
        }
    }

    // MARK: - Dzīvie rādījumi

    private func trackingWarning(_ t: ARCamera.TrackingState) -> String? {
        switch t {
        case .normal: return nil
        case .notAvailable: return "Izsekošana nav pieejama"
        case .limited(let r):
            switch r {
            case .initializing: return "Inicializē — lēnām pakustini telefonu"
            case .excessiveMotion: return "Kustini lēnāk"
            case .insufficientFeatures: return "Par maz detaļu attēlā"
            case .relocalizing: return "Atjauno pozīciju…"
            @unknown default: return "Izsekošana ierobežota"
            }
        }
    }

    /// Zemes augstums: 1,3 m zem vietas, kur mērīts caurmērs.
    private func groundY() -> Float? {
        treeQ.dY.map { $0 - Self.breastHeight }
    }

    private func updateLive(_ s: DepthSnapshot) {
        var info = LiveInfo()
        info.warning = trackingWarning(s.tracking)
        let aim = s.aimPoint()
        let dist = aim.map { simd_length($0 - s.camPos) }
        var edges: (SIMD2<Float>, SIMD2<Float>)? = nil
        var edgeY: Float = 0

        switch modeQ {
        case .diameter:
            guard let aim, let dist else {
                info.main = "Par tālu LiDAR"
                info.detail = "Ieteicamais attālums 1–3 m"
                break
            }
            let slice = TrunkSlicer.slice(s, y0: aim.y, aim: aim)
            if let sl = slice, let d = sl.edgeDiameter, let ec = sl.edgeCenter {
                info.main = "≈ \(fmt(d * 100, 1)) cm"
                info.good = dist >= 0.5 && dist <= 3.5
                let cam = SIMD2(Double(s.camPos.x), Double(s.camPos.z))
                if let t = Geo.tangentPoints(center: ec, radius: d / 2, from: cam) {
                    edges = (SIMD2(Float(t.0.x), Float(t.0.y)), SIMD2(Float(t.1.x), Float(t.1.y)))
                    edgeY = aim.y
                }
            } else {
                info.main = "Stumbrs nav atrasts"
            }
            info.detail = "Tēmē stumbra vidū 1,3 m augstumā · attālums \(fmt(dist, 1)) m"
            if let pc = plotCenterQ {
                let tc = slice?.edgeCenter.map { SIMD2(Float($0.x), Float($0.y)) }
                    ?? SIMD2(aim.x, aim.z)
                let r = Double(simd_length(tc - pc))
                info.detail += "\nno centra \(fmt(r, 1)) m — " + SampleArea.status(r).title
            }

        case .height:
            guard let axis = treeQ.axisXZ, let ry = groundY() else {
                info.main = "Vispirms izmēri caurmēru"
                info.detail = "Augstumu skaita no 1,3 m zem caurmēra"
                break
            }
            if case let (H, L)? = heightOnAxis(s, axis: axis, baseY: ry) {
                info.main = "H ≈ \(fmt(H, 1)) m"
                let elev = asin(max(-1, min(1, s.aimDir.y))) * 180 / .pi
                info.detail = "līdz kokam \(fmt(L, 1)) m · leņķis \(fmt(elev, 0))°"
                info.good = L > 0.6 * H
                if L < 0.6 * H { info.detail += " · atkāpies tālāk" }
            } else {
                info.main = "Tēmē uz koka galotni"
            }
        }
        publishLive(info)
        let show = modeQ == .diameter
        DispatchQueue.main.async { self.showLive(show ? edges : nil, y: edgeY) }
    }

    private func publishLive(_ info: LiveInfo) {
        DispatchQueue.main.async { self.live = info }
    }

    /// Kur tēmēšanas stars šķērso koka asi (vertikāli virs `axis`): augstums virs `baseY`
    /// un horizontālais attālums līdz asij.
    private func heightOnAxis(_ s: DepthSnapshot, axis: SIMD2<Float>, baseY: Float) -> (Float, Float)? {
        let o = s.camPos, v = s.aimDir
        let vh = SIMD2(v.x, v.z)
        let n2 = simd_dot(vh, vh)
        guard n2 > 1e-4 else { return nil }
        let qv = axis - SIMD2(o.x, o.z)
        let t = simd_dot(qv, vh) / n2
        guard t > 0 else { return nil }
        let y = o.y + t * v.y
        return (y - baseY, simd_length(qv))
    }

    // MARK: - Darbības

    func act() {
        switch mode {
        case .diameter: startDiameter()
        case .height: markTop()
        }
    }

    /// Vēlreiz izmērīt to pašu koku; rezultāts — visu mērījumu vidējais caurmērs.
    func measureAgain() { startDiameter(again: true) }

    private func startDiameter(again: Bool = false) {
        q.async {
            guard self.capture == nil else { return }
            guard let s = self.last, let aim = s.aimPoint() else {
                self.say("LiDAR neredz stumbru — pieej tuvāk (1–3 m)")
                return
            }
            var c = Capture(y0: aim.y, aim: aim)
            c.again = again && !self.treeQ.dSamples.isEmpty
            self.capture = c
            DispatchQueue.main.async { self.busy = true; self.progress = 0; self.message = "Turi telefonu mierīgi…" }
        }
    }

    private func stepCapture(_ s: DepthSnapshot) {
        guard var c = capture else { return }
        c.frames += 1
        if let sl = TrunkSlicer.slice(s, y0: c.y0, aim: c.aim) {
            c.points.append(contentsOf: sl.points)
            if let d = sl.edgeDiameter { c.edgeD.append(d) }
            if let e = sl.edgeCenter { c.edgeC.append(e) }
            c.nearest.append(sl.nearest)
        }
        capture = c
        let p = Double(c.frames) / Double(Capture.total)
        DispatchQueue.main.async { self.progress = p }
        if c.frames >= Capture.total {
            capture = nil
            finishDiameter(c)
        }
    }

    private func finishDiameter(_ c: Capture) {
        // Punktu skaitu ierobežojam, lai fits būtu ātrs.
        var pts = c.points
        if pts.count > 20000 {
            let step = pts.count / 20000 + 1
            pts = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
        }
        let edge = Geo.median(c.edgeD)
        let nearest = Geo.median(c.nearest) ?? 0
        let circle = Geo.robustCircle(pts)

        var circleOK = false
        if let ci = circle, let s = last {
            let cam = SIMD2(Double(s.camPos.x), Double(s.camPos.z))
            let distC = simd_length(ci.center - cam)
            circleOK = ci.radius > 0.015 && ci.radius < 0.8
                && ci.rms < 0.015
                && ci.coverageDeg >= 50
                && distC > nearest + 0.5 * ci.radius
            if circleOK, let e = edge, abs(2 * ci.radius - e) / e > 0.35 { circleOK = false }
        }

        var d: Double? = nil, method = "", axis: SIMD2<Double>? = nil
        if circleOK, let ci = circle {
            d = 2 * ci.radius; method = "aplis"; axis = ci.center
        } else if let e = edge {
            d = e; method = "malas"
            if !c.edgeC.isEmpty {
                axis = c.edgeC.reduce(SIMD2<Double>(0, 0), +) / Double(c.edgeC.count)
            }
        }
        if axis == nil, let D = d, let s = last {
            // Rezerve: tēmēšanas punkts + rādiuss prom no kameras.
            let a = SIMD2(Double(c.aim.x), Double(c.aim.z))
            let v = a - SIMD2(Double(s.camPos.x), Double(s.camPos.z))
            let n = simd_length(v)
            axis = n > 1e-3 ? a + v / n * D / 2 : a
        }

        guard let D = d else {
            DispatchQueue.main.async {
                self.busy = false
                self.message = "Neizdevās. Pieej 1–3 m attālumā un tēmē stumbra vidū."
                Haptics.fail()
            }
            return
        }

        var info = "\(method)"
        if let ci = circle { info += String(format: " · aplis %.1f (±%.1f mm, %.0f°)", 2 * ci.radius * 100, ci.rms * 1000, ci.coverageDeg) }
        if let e = edge { info += String(format: " · malas %.1f", e * 100) }
        info += " · \(c.points.count) p."

        var samples = [D * 100]
        var axes = axis.map { [$0] } ?? []
        var note: String? = nil
        if c.again, let a = axis, let prev = treeQ.axisSamples.last {
            // Vai tas pats stumbrs? Asis nedrīkst atšķirties vairāk par pusi caurmēra (min. 15 cm).
            let gap = simd_length(a - prev)
            if gap <= max(0.15, D / 2) {
                samples = treeQ.dSamples + samples
                axes = treeQ.axisSamples + axes
            } else {
                note = "Šķiet cits koks (\(fmt(gap, 1)) m no iepriekšējā) — vidējo nerēķina, sākts jauns koks"
                treeQ = TreeMeasure()
            }
        }
        let Dcm = samples.reduce(0, +) / Double(samples.count)
        let Dm = Dcm / 100
        let meanAxis = axes.isEmpty ? nil : axes.reduce(SIMD2<Double>(0, 0), +) / Double(axes.count)
        if samples.count > 1 {
            let spread = samples.max()! - samples.min()!
            info = "\(samples.count) mērījumi: " + samples.map { fmt($0, 1) }.joined(separator: " · ")
                + " → \(fmt(Dcm, 1)) · pēdējais: " + info
            note = "Vidējais no \(samples.count) mērījumiem: \(fmt(Dcm, 1)) cm (starpība \(fmt(spread, 1)) cm)"
                + (spread > 0.1 * Dcm ? " — liela, mēri vēlreiz" : "")
            method += ", vid. \(samples.count)"
        }

        treeQ.dCm = Dcm
        treeQ.dMethod = method
        treeQ.dInfo = info
        treeQ.dSamples = samples
        treeQ.axisSamples = axes
        if samples.count == 1 || treeQ.dY == nil { treeQ.dY = c.y0 }
        treeQ.edges = nil
        if let a = meanAxis {
            treeQ.axisXZ = SIMD2(Float(a.x), Float(a.y))
            if let s = last,
               let t = Geo.tangentPoints(center: a, radius: Dm / 2, from: SIMD2(Double(s.camPos.x), Double(s.camPos.z))) {
                treeQ.edges = (SIMD2(Float(t.0.x), Float(t.0.y)), SIMD2(Float(t.1.x), Float(t.1.y)))
            }
        }
        let t = treeQ
        DispatchQueue.main.async {
            self.tree = t
            self.busy = false
            self.message = note
            self.placeMarkers()
            Haptics.ok()
            if !self.diameterOnly { self.mode = .height }
            self.diameterCount += 1
        }
    }

    private func markTop() {
        q.async {
            guard let s = self.last else { return }
            guard let axis = self.treeQ.axisXZ, let ry = self.groundY() else {
                self.say("Vispirms izmēri caurmēru")
                return
            }
            guard case let (H, L)? = self.heightOnAxis(s, axis: axis, baseY: ry), H > 1.5 else {
                self.say("Tēmē uz galotni virs koka")
                return
            }
            self.treeQ.hM = Double(H)
            self.treeQ.hDist = Double(L)
            let t = self.treeQ
            DispatchQueue.main.async {
                self.tree = t
                self.message = "Augstums \(fmt(H, 1)) m"
                self.placeMarkers()
                Haptics.ok()
                self.heightCount += 1
            }
        }
    }

    /// Punkts, uz kuru pašlaik tēmē (LiDAR), un kameras pozīcija — galvenajā pavedienā.
    func aimNow(_ done: @escaping (SIMD3<Float>?, SIMD3<Float>?) -> Void) {
        q.async {
            let p = self.last?.aimPoint(), c = self.last?.camPos
            DispatchQueue.main.async { done(p, c) }
        }
    }

    /// Augstuma mērīšana jau zināmam stumbram (ass `axis`, 1,3 m augstums pasaulē `dY`).
    func setHeightTarget(axis: SIMD2<Float>, dY: Float) {
        q.async {
            self.capture = nil
            self.treeQ = TreeMeasure()
            self.treeQ.axisXZ = axis
            self.treeQ.dY = dY
            let t = self.treeQ
            DispatchQueue.main.async {
                self.tree = t
                self.busy = false
                self.clearMarkers()
                self.mode = .height
            }
        }
    }

    /// Notīra pašreizējo koku; `message` — ziņojums, ko parādīt pēc tam.
    func resetTree(message: String? = nil) {
        q.async {
            self.treeQ = TreeMeasure()
            self.capture = nil
            DispatchQueue.main.async {
                self.tree = TreeMeasure()
                self.busy = false
                self.message = message
                self.mode = .diameter
                self.clearMarkers()
            }
        }
    }

    private func say(_ s: String) {
        DispatchQueue.main.async { self.message = s; Haptics.fail() }
    }

    // MARK: - Marķieri AR skatā (vizuāla pārbaude, vai mērījums sakrīt ar koku)

    private static let lineLen: Float = 0.7
    private static let lineR: Float = 0.006

    private var markerAnchor: AnchorEntity? = nil
    private var liveAnchor: AnchorEntity? = nil
    private var liveLines: [ModelEntity] = []

    static func mat(_ c: UIColor, _ o: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: c)
        m.blending = .transparent(opacity: .init(scale: o))
        return m
    }

    /// Baltās līnijas pie stumbra malām, kamēr tēmē (galvenajā pavedienā).
    private func showLive(_ e: (SIMD2<Float>, SIMD2<Float>)?, y: Float) {
        guard let view = arView else { return }
        if liveAnchor == nil {
            let a = AnchorEntity(world: matrix_identity_float4x4)
            for _ in 0..<2 {
                let l = ModelEntity(mesh: .generateCylinder(height: Self.lineLen, radius: Self.lineR),
                                    materials: [Self.mat(.white, 0.9)])
                l.isEnabled = false
                a.addChild(l)
                liveLines.append(l)
            }
            view.scene.addAnchor(a)
            liveAnchor = a
        }
        guard let e, active, !busy else {
            liveLines.forEach { $0.isEnabled = false }
            return
        }
        for (l, p) in zip(liveLines, [e.0, e.1]) {
            l.position = SIMD3(p.x, y, p.y)
            l.isEnabled = true
        }
    }

    private func clearMarkers() {
        if let a = markerAnchor { arView?.scene.removeAnchor(a) }
        markerAnchor = nil
    }

    private func placeMarkers() {
        guard let view = arView else { return }
        if let a = markerAnchor { view.scene.removeAnchor(a) }
        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        let t = tree

        if let e = t.edges, let y = t.dY {
            for p in [e.0, e.1] {
                let l = ModelEntity(mesh: .generateCylinder(height: Self.lineLen, radius: Self.lineR * 1.3),
                                    materials: [Self.mat(.systemGreen, 0.95)])
                l.position = SIMD3(p.x, y, p.y)
                anchor.addChild(l)
            }
        }
        if let h = t.hM, let axis = t.axisXZ, let dy = t.dY {
            let by = dy - Self.breastHeight
            let top = Float(h) + by
            let s = ModelEntity(mesh: .generateSphere(radius: 0.15), materials: [Self.mat(.systemRed, 0.8)])
            s.position = SIMD3(axis.x, top, axis.y)
            anchor.addChild(s)
            let pole = ModelEntity(mesh: .generateCylinder(height: Float(h), radius: 0.01), materials: [Self.mat(.systemRed, 0.5)])
            pole.position = SIMD3(axis.x, by + Float(h) / 2, axis.y)
            anchor.addChild(pole)
        }
        view.scene.addAnchor(anchor)
        markerAnchor = anchor
    }
}

enum Haptics {
    static func ok() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func fail() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

func fmt<T: BinaryFloatingPoint>(_ v: T, _ digits: Int) -> String {
    String(format: "%.\(digits)f", Double(v)).replacingOccurrences(of: ".", with: ",")
}

/// Skaits: vesels → „3”, ar pusi → „2,5”.
func fmtN(_ x: Double) -> String {
    x == x.rounded() ? String(Int(x)) : fmt(x, 1)
}
