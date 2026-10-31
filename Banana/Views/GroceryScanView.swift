#if os(iOS)
import PhotosUI
import SwiftUI

/// Scanning in what you bought, straight after shopping: the camera stays open and each package
/// joins your foods as its barcode is read, bought today (`MyFoodsStore.bought`). Something you
/// buy again only gets today's date. One no database knows waits in the list for a photo of its
/// label. Photos of packages, picked from Photos, are read the same way (`PackagePhoto`); one with
/// no barcode in it goes to its label. What's bought lately is then offered when you log a meal,
/// before you've ever had it (`MyFoods.justBought`).
struct GroceryScanView: View {
    @ObservedObject private var store = MyFoodsStore.shared
    @Environment(\.dismiss) private var dismiss

    private struct Scanned: Identifiable, Equatable {
        enum State: Equatable { case looking, new, again, needsLabel, noBarcode }
        var id: String
        /// Nil for a photo with no barcode in it.
        var barcode: String?
        var name: String
        var state: State
        /// The photo it was read from, for its label.
        var photo: Data?
    }

    /// Newest first.
    @State private var scanned: [Scanned] = []
    @State private var problem: String?
    @State private var labelFor: Scanned?
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                camera
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipped()
                List {
                    Section {
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("groceries.photos")
                    } footer: {
                        if scanned.isEmpty {
                            Text("Scan each package\u{2019}s barcode, or choose photos of them. What you bought shows up first when you log a meal.")
                        }
                    }
                    ForEach(scanned) { row($0) }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Groceries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $labelFor) { item in
                ScanCorrectionSheet(items: [], photos: [], startingBarcode: item.barcode, startingPhoto: item.photo) { result in
                    let food = store.bought(result.food)
                    update(item.id) { $0.name = food.name; $0.state = .new }
                }
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { await photo(data) }
                    }
                }
            }
            #if DEBUG
            // `--grocery-codes a,b,c`: those barcodes, read one after another as the camera would.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "--grocery-codes"), i + 1 < args.count else { return }
                for code in args[i + 1].split(separator: ",") {
                    try? await Task.sleep(for: .milliseconds(400))
                    await read(String(code))
                }
            }
            // `--grocery-photo-codes a,-`: photos picked from Photos, one with barcode a on it, one
            // with none (`-`).
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "--grocery-photo-codes"), i + 1 < args.count else { return }
                for code in args[i + 1].split(separator: ",") {
                    if let data = PackagePhoto.barcodePicture(code == "-" ? nil : String(code)) { await photo(data) }
                }
            }
            #endif
        }
    }

    @ViewBuilder private var camera: some View {
        if BarcodeScannerView.isSupported, problem == nil {
            BarcodeScannerView(onScan: { code in Task { await read(code) } },
                               onError: { problem = $0 },
                               continuous: true)
        } else {
            ContentUnavailableView {
                Label("No camera scanner", systemImage: "barcode.viewfinder")
            } description: {
                Text(problem ?? "This device can\u{2019}t scan barcodes.")
            }
            .background(Color(.secondarySystemBackground))
        }
    }

    private func row(_ item: Scanned) -> some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(item.name)
                switch item.state {
                case .looking: Text("Looking it up\u{2026}").font(.footnote).foregroundStyle(.secondary)
                case .new: Text("Added").font(.footnote).foregroundStyle(.secondary)
                case .again: Text("Bought again").font(.footnote).foregroundStyle(.secondary)
                case .needsLabel: Text("No nutrition on file").font(.footnote).foregroundStyle(.secondary)
                case .noBarcode: Text("No barcode in it").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.s)
            switch item.state {
            case .looking: ProgressView()
            case .new, .again: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsLabel:
                Button(item.photo == nil ? "Photograph label" : "Read label") { labelFor = item }
                    .buttonStyle(.secondarySmall)
            case .noBarcode:
                Button("Read label") { labelFor = item }
                    .buttonStyle(.secondarySmall)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("groceries.row")
    }

    /// A photo from Photos: each barcode in it, as if scanned; none, and it waits for its label
    /// to be read.
    private func photo(_ data: Data) async {
        guard let image = PackagePhoto.image(data) else { return }
        let codes = await PackagePhoto.barcodes(in: image)
        guard !codes.isEmpty else {
            scanned.insert(Scanned(id: UUID().uuidString, name: "Photo", state: .noBarcode, photo: data), at: 0)
            return
        }
        for code in codes { await read(code, photo: data) }
    }

    /// One barcode: yours already (bought again), found in a database (added), or waiting for
    /// its label. Once per visit, however often the camera sees it.
    private func read(_ raw: String, photo: Data? = nil) async {
        guard let barcode = try? BarcodeProductLookup.normalizedBarcode(raw),
              !scanned.contains(where: { $0.barcode == barcode }) else { return }
        if let mine = store.food(barcode: barcode) {
            let food = store.bought(mine)
            scanned.insert(Scanned(id: barcode, barcode: barcode, name: food.name, state: .again), at: 0)
            Telemetry.shared.record(.feature(.groceriesScanned))
            return
        }
        scanned.insert(Scanned(id: barcode, barcode: barcode, name: barcode, state: .looking, photo: photo), at: 0)
        switch try? await BarcodeProductLookup.lookup(barcode) {
        case .foundLocally(let product), .foundOnline(let product):
            if let food = MyFoods.food(product: product) {
                let kept = store.bought(food)
                update(barcode) { $0.name = kept.name; $0.state = .new }
                Telemetry.shared.record(.feature(.groceriesScanned))
            } else {
                update(barcode) { $0.name = product.name; $0.state = .needsLabel }
            }
        default:
            update(barcode) { $0.state = .needsLabel }
        }
    }

    private func update(_ id: String, _ change: (inout Scanned) -> Void) {
        guard let i = scanned.firstIndex(where: { $0.id == id }) else { return }
        change(&scanned[i])
    }
}
#endif
