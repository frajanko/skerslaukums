import SwiftUI

private let gaugeYellow = Color(red: 1, green: 0.94, blue: 0.35)

/// Apaļš tēmēklis galvenajā skatā (kameras attēla centrā).
struct Reticle: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = 34, gap: CGFloat = 5, arm: CGFloat = 46
            var p = Path()
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            p.move(to: CGPoint(x: c.x - arm, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
            p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - arm)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
            p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            ctx.stroke(p, with: .color(.black.opacity(0.55)), lineWidth: 3)
            ctx.stroke(p, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
        }
        .frame(width: 100, height: 100)
        .allowsHitTesting(false)
    }
}

struct WindowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

/// Prizmas logs virs pogām. Attēlu tajā zīmē `Prism` (renderētājs); šeit — rāmis, līnijas, uzraksti.
struct PrismWindow: View {
    @EnvironmentObject var b: BasalModel
    @ObservedObject var pose: Pose
    static let height: CGFloat = 150

    var body: some View {
        let slope = b.slopeCorr ? (pose.pitch ?? 0) : 0
        let s = Calc.critSin(baf: Double(b.baf), slopeDeg: slope)
        let M = Double(b.zoom)
        let w = Gauge.shared.focalPoints().map { Calc.gaugeWidth(F: $0, sinHalf: s) * M }
        let ang = 2 * asin(min(0.5, s)) * 180 / .pi

        Canvas { ctx, size in
            let W = size.width, H = size.height, cx = W / 2

            func line(_ a: CGPoint, _ c: CGPoint, _ width: CGFloat = 1.5, _ col: Color = gaugeYellow) {
                var p = Path(); p.move(to: a); p.addLine(to: c)
                ctx.stroke(p, with: .color(.black.opacity(0.75)), lineWidth: width + 2)
                ctx.stroke(p, with: .color(col), lineWidth: width)
            }

            if b.prism {
                line(CGPoint(x: 0, y: H / 2), CGPoint(x: W, y: H / 2), 1, gaugeYellow.opacity(0.9))
                var tri = Path()
                tri.move(to: CGPoint(x: cx - 6, y: 0)); tri.addLine(to: CGPoint(x: cx + 6, y: 0))
                tri.addLine(to: CGPoint(x: cx, y: 9)); tri.closeSubpath()
                ctx.fill(tri, with: .color(gaugeYellow))
            } else if let w {
                line(CGPoint(x: cx - w / 2, y: 0), CGPoint(x: cx - w / 2, y: H))
                line(CGPoint(x: cx + w / 2, y: 0), CGPoint(x: cx + w / 2, y: H))
            }
            ctx.stroke(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.preference(key: WindowFrameKey.self, value: g.frame(in: .global))
        })
        .overlay(alignment: .topLeading) {
            Text(w == nil ? "kamera vēl nav gatava" : "\(fmt(ang, 2))° · BAF \(b.baf)")
                .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule()).padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            Button(b.prism ? "Prizma" : "Līnijas") { b.prism.toggle() }
                .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule()).padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                b.zoom = BasalModel.zooms[(BasalModel.zooms.firstIndex(of: b.zoom).map { $0 + 1 } ?? 0) % BasalModel.zooms.count]
            } label: {
                Label("\(b.zoom)×", systemImage: "plus.magnifyingglass")
                    .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .padding(6)
        }
        .foregroundStyle(.white)
    }
}

/// Apgrieziena aplis: zaļš — virzieni, kas jau apskatīti; balta bulta — kur skatās telefons.
struct CoverageRing: View {
    let bins: Set<Int>
    let heading: Double?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 6
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 6, y: c.y - r - 6, width: 2 * r + 12, height: 2 * r + 12)),
                     with: .color(.black.opacity(0.45)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(0.18)), lineWidth: 5)
            for bin in bins {
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .degrees(Double(bin * 5) - 90),
                         endAngle: .degrees(Double(bin * 5 + 5) - 90 + 0.5), clockwise: false)
                ctx.stroke(p, with: .color(.green), lineWidth: 5)
            }
            if let h = heading {
                let a = (h - 90) * .pi / 180
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + cos(a) * (r - 5), y: c.y + sin(a) * (r - 5)))
                ctx.stroke(p, with: .color(.white), lineWidth: 2)
            }
        }
        .frame(width: 52, height: 52)
        .allowsHitTesting(false)
    }
}

