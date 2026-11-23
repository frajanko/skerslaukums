import SwiftUI
import RealityKit
import ARKit

@main
struct KokuMeritajsApp: App {
    @StateObject private var store = TreeStore()
    @StateObject private var measurer = Measurer()

    var body: some Scene {
        WindowGroup {
            Group {
                if Measurer.lidarAvailable {
                    MeasureView()
                } else {
                    Text("Šim telefonam nav LiDAR skenera.\nVajadzīgs iPhone Pro modelis.")
                        .multilineTextAlignment(.center).padding()
                }
            }
            .environmentObject(store)
            .environmentObject(measurer)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - AR skats ar tēmēkli tieši ekrāna centrā

struct ARContainer: UIViewRepresentable {
    let measurer: Measurer

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let cross = CrosshairView()
        cross.translatesAutoresizingMaskIntoConstraints = false
        cross.isUserInteractionEnabled = false
        v.addSubview(cross)
        NSLayoutConstraint.activate([
            cross.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            cross.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            cross.widthAnchor.constraint(equalToConstant: 70),
            cross.heightAnchor.constraint(equalToConstant: 70),
        ])
        measurer.attach(v)
        return v
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

final class CrosshairView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for (color, width) in [(UIColor.black.withAlphaComponent(0.6), 3.0), (UIColor.white, 1.2)] {
            g.setStrokeColor(color.cgColor)
            g.setLineWidth(width)
            let r: CGFloat = 30, gap: CGFloat = 6
            g.move(to: CGPoint(x: c.x - r, y: c.y)); g.addLine(to: CGPoint(x: c.x - gap, y: c.y))
            g.move(to: CGPoint(x: c.x + gap, y: c.y)); g.addLine(to: CGPoint(x: c.x + r, y: c.y))
            g.move(to: CGPoint(x: c.x, y: c.y - r)); g.addLine(to: CGPoint(x: c.x, y: c.y - gap))
            g.move(to: CGPoint(x: c.x, y: c.y + gap)); g.addLine(to: CGPoint(x: c.x, y: c.y + r))
            g.strokePath()
            g.strokeEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        }
    }
}

// MARK: - Galvenais ekrāns

struct MeasureView: View {
    @EnvironmentObject var m: Measurer
    @EnvironmentObject var store: TreeStore
    @AppStorage("species") private var species = "P"
    @AppStorage("stand") private var stand = ""
    @State private var showList = false
    @State private var showHelp = false

    var body: some View {
        ZStack {
            ARContainer(measurer: m).ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                if let w = m.live.warning {
                    pill(w, .orange)
                }
                Spacer()
                panel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showList) { TreeListView(stand: $stand) }
        .sheet(isPresented: $showHelp) { HelpView() }
    }

    private var topBar: some View {
        HStack {
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle").font(.title2) }
            Spacer()
            Text(stand.isEmpty ? "Nogabals: —" : "Nogabals: \(stand)")
                .font(.subheadline).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button { showList = true } label: {
                Label("\(store.trees.count)", systemImage: "list.bullet")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    private func pill(_ s: String, _ c: Color) -> some View {
        Text(s).font(.subheadline.bold()).padding(.horizontal, 12).padding(.vertical, 6)
            .background(c.opacity(0.85), in: Capsule()).foregroundStyle(.black)
    }

    private var panel: some View {
        VStack(spacing: 10) {
            // Dzīvais rādījums
            VStack(spacing: 2) {
                if m.busy {
                    ProgressView(value: m.progress).tint(.green)
                    Text("Mēra… turi tēmēkli uz stumbra").font(.headline)
                } else {
                    Text(m.live.main.isEmpty ? " " : m.live.main)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(m.live.good ? Color.green : Color.white)
                    Text(m.live.detail).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let msg = m.message {
                    Text(msg).font(.footnote.bold()).foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity)

            // Pašreizējais koks
            HStack(spacing: 12) {
                valueBox("Pamatne", m.tree.baseY == nil ? "—" : "✓")
                valueBox("D, cm", m.tree.dCm.map { fmt($0, 1) } ?? "—")
                valueBox("H, m", m.tree.hM.map { fmt($0, 1) } ?? "—")
            }
            if let info = m.tree.dInfo {
                Text(info).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Species.all) { s in
                        Button(s.name) { species = s.id }
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(s.id == species ? Color.green : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(s.id == species ? Color.black : Color.white)
                    }
                }
            }

            Picker("Režīms", selection: $m.mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(m.busy)

            HStack(spacing: 10) {
                Button(role: .destructive) { m.resetTree() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 50)
                }
                .buttonStyle(.bordered)

                Button { m.act() } label: {
                    Text(m.mode.action).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(m.busy)

                Button {
                    store.add(m.tree, species: species, stand: stand)
                    m.resetTree()
                    Haptics.ok()
                } label: {
                    Image(systemName: "square.and.arrow.down").frame(width: 44, height: 50)
                }
                .buttonStyle(.bordered)
                .disabled(m.tree.dCm == nil && m.tree.hM == nil)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }

    private func valueBox(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Saraksts

struct TreeListView: View {
    @EnvironmentObject var store: TreeStore
    @EnvironmentObject var m: Measurer
    @Environment(\.dismiss) private var dismiss
    @Binding var stand: String
    @State private var confirmClear = false
    @State private var share: ShareItem? = nil

    private struct SpeciesSummary: Identifiable {
        let id: String
        let count: Int
        let meanD: Double?
        let meanH: Double?
    }

    private var summary: [SpeciesSummary] {
        Dictionary(grouping: store.trees, by: \.species)
            .map { (k, v) in
                let ds = v.compactMap(\.dCm), hs = v.compactMap(\.hM)
                return SpeciesSummary(id: k, count: v.count,
                                      meanD: ds.isEmpty ? nil : ds.reduce(0, +) / Double(ds.count),
                                      meanH: hs.isEmpty ? nil : hs.reduce(0, +) / Double(hs.count))
            }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nogabals") {
                    TextField("piem. 12-5", text: $stand)
                }
                if !store.trees.isEmpty {
                    Section("Kopsavilkums") {
                        ForEach(summary) { s in
                            HStack {
                                Text(Species.name(s.id)).frame(width: 110, alignment: .leading)
                                Text("\(s.count) gab.").frame(width: 60, alignment: .leading)
                                Spacer()
                                Text("D̄ \(s.meanD.map { fmt($0, 1) } ?? "—")  H̄ \(s.meanH.map { fmt($0, 1) } ?? "—")")
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                }
                Section("Koki (\(store.trees.count))") {
                    ForEach(store.trees.reversed()) { t in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(t.stand.isEmpty ? "" : t.stand + " · ")#\(t.no) \(Species.name(t.species))").font(.headline)
                                Text(t.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("D \(t.dCm.map { fmt($0, 1) } ?? "—") cm").monospacedDigit()
                                Text("H \(t.hM.map { fmt($0, 1) } ?? "—") m").monospacedDigit()
                            }
                        }
                        .swipeActions {
                            Button("Dzēst", role: .destructive) { store.delete([t.id]) }
                        }
                    }
                }
            }
            .navigationTitle("Koki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Gatavs") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { share = store.csvFile().map { ShareItem(url: $0) } } label: { Label("Eksportēt CSV", systemImage: "square.and.arrow.up") }
                            .disabled(store.trees.isEmpty)
                        Button(role: .destructive) { confirmClear = true } label: { Label("Dzēst visus", systemImage: "trash") }
                            .disabled(store.trees.isEmpty)
                        Divider()
                        Button { m.restart(); dismiss() } label: { Label("Atiestatīt AR izsekošanu", systemImage: "arrow.triangle.2.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Dzēst visus \(store.trees.count) kokus?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Dzēst visus", role: .destructive) { store.deleteAll() }
            }
            .sheet(item: $share) { s in ShareSheet(items: [s.url]) }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Palīdzība

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        Text("1. Pamatne").font(.headline)
                        Text("Pieej pie koka (līdz 4 m), notēmē stumbra apakšu tur, kur tas ieiet zemē, un spied „Atzīmēt pamatni”. Parādās dzeltena lodīte. No tās mēra krūšaugstumu un koka augstumu.")
                        Text("2. Caurmērs").font(.headline)
                        Text("Stāvi 1–3 m no koka. Pacel tēmēkli, līdz uzraksts „Tēmēklis 1,30 m virs pamatnes” kļūst zaļš, notēmē stumbra vidū un spied „Mērīt caurmēru”. Sekundi turi telefonu mierīgi. Zaļajam diskam jāsakrīt ar stumbru.")
                        Text("Metode „aplis” — LiDAR punktiem pielāgots riņķis; „malas” — pēc stumbra leņķiskā platuma. Lielākai precizitātei mērot nedaudz pakustini telefonu pa kreisi–pa labi.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Group {
                        Text("3. Augstums").font(.headline)
                        Text("Atkāpies tik tālu, lai redzi galotni (attālums ≈ koka augstums ir labākais). Telefons pats seko, cik tālu esi aizgājis. Notēmē galotni un spied „Atzīmēt galotni”. Augstums tiek rēķināts tur, kur tēmēšanas stars šķērso stumbra asi.")
                        Text("Saglabāšana").font(.headline)
                        Text("Izvēlies sugu un spied ⤓. Sarakstā (augšā pa labi) — kopsavilkums pa sugām un CSV eksports Excel.")
                        Text("Padomi").font(.headline)
                        Text("• LiDAR redz līdz ~5 m; caurmēram labākais 1–2 m.\n• Ja rādās „Inicializē”, lēnām pakustini telefonu.\n• Ja marķieri vairs nesakrīt ar koku, izvēlnē „Atiestatīt AR izsekošanu”.\n• Pirmajos mērījumos salīdzini ar dastu un mērlenti.")
                    }
                }
                .padding()
            }
            .navigationTitle("Kā mērīt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Aizvērt") { dismiss() } } }
        }
    }
}
