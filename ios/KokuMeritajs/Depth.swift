import ARKit
import simd

/// Viena kadra LiDAR dziļuma kopija (ARFrame paturēt nedrīkst — tas aizņem ARKit kadru buferi).
struct DepthSnapshot {
    let w: Int
    let h: Int
    let depth: [Float]      // metri, gar kameras asi
    let conf: [UInt8]       // ARConfidenceLevel: 0 zema, 1 vidēja, 2 augsta
    let fx: Float, fy: Float, cx: Float, cy: Float   // pārrēķināti dziļuma kartes izšķirtspējai
    let T: simd_float4x4    // kamera → pasaule
    let tracking: ARCamera.TrackingState

    init?(frame: ARFrame) {
        guard let sd = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let dm = sd.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        let rb = CVPixelBufferGetBytesPerRow(dm)
        guard let base = CVPixelBufferGetBaseAddress(dm) else { return nil }
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { depth[y * w + x] = row[x] }
        }
        var conf = [UInt8](repeating: 2, count: w * h)
        if let cm = sd.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
            if let cb = CVPixelBufferGetBaseAddress(cm),
               CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h {
                let crb = CVPixelBufferGetBytesPerRow(cm)
                for y in 0..<h {
                    let row = cb.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { conf[y * w + x] = row[x] }
                }
            }
        }
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        self.w = w; self.h = h
        self.depth = depth; self.conf = conf
        fx = K.columns.0.x * sx; fy = K.columns.1.y * sy
        cx = K.columns.2.x * sx; cy = K.columns.2.y * sy
        T = frame.camera.transform
        tracking = frame.camera.trackingState
    }

    var camPos: SIMD3<Float> { SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z) }

    /// Pasaules punkts dziļuma kartes koordinātās (u, v) ar dziļumu d.
    /// ARKit kameras telpā: x pa labi, y uz augšu, skats uz −z.
    @inline(__always)
    func world(_ u: Float, _ v: Float, _ d: Float) -> SIMD3<Float> {
        let p = T * SIMD4((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// Stars caur attēla (= ekrāna) centru, pasaules koordinātās, normēts.
    var aimDir: SIMD3<Float> {
        let u = Float(w) / 2, v = Float(h) / 2
        let d = T * SIMD4((u - cx) / fx, -(v - cy) / fy, -1, 0)
        return simd_normalize(SIMD3(d.x, d.y, d.z))
    }

    /// Dziļums tēmēkļa centrā (mediāna 7×7 laukumā).
    func centerDepth() -> Float? {
        let x0 = w / 2, y0 = h / 2
        var v: [Float] = []
        for y in (y0 - 3)...(y0 + 3) {
            for x in (x0 - 3)...(x0 + 3) {
                let i = y * w + x
                if conf[i] >= 1, depth[i] > 0.1 { v.append(depth[i]) }
            }
        }
        return v.count >= 10 ? Geo.medianF(v) : nil
    }

    /// Punkts, uz kuru rāda tēmēklis (ja LiDAR to sasniedz).
    func aimPoint() -> SIMD3<Float>? {
        guard let d = centerDepth() else { return nil }
        return world(Float(w) / 2, Float(h) / 2, d)
    }
}

/// Stumbra šķēlums vienā kadrā: punkti horizontālā joslā ap augstumu y0.
struct TrunkSlice {
    var points: [SIMD2<Double>]       // stumbra virsmas punkti (pasaules X, Z)
    var edgeDiameter: Double?         // m, pēc malu leņķa
    var edgeCenter: SIMD2<Double>?    // stumbra ass pēc malu metodes
    var nearest: Double               // m, horizontāli līdz tuvākajai virsmai
}

enum TrunkSlicer {
    static let halfBand: Float = 0.04         // ±4 cm augstumā
    static let maxAz: Float = 0.6             // ±34° no tēmēšanas virziena
    static let binW: Float = 0.25 * .pi / 180
    /// Resnākais stumbrs, ko meklē (rādiuss, m). Plašākas virsmas (krūmi, zeme, vairāki koki kopā) atmet.
    static let maxRadius: Float = 0.6

    /// Atrod stumbru, uz kuru rāda `aim`, horizontālā joslā augstumā `y0`.
    static func slice(_ s: DepthSnapshot, y0: Float, aim: SIMD3<Float>) -> TrunkSlice? {
        let C = s.camPos
        let c2 = SIMD2(C.x, C.z)
        let a2 = SIMD2(aim.x, aim.z) - c2
        guard simd_length(a2) > 0.1 else { return nil }
        let ref = atan2(a2.y, a2.x)

        var az: [Float] = [], rg: [Float] = [], xz: [SIMD2<Float>] = []
        az.reserveCapacity(4000); rg.reserveCapacity(4000); xz.reserveCapacity(4000)
        for y in 0..<s.h {
            let fy = Float(y) + 0.5
            for x in 0..<s.w {
                let i = y * s.w + x
                guard s.conf[i] >= 1 else { continue }
                let d = s.depth[i]
                guard d > 0.15, d < 5.5 else { continue }
                let p = s.world(Float(x) + 0.5, fy, d)
                guard abs(p.y - y0) <= halfBand else { continue }
                let v = SIMD2(p.x, p.z) - c2
                var a = atan2(v.y, v.x) - ref
                if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
                guard abs(a) <= maxAz else { continue }
                az.append(a); rg.append(simd_length(v)); xz.append(SIMD2(p.x, p.z))
            }
        }
        guard az.count >= 10 else { return nil }

        let nb = Int(2 * maxAz / binW) + 1
        var bins = [[Float]](repeating: [], count: nb)
        var binOf = [Int](repeating: 0, count: az.count)
        for k in 0..<az.count {
            let b = min(nb - 1, max(0, Int((az[k] + maxAz) / binW)))
            binOf[k] = b
            bins[b].append(rg[k])
        }
        let med: [Float?] = bins.map { Geo.medianF($0) }

        // Centra josla (vai tuvākā netukšā)
        let c0 = Int(maxAz / binW)
        var center: Int? = nil
        for off in 0...4 {
            if c0 - off >= 0, med[c0 - off] != nil { center = c0 - off; break }
            if c0 + off < nb, med[c0 + off] != nil { center = c0 + off; break }
        }
        guard let c = center else { return nil }

        // Tikai stumbrs, uz kuru tēmē: leņķiskais platums nedrīkst pārsniegt maxRadius stumbra platumu.
        let r0 = med[c]!
        let halfMax = asin(min(0.95, maxRadius / (r0 + maxRadius)))
        let maxBins = Int(2 * halfMax / binW) + 1

        /// Paplašina stumbru no centra joslas, kamēr attālums mainās vienmērīgi. `wide` — virsma turpinās
        /// tālāk par resnākā stumbra platumu (siena, krūms, vairāki koki) — tas nav viens stumbrs.
        func grow(_ step: Int) -> (last: Int, wide: Bool) {
            var last = c, cur = med[c]!, gap = 0, i = c + step
            while i >= 0, i < nb {
                if abs(i - c) > maxBins { return (last, true) }
                if let m = med[i] {
                    if abs(m - cur) <= max(0.05, 0.05 * cur) { last = i; cur = m; gap = 0 } else { break }
                } else {
                    gap += 1
                    if gap > 2 { break }
                }
                i += step
            }
            return (last, i < 0 || i >= nb)
        }
        let gl = grow(-1), gh = grow(1)
        let lo = gl.last, hi = gh.last
        guard hi - lo >= 2, !gl.wide, !gh.wide, hi - lo <= maxBins else { return nil }

        var pts: [SIMD2<Double>] = []
        var azMin = Float.greatestFiniteMagnitude, azMax = -Float.greatestFiniteMagnitude
        for k in 0..<az.count {
            let b = binOf[k]
            guard b >= lo, b <= hi, let m = med[b], abs(rg[k] - m) <= 0.05 else { continue }
            pts.append(SIMD2(Double(xz[k].x), Double(xz[k].y)))
            azMin = min(azMin, az[k]); azMax = max(azMax, az[k])
        }
        guard pts.count >= 5 else { return nil }
        let nearest = Double((lo...hi).compactMap { med[$0] }.min() ?? 0)
        let alpha = Double(azMax - azMin)
        let D = Geo.diameterFromEdges(alpha: alpha, nearest: nearest)
        var ec: SIMD2<Double>? = nil
        if let D {
            let mid = Double(ref + (azMin + azMax) / 2)
            let L = nearest + D / 2
            ec = SIMD2(Double(c2.x), Double(c2.y)) + L * SIMD2(cos(mid), sin(mid))
        }
        return TrunkSlice(points: pts, edgeDiameter: D, edgeCenter: ec, nearest: nearest)
    }
}

// MARK: - Stumbra malu precizēšana kameras attēlā

/// LiDAR dziļuma karte ir tikai 256×192 (~0,25° uz pikseli), un malās tās pikseļi sajaucas ar fonu
/// (zema ticamība) — tāpēc LiDAR malas parasti ir stumbra iekšpusē un caurmērs sanāk par mazu.
/// Kameras attēls ir 1920×1440 (~7× smalkāk): LiDAR malas projicē attēlā un tuvumā meklē
/// spēcīgāko gaišuma pāreju (stumbrs ↔ fons). Attālumu joprojām ņem no LiDAR.
struct ImageEdgeFit {
    var diameter: Double            // m
    var center: SIMD2<Double>       // stumbra ass (pasaules X, Z)
}

enum ImageEdges {
    static func refine(frame: ARFrame, slice: TrunkSlice, y0: Float) -> ImageEdgeFit? {
        guard let D0 = slice.edgeDiameter, let ec = slice.edgeCenter else { return nil }
        let T = frame.camera.transform
        let cam2 = SIMD2(Double(T.columns.3.x), Double(T.columns.3.z))
        guard let tp = Geo.tangentPoints(center: ec, radius: D0 / 2, from: cam2) else { return nil }

        let K = frame.camera.intrinsics
        let fx = K.columns.0.x, fy = K.columns.1.y, cx = K.columns.2.x, cy = K.columns.2.y
        let inv = T.inverse
        func project(_ p: SIMD2<Double>) -> SIMD2<Float>? {
            let q = inv * SIMD4(Float(p.x), y0, Float(p.y), 1)
            let d = -q.z
            guard d > 0.1 else { return nil }
            return SIMD2(cx + fx * q.x / d, cy - fy * q.y / d)
        }
        guard let pA = project(tp.0), let pB = project(tp.1) else { return nil }
        let seg = pB - pA
        let len = simd_length(seg)
        guard len > 15 else { return nil }
        let u = seg / len
        let n = SIMD2(-u.y, u.x)

        let pb = frame.capturedImage
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let W = CVPixelBufferGetWidthOfPlane(pb, 0), H = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let Y = base.assumingMemoryBound(to: UInt8.self)

        // Gaišuma profils gar šķērsgriezuma līniju, vidējots ±30 px gar stumbru (mizas troksnis mazinās).
        let s0 = -0.3 * len, s1 = 1.3 * len
        let count = Int(s1 - s0)
        guard count > 20 else { return nil }
        var prof = [Float](repeating: .nan, count: count)
        for i in 0..<count {
            let b = pA + u * (s0 + Float(i))
            var sum: Float = 0, cnt: Float = 0
            for k in stride(from: -30, through: 30, by: 5) {
                let p = b + n * Float(k)
                let xi = Int(p.x.rounded()), yi = Int(p.y.rounded())
                guard xi >= 0, yi >= 0, xi < W, yi < H else { continue }
                sum += Float(Y[yi * rb + xi]); cnt += 1
            }
            if cnt >= 4 { prof[i] = sum / cnt }
        }
        // Izlīdzina (5 px) un rēķina gradientu.
        var sm = prof
        for i in 2..<(count - 2) {
            let w = prof[(i - 2)...(i + 2)]
            sm[i] = w.contains { $0.isNaN } ? .nan : w.reduce(0, +) / 5
        }
        func grad(_ i: Int) -> Float {
            guard i >= 3, i < count - 3 else { return 0 }
            let g = sm[i + 3] - sm[i - 3]
            return g.isNaN ? 0 : abs(g)
        }
        /// Malas meklēšana: LiDAR mala parasti ir stumbra iekšpusē, tāpēc ārpusē meklē tālāk (15 %),
        /// iekšpusē maz (5 %) — lai mizas rievas netiek uzskatītas par malu.
        func edge(at e: Int, outward: Int) -> Int? {
            let out = Int(0.15 * len), inn = Int(0.05 * len)
            let a = outward < 0 ? e - out : e - inn
            let b = outward < 0 ? e + inn : e + out
            let lo = max(3, a), hi = min(count - 4, b)
            guard lo < hi else { return nil }
            var best = -1, bg: Float = 0
            for i in lo...hi where grad(i) > bg { bg = grad(i); best = i }
            return best >= 0 && bg >= 12 ? best : nil
        }
        let iA = Int(-s0), iB = Int(-s0 + len)
        guard let eA = edge(at: iA, outward: -1), let eB = edge(at: iB, outward: 1) else { return nil }
        let qA = pA + u * (s0 + Float(eA)), qB = pA + u * (s0 + Float(eB))

        // Pikselis → horizontāls virziens pasaulē.
        func azimuth(_ p: SIMD2<Float>) -> Double {
            let d = T * SIMD4((p.x - cx) / fx, -(p.y - cy) / fy, -1, 0)
            return atan2(Double(d.z), Double(d.x))
        }
        let a1 = azimuth(qA), a2 = azimuth(qB)
        var alpha = a2 - a1
        while alpha > .pi { alpha -= 2 * .pi }
        while alpha < -.pi { alpha += 2 * .pi }
        let mid = a1 + alpha / 2
        alpha = abs(alpha)
        guard let D = Geo.diameterFromEdges(alpha: alpha, nearest: slice.nearest) else { return nil }
        // Nedrīkst būtiski atšķirties no LiDAR malām (citādi atrasta cita mala / fons).
        guard D > 0.85 * D0, D < 1.3 * D0 else { return nil }
        let L = slice.nearest + D / 2
        return ImageEdgeFit(diameter: D, center: cam2 + L * SIMD2(cos(mid), sin(mid)))
    }
}