struct BasalTopRow: View {
    @EnvironmentObject var b: BasalModel
    @ObservedObject var pose: Pose
    @State private var askBaf: Int? = nil
    @State private var showSettings = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button("BAF \(b.baf)") {
                let next = BasalModel.bafs[(BasalModel.bafs.firstIndex(of: b.baf).map { $0 + 1 } ?? 0) % BasalModel.bafs.count]
                if b.cur.n > 0 { askBaf = next } else { b.setBaf(next) }
            }
            .modifier(PillStyle())
            Text(pose.pitch.map { "∠ \(fmt($0, 0))°" + (b.slopeCorr ? "" : " (izsl.)") } ?? "∠ –")
                .modifier(PillStyle())
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .modifier(PillStyle())
                CoverageRing(bins: b.cur.cover, heading: pose.heading)
                Text("\(b.coverDeg)°").font(.caption2.bold()).shadow(color: .black, radius: 2)
            }
        }
        .foregroundStyle(.white)
        .alert("Mainīt uz BAF \(askBaf ?? 0)?", isPresented: Binding(get: { askBaf != nil }, set: { if !$0 { askBaf = nil } })) {
            Button("Nodzēst un mainīt", role: .destructive) { if let n = askBaf { b.setBaf(n) } }
            Button("Atcelt", role: .cancel) {}
        } message: {
            Text("Šajā laukumā jau saskaitīti \(fmtN(b.cur.n)) koki ar BAF \(b.baf). Ar citu BAF ir cits skaitīšanas leņķis, tāpēc koki jāpārskaita no jauna.")
        }
        .sheet(isPresented: $showSettings) { BasalSettingsView() }
    }
}

struct PillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.subheadline.bold().monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct BasalPanel: View {
    @EnvironmentObject var b: BasalModel
    @EnvironmentObject var loc: LocationProvider
    @AppStorage("stand") private var stand = ""
    @AppStorage("species") private var species = "P"
    @State private var editMeta = false
    @State private var metaStand = ""
    @State private var metaNo = ""
    @State private var saveWarning: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Button {
                metaStand = stand
                metaNo = String(b.cur.no)
                editMeta = true
            } label: {
                Text("Nogabals **\(stand.isEmpty ? "—" : stand)** · laukums **\(b.cur.no)** ✎")
                    .font(.subheadline)
            }

            SpeciesChips(species: $species, counts: b.cur.counts)

            HStack {
                Text("Koki **\(fmtN(b.cur.n))**")
                Spacer()
                Text("G **\(fmt(b.cur.n * Double(b.baf), 1))** m²/ha")
                Spacer()
                Text(Calc.composition(b.cur.counts.mapValues { $0 * Double(b.baf) })).bold()
            }
            .font(.subheadline.monospacedDigit())

