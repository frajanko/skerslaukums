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
