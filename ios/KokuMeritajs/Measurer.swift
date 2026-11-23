import ARKit
import RealityKit
import SwiftUI
import simd

enum Mode: Int, CaseIterable, Identifiable {
    case base, diameter, height
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .base: return "1 Pamatne"
        case .diameter: return "2 Caurmērs"
        case .height: return "3 Augstums"
        }
    }
    var action: String {
        switch self {
        case .base: return "Atzīmēt pamatni"
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
    var baseY: Float? = nil
    var baseXZ: SIMD2<Float>? = nil
    var axisXZ: SIMD2<Float>? = nil        // stumbra ass pēc caurmēra mērījuma
    var dCm: Double? = nil
    var dMethod: String? = nil
    var dHeight: Double? = nil             // m virs pamatnes, kur mērīts caurmērs
    var dInfo: String? = nil
    var hM: Double? = nil
    var hBase: String? = nil               // "pamatne" vai "zemes plakne"
    var hDist: Double? = nil
    var hRefY: Float? = nil                // pamatnes augstums pasaules koordinātās
    var isEmpty: Bool { baseY == nil && dCm == nil && hM == nil }
}

final class Measurer: NSObject, ObservableObject, ARSessionDelegate {
    static var lidarAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    @Published var mode: Mode = .base { didSet { let m = mode; q.async { self.modeQ = m } } }
    @Published var live = LiveInfo()
    @Published var tree = TreeMeasure()
    @Published var message: String? = nil
    @Published var busy = false
    @Published var progress: Double = 0

    /// Krūšaugstums, m.
    static let breastHeight: Float = 1.3

    private let q = DispatchQueue(label: "koku.ar", qos: .userInitiated)
    private weak var arView: ARView?

    // Stāvoklis, kuru lieto tikai rindā `q`:
    private var modeQ: Mode = .base
    private var treeQ = TreeMeasure()
    private var last: DepthSnapshot? = nil
    private var groundY: Float? = nil
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
        cfg.planeDetection = [.horizontal]
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
        resetTree()
        q.async { self.groundY = nil }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // izpildās rindā q
        frameNo += 1
        guard let snap = DepthSnapshot(frame: frame) else {
            if frameNo % 30 == 0 {
                publishLive(LiveInfo(main: "Nav LiDAR datu", detail: "", good: false, warning: nil))
            }
            return
        }
        last = snap

        if frameNo % 15 == 0 {
            let camY = snap.camPos.y
            let ys = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
                .filter { $0.alignment == .horizontal }
                .map { $0.transform.columns.3.y }
                .filter { $0 < camY - 0.5 }
            groundY = ys.max()   // augstākā plakne zem telefona (nevis kāda bedre)
        }

        if capture != nil {
            stepCapture(snap)
        } else if frameNo % 6 == 0 {
            updateLive(snap)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.message = "AR kļūda: \(error.localizedDescription)" }
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

    private func referenceY() -> (Float, String)? {
        if let b = treeQ.baseY { return (b, "pamatnes") }
        if let g = groundY { return (g, "zemes plaknes") }
        return nil
    }

    private func updateLive(_ s: DepthSnapshot) {
        var info = LiveInfo()
        info.warning = trackingWarning(s.tracking)
        let aim = s.aimPoint()
        let dist = aim.map { simd_length($0 - s.camPos) }

        switch modeQ {
        case .base:
            if let dist {
                info.main = "Attālums \(fmt(dist, 2)) m"
                info.detail = "Notēmē stumbra apakšu pie zemes"
                info.good = dist < 4
            } else {
                info.main = "Par tālu LiDAR (> 5 m)"
                info.detail = "Pieej tuvāk kokam"
            }

        case .diameter:
            guard let aim, let dist else {
                info.main = "Par tālu LiDAR"
                info.detail = "Ieteicamais attālums 1–3 m"
                break
            }
            var parts: [String] = []
            if case let (ry, name)? = referenceY() {
                let hh = aim.y - ry
                parts.append("Tēmēklis \(fmt(hh, 2)) m virs \(name)")
                info.good = abs(hh - Self.breastHeight) <= 0.05
            } else {
                parts.append("Augstums nezināms — vispirms atzīmē pamatni")
            }
            if let sl = TrunkSlicer.slice(s, y0: aim.y, aim: aim), let d = sl.edgeDiameter {
                info.main = "≈ \(fmt(d * 100, 1)) cm"
            } else {
                info.main = "Stumbrs nav atrasts"
            }
            parts.append("attālums \(fmt(dist, 1)) m")
            info.detail = parts.joined(separator: " · ")

        case .height:
            guard let axis = treeQ.axisXZ ?? treeQ.baseXZ else {
                info.main = "Vispirms atzīmē pamatni"
                info.detail = "vai izmēri caurmēru"
                break
            }
            guard case let (ry, _)? = referenceY() else {
                info.main = "Nav zināms pamatnes augstums"
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
        case .base: markBase()
        case .diameter: startDiameter()
        case .height: markTop()
        }
    }

    private func markBase() {
        q.async {
            guard let s = self.last, let p = s.aimPoint() else {
                self.say("LiDAR neredz punktu — pieej tuvāk (līdz 4 m)")
                return
            }
            self.treeQ.baseY = p.y
            self.treeQ.baseXZ = SIMD2(p.x, p.z)
            let t = self.treeQ
            DispatchQueue.main.async {
                self.tree = t
                self.message = "Pamatne atzīmēta"
                self.placeMarkers()
                if t.dCm == nil { self.mode = .diameter }
                Haptics.ok()
            }
        }
    }

    private func startDiameter() {
        q.async {
            guard self.capture == nil else { return }
            guard let s = self.last, let aim = s.aimPoint() else {
                self.say("LiDAR neredz stumbru — pieej tuvāk (1–3 m)")
                return
            }
            self.capture = Capture(y0: aim.y, aim: aim)
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

        treeQ.dCm = D * 100
        treeQ.dMethod = method
        treeQ.dInfo = info
        if case let (ry, _)? = referenceY() { treeQ.dHeight = Double(c.y0 - ry) } else { treeQ.dHeight = nil }
        if let a = axis { treeQ.axisXZ = SIMD2(Float(a.x), Float(a.y)) }
        let t = treeQ
        let y0 = c.y0
        DispatchQueue.main.async {
            self.tree = t
            self.busy = false
            self.message = nil
            self.placeMarkers(sliceY: y0)
            Haptics.ok()
            self.mode = .height
        }
    }

    private func markTop() {
        q.async {
            guard let s = self.last else { return }
            guard let axis = self.treeQ.axisXZ ?? self.treeQ.baseXZ else {
                self.say("Vispirms atzīmē pamatni vai izmēri caurmēru")
                return
            }
            guard case let (ry, name)? = self.referenceY() else {
                self.say("Nav zināms pamatnes augstums — atzīmē pamatni")
                return
            }
            guard case let (H, L)? = self.heightOnAxis(s, axis: axis, baseY: ry), H > 0.5 else {
                self.say("Tēmē uz galotni virs koka")
                return
            }
            self.treeQ.hM = Double(H)
            self.treeQ.hBase = name == "pamatnes" ? "pamatne" : "zemes plakne"
            self.treeQ.hDist = Double(L)
            self.treeQ.hRefY = ry
            let t = self.treeQ
            DispatchQueue.main.async {
                self.tree = t
                self.message = "Augstums \(fmt(H, 1)) m"
                self.placeMarkers()
                Haptics.ok()
            }
        }
    }

    func resetTree() {
        q.async {
            self.treeQ = TreeMeasure()
            self.capture = nil
            DispatchQueue.main.async {
                self.tree = TreeMeasure()
                self.busy = false
                self.message = nil
                self.mode = .base
                self.clearMarkers()
            }
        }
    }

    private func say(_ s: String) {
        DispatchQueue.main.async { self.message = s; Haptics.fail() }
    }

    // MARK: - Marķieri AR skatā (vizuāla pārbaude, vai mērījums sakrīt ar koku)

    private var markerAnchor: AnchorEntity? = nil
    private var lastSliceY: Float? = nil

    private func clearMarkers() {
        if let a = markerAnchor { arView?.scene.removeAnchor(a) }
        markerAnchor = nil
        lastSliceY = nil
    }

    private func placeMarkers(sliceY: Float? = nil) {
        guard let view = arView else { return }
        if let y = sliceY { lastSliceY = y }
        if let a = markerAnchor { view.scene.removeAnchor(a) }
        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        let t = tree

        func mat(_ c: UIColor, _ o: Float) -> UnlitMaterial {
            var m = UnlitMaterial(color: c)
            m.blending = .transparent(opacity: .init(scale: o))
            return m
        }

        if let by = t.baseY, let bxz = t.baseXZ {
            let s = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [mat(.systemYellow, 0.9)])
            s.position = SIMD3(bxz.x, by, bxz.y)
            anchor.addChild(s)
        }
        if let d = t.dCm, let axis = t.axisXZ, let y = lastSliceY {
            let r = Float(d / 200)
            let disc = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: r), materials: [mat(.systemGreen, 0.55)])
            disc.position = SIMD3(axis.x, y, axis.y)
            anchor.addChild(disc)
        }
        if let h = t.hM, let axis = t.axisXZ ?? t.baseXZ, let by = t.hRefY {
            let top = Float(h) + by
            let s = ModelEntity(mesh: .generateSphere(radius: 0.15), materials: [mat(.systemRed, 0.8)])
            s.position = SIMD3(axis.x, top, axis.y)
            anchor.addChild(s)
            let pole = ModelEntity(mesh: .generateCylinder(height: Float(h), radius: 0.01), materials: [mat(.systemRed, 0.5)])
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
}

func fmt<T: BinaryFloatingPoint>(_ v: T, _ digits: Int) -> String {
    String(format: "%.\(digits)f", Double(v)).replacingOccurrences(of: ".", with: ",")
}