            HStack(spacing: 8) {
                Button { b.undo() } label: {
                    VStack(spacing: 0) { Text("↶").font(.title2); Text("atcelt").font(.caption2) }
                        .frame(width: 60, height: 56)
                }
                .buttonStyle(.bordered)
                .disabled(b.cur.hist.isEmpty)

                Button { b.add(0.5, species: species) } label: {
                    VStack(spacing: 0) { Text("+½").font(.title2.bold()); Text("robežkoks").font(.caption2) }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent).tint(.yellow)

                Button { b.add(1, species: species) } label: {
                    VStack(spacing: 0) { Text("+1").font(.title2.bold()); Text("koks").font(.caption2) }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }

            Button { trySave() } label: {
                Text("Saglabāt laukumu").font(.headline).frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
        .alert("Laukuma dati", isPresented: $editMeta) {
            TextField("Nogabala numurs / nosaukums", text: $metaStand)
            TextField("Laukuma numurs", text: $metaNo).keyboardType(.numberPad)
            Button("Saglabāt") {
                stand = metaStand.trimmingCharacters(in: .whitespaces)
                if let n = Int(metaNo) { b.setNo(n) }
            }
            Button("Atcelt", role: .cancel) {}
        }
        .alert("Saglabāt laukumu?", isPresented: Binding(get: { saveWarning != nil }, set: { if !$0 { saveWarning = nil } })) {
            Button("Saglabāt") { save() }
            Button("Atcelt", role: .cancel) {}
        } message: {
            Text(saveWarning ?? "")
        }
    }

    private func trySave() {
        var w: [String] = []
        if b.cur.n == 0 { w.append("Nav saskaitīts neviens koks (G = 0).") }
        if b.coverDeg < 300 { w.append("Apgriezts tikai ~\(b.coverDeg)°.") }
        if w.isEmpty { save() } else { saveWarning = w.joined(separator: "\n") }
    }

    private func save() {
        b.savePlot(stand: stand, location: loc.recent)
    }
}

struct BasalSettingsView: View {
    @EnvironmentObject var b: BasalModel
    @Environment(\.dismiss) private var dismiss
    @State private var dText = ""
    @State private var lText = ""
    @State private var askBaf: Int? = nil

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("BAF", selection: Binding(get: { b.baf }, set: { n in
                        if b.cur.n > 0 { askBaf = n } else { b.setBaf(n) }
                    })) {
                        ForEach(BasalModel.bafs, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Pamatlaukuma faktors (BAF)")
                } footer: {
                    Text(BasalModel.bafs.map { "BAF \($0) → \(fmt(Calc.critAngleDeg(Double($0)), 3))°" }.joined(separator: " · ")
                         + ". Izvēlies tā, lai laukumā saskaitītu ~8–20 kokus. Mainot BAF, laukuma skaitījums sākas no jauna.")
                }

                Section("Skats") {
                    Picker("Skats", selection: $b.prism) {
                        Text("Prizma").tag(true)
                        Text("Mērlīnijas").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker("Palielinājums prizmas logā", selection: $b.zoom) {
                        ForEach(BasalModel.zooms, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Slīpuma korekcija (pēc telefona slīpuma)", isOn: $b.slopeCorr)
                }

                Section {
                    HStack {
                        Text("Caurmērs 1,3 m, cm")
                        TextField("piem. 32", text: $dText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Attālums līdz centram, m")
                        TextField("piem. 9,5", text: $lText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    borderline
                } header: {
                    Text("Robežkoka pārbaude")
                } footer: {
                    Text("Attālums horizontāli no laukuma centra līdz stumbra centram (līdz mizai + ½ caurmēra). Caurmēru var izmērīt režīmā „Koki”.")
                }

                Section {
                    Text("Kalibrēt nevajag: ARKit dod kameras precīzo fokusa attālumu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Iestatījumi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gatavs") { dismiss() } } }
            .alert("Mainīt uz BAF \(askBaf ?? 0)?", isPresented: Binding(get: { askBaf != nil }, set: { if !$0 { askBaf = nil } })) {
                Button("Nodzēst un mainīt", role: .destructive) { if let n = askBaf { b.setBaf(n) } }
                Button("Atcelt", role: .cancel) {}
            } message: {
                Text("Šajā laukumā jau saskaitīti \(fmtN(b.cur.n)) koki ar BAF \(b.baf). Ar citu BAF koki jāpārskaita no jauna.")
            }
        }
    }

    @ViewBuilder private var borderline: some View {
        if let d = num(dText), d > 0 {
            let R = Calc.maxDistance(dCm: d, baf: Double(b.baf))
            if let L = num(lText), L > 0 {
                let diff = R - L
                if abs(diff) < 0.005 * R {
                    Text("Robežkoks (R = \(fmt(R, 2)) m) → +½").bold().foregroundStyle(.yellow)
                } else if diff > 0 {
                    Text("Skaitās (R = \(fmt(R, 2)) m) → +1").bold().foregroundStyle(.green)
                } else {
                    Text("Neskaitās (R = \(fmt(R, 2)) m)").bold().foregroundStyle(.red)
                }
            } else {
                Text("Robežattālums: \(fmt(R, 2)) m (BAF \(b.baf))").bold()
            }
        } else {
            Text("Ievadi caurmēru, lai redzētu robežattālumu.").foregroundStyle(.secondary)
        }
    }
}
