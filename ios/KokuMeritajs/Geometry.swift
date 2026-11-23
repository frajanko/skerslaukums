import Foundation
import simd

/// Riņķis horizontālajā plaknē (pasaules X, Z koordinātas, metros).
struct FittedCircle {
    var center: SIMD2<Double>
    var radius: Double
    /// Vidējā kvadrātiskā novirze no riņķa līnijas, m.
    var rms: Double
    /// Cik grādus no apkārtmēra aptver punkti.
    var coverageDeg: Double
    var count: Int
}

enum Geo {
    /// Algebriskais (Kasa) riņķa fits. Ātrs, bet uz īsiem lokiem ar troksni samazina rādiusu —
    /// tāpēc izmantojam tikai kā sākuma minējumu ģeometriskajam fitam.
    static func kasa(_ pts: [SIMD2<Double>]) -> (SIMD2<Double>, Double)? {
        guard pts.count >= 3 else { return nil }
        let mean = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for p0 in pts {
            let p = p0 - mean
            let z = p.x * p.x + p.y * p.y
            sxx += p.x * p.x; sxy += p.x * p.y; syy += p.y * p.y
            sx += p.x; sy += p.y
            sxz += p.x * z; syz += p.y * z; sz += z
        }
        let n = Double(pts.count)
        let A = simd_double3x3(rows: [
            SIMD3(sxx, sxy, sx),
            SIMD3(sxy, syy, sy),
            SIMD3(sx, sy, n),
        ])
        guard abs(A.determinant) > 1e-18 else { return nil }
        let sol = A.inverse * SIMD3(-sxz, -syz, -sz)
        let c = SIMD2(-sol.x / 2, -sol.y / 2)
        let r2 = c.x * c.x + c.y * c.y - sol.z
        guard r2 > 0 else { return nil }
        return (c + mean, sqrt(r2))
    }

    /// Ģeometriskais fits (Gausa–Ņūtona metode): minimizē Σ(|p−c| − R)².
    static func geometric(_ pts: [SIMD2<Double>], center c0: SIMD2<Double>, radius r0: Double) -> (SIMD2<Double>, Double) {
        var c = c0, r = r0
        for _ in 0..<30 {
            var JtJ = simd_double3x3()
            var Jtr = SIMD3<Double>(0, 0, 0)
            for p in pts {
                let d = p - c
                let len = max(simd_length(d), 1e-9)
                let res = len - r
                let j = SIMD3(-d.x / len, -d.y / len, -1.0)
                JtJ += simd_double3x3(columns: (j * j.x, j * j.y, j * j.z))
                Jtr += j * res
            }
            guard abs(JtJ.determinant) > 1e-18 else { break }
            let delta = -(JtJ.inverse * Jtr)
            c += SIMD2(delta.x, delta.y)
            r += delta.z
            if simd_length(delta) < 1e-7 { break }
        }
        return (c, r)
    }

    /// Riņķa fits ar izlēcēju atmešanu.
    static func robustCircle(_ input: [SIMD2<Double>]) -> FittedCircle? {
        guard input.count >= 20, case let (c0, r0)? = kasa(input) else { return nil }
        var pts = input
        var c = c0, r = r0
        var rms = 0.0
        for _ in 0..<4 {
            (c, r) = geometric(pts, center: c, radius: r)
            guard r.isFinite, r > 0 else { return nil }
            let res = pts.map { simd_length($0 - c) - r }
            rms = sqrt(res.reduce(0) { $0 + $1 * $1 } / Double(res.count))
            let lim = max(2.5 * rms, 0.004)
            let kept = zip(pts, res).filter { abs($0.1) <= lim }.map { $0.0 }
            if kept.count == pts.count || kept.count < 20 { break }
            pts = kept
        }
        return FittedCircle(center: c, radius: r, rms: rms,
                            coverageDeg: coverageDeg(pts, center: c), count: pts.count)
    }

    /// Cik lielu loka daļu (grādos) aptver punkti ap centru.
    static func coverageDeg(_ pts: [SIMD2<Double>], center c: SIMD2<Double>) -> Double {
        guard pts.count >= 2 else { return 0 }
        let a = pts.map { atan2($0.y - c.y, $0.x - c.x) }.sorted()
        var maxGap = a.first! + 2 * .pi - a.last!
        for i in 1..<a.count { maxGap = max(maxGap, a[i] - a[i - 1]) }
        return (2 * .pi - maxGap) * 180 / .pi
    }

    /// Caurmērs pēc stumbra leņķiskā platuma α un attāluma līdz tuvākajai virsmai d:
    /// sin(α/2) = r / (d + r)  ⇒  r = d·s / (1 − s).
    static func diameterFromEdges(alpha: Double, nearest d: Double) -> Double? {
        let s = sin(alpha / 2)
        guard alpha > 0, s < 0.95 else { return nil }
        return 2 * d * s / (1 - s)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func medianF(_ v: [Float]) -> Float? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }
}
