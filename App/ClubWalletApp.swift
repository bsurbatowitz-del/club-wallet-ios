import SwiftUI
import PassKit
import ClubCore

@main
struct ClubWalletApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { store.handleIncoming($0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var transferPassword = ""
    @State private var tab = Demo.startTab

    var body: some View {
        TabView(selection: $tab) {
            MembersView().tabItem { Label("Members", systemImage: "person.3") }.tag(0)
            DesignView().tabItem { Label("Design", systemImage: "paintpalette") }.tag(1)
            WalletsView().tabItem { Label("Wallets", systemImage: "wallet.pass") }.tag(2)
            EmailView().tabItem { Label("Email", systemImage: "envelope") }.tag(3)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .alert(item: $store.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $store.showProgress) { ProgressSheet().environmentObject(store) }
        .alert("Transfer file password", isPresented: Binding(get: { store.pendingTransfer != nil },
                                                               set: { if !$0 { store.pendingTransfer = nil } })) {
            SecureField("Password", text: $transferPassword)
            Button("Import") {
                if let d = store.pendingTransfer { store.openTransfer(d, password: transferPassword) }
                transferPassword = ""
            }
            Button("Cancel", role: .cancel) { store.pendingTransfer = nil; transferPassword = "" }
        } message: {
            Text("Type the password you chose when exporting from the Ubuntu app.")
        }
    }
}

/// Progress + log while generating / emailing.
struct ProgressSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.progressTitle).font(.headline)
                ProgressView(value: store.progress)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.log.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(line.contains("✗") ? .red : line.contains("!") ? .orange : .primary)
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: store.log.count) { _, n in proxy.scrollTo(n - 1) }
                }
            }
            .padding()
            .navigationTitle(store.busy ? "Working…" : "Finished")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.busy {
                    ToolbarItem(placement: .cancellationAction) { Button("Stop") { store.stopRequested = true } }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .interactiveDismissDisabled(store.busy)
        }
    }
}

/// Presents the system "Add to Apple Wallet" screen.
struct AddPassView: UIViewControllerRepresentable {
    let pass: PKPass

    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

/// Share sheet for files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension Color {
    init(hex: String) {
        let c = RGB.parse(hex, default: RGB(r: 0, g: 0, b: 0))
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: Int(round(r * 255)), g: Int(round(g * 255)), b: Int(round(b * 255))).hex
    }
}

/// Binding to a "#RRGGBB" string as a SwiftUI Color.
func colorBinding(_ s: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(hex: s.wrappedValue) }, set: { s.wrappedValue = $0.hexString })
}
