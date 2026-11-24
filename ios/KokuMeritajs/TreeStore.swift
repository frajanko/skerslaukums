import Foundation
import SwiftUI

struct Species: Identifiable, Hashable {
    let id: String
    let name: String
    // Tāds pats saraksts kā Šķērslaukuma PWA (calc.js)
    static let all: [Species] = [
        .init(id: "P", name: "Priede"), .init(id: "E", name: "Egle"), .init(id: "B", name: "Bērzs"),
        .init(id: "A", name: "Apse"), .init(id: "M", name: "Melnalksnis"), .init(id: "Ba", name: "Baltalksnis"),
        .init(id: "O", name: "Ozols"), .init(id: "Os", name: "Osis"), .init(id: "L", name: "Liepa"),
        .init(id: "Kļ", name: "Kļava"), .init(id: "C", name: "Cits"),
    ]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

struct TreeRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var stand: String
    var no: Int
    var species: String
    var date: Date
    var dCm: Double?
    var dMethod: String?
    var hM: Double?
    var hDist: Double?
}

final class TreeStore: ObservableObject {
    @Published private(set) var trees: [TreeRecord] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("koki.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let t = try? JSONDecoder().decode([TreeRecord].self, from: data) {
            trees = t
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trees) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func nextNo(stand: String) -> Int {
        (trees.filter { $0.stand == stand }.map(\.no).max() ?? 0) + 1
    }

    @discardableResult
    func add(_ m: TreeMeasure, species: String, stand: String) -> TreeRecord {
        let r = TreeRecord(stand: stand, no: nextNo(stand: stand), species: species, date: Date(),
                           dCm: m.dCm, dMethod: m.dMethod, hM: m.hM, hDist: m.hDist)
        trees.append(r)
        save()
        return r
    }

    func delete(_ ids: Set<UUID>) {
        trees.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        trees = []
        save()
    }

    // MARK: - CSV (Excel: `;` atdalītājs, decimālkomats, UTF-8 ar BOM — kā PWA)

    func csv() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "lv_LV"); df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "lv_LV"); tf.dateFormat = "HH:mm:ss"
        func num(_ x: Double?, _ d: Int) -> String { x.map { fmt($0, d) } ?? "" }
        let head = ["nogabals", "nr", "datums", "laiks", "suga", "D_cm", "H_m", "D_metode", "H_attālums_m"]
        let rows = trees.map { t in
            [t.stand, String(t.no), df.string(from: t.date), tf.string(from: t.date), t.species,
             num(t.dCm, 1), num(t.hM, 1), t.dMethod ?? "", num(t.hDist, 1)]
                .map(csvCell).joined(separator: ";")
        }
        return "\u{FEFF}" + ([head.joined(separator: ";")] + rows).joined(separator: "\r\n")
    }
}

func csvCell(_ s: String) -> String {
    s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" })
        ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
}

/// Ieraksta CSV pagaidu failā kopīgošanai, piem. „koki_2026-11-23.csv”.
func writeTemp(_ prefix: String, _ text: String) -> URL? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)_\(f.string(from: Date())).csv")
    do { try text.write(to: u, atomically: true, encoding: .utf8); return u } catch { return nil }
}
