import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ClubCore

/// Which file a shared file importer is currently picking.
enum ImportTarget: Identifiable {
    case asset(Asset), photos, settings, transfer
    var id: String {
        switch self {
        case .asset(let a): return a.rawValue
        case .photos: return "photos"
        case .settings: return "settings"
        case .transfer: return "transfer"
        }
    }

    var types: [UTType] {
        switch self {
        case .asset(let a):
            switch a {
            case .logo, .background: return [.image]
            case .members: return spreadsheetTypes + [.data]
            case .googleServiceAccount: return [.json, .data]
            default: return [.data]
            }
        case .photos: return [.image]
        case .settings: return [.json, .data]
        case .transfer: return [.data]
        }
    }

    var multiple: Bool { if case .photos = self { return true } else { return false } }
}

struct FileImporter: ViewModifier {
    @EnvironmentObject var store: Store
    @Binding var target: ImportTarget?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                             allowedContentTypes: target?.types ?? [.data],
                             allowsMultipleSelection: target?.multiple ?? false) { result in
            guard let t = target, case .success(let urls) = result, !urls.isEmpty else { return }
            switch t {
            case .asset(let a): store.importAsset(a, from: urls[0])
            case .photos: store.importPhotos(urls)
            case .settings: store.importSettings(from: urls[0])
            case .transfer:
                do { store.openTransfer(try Store.read(urls[0])) } catch { store.show(error, title: "Import failed") }
            }
        }
    }
}

extension View {
    func fileImporter(target: Binding<ImportTarget?>) -> some View { modifier(FileImporter(target: target)) }
}

struct AssetRow: View {
    @EnvironmentObject var store: Store
    let asset: Asset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(asset.title).foregroundStyle(.primary)
                Spacer()
                if store.hasAsset(asset) {
                    Label("Imported", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                    Text("Replace").foregroundStyle(.tint)
                } else {
                    Text("Import…").foregroundStyle(.tint)
                }
            }
        }
        .id("\(asset.rawValue)-\(store.revision)")
    }
}

// MARK: - Design
struct DesignView: View {
    @EnvironmentObject var store: Store
    @State private var target: ImportTarget?
    @State private var logoItem: PhotosPickerItem?
    @State private var bgItem: PhotosPickerItem?
    @State private var preview: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Club name", text: $store.config.clubName)
                    TextField("Card title", text: $store.config.cardTitle)
                    TextField("Season (e.g. 2026)", text: $store.config.season)
                    TextField("Expiration date YYYY-MM-DD (optional)", text: $store.config.expirationDate)
                        .keyboardType(.numbersAndPunctuation)
                }
                Section {
                    Toggle("Take colours from background picture", isOn: $store.config.bgAutoColor)
                    ColorPicker("Background", selection: colorBinding($store.config.bgColor), supportsOpacity: false)
                    ColorPicker("Text", selection: colorBinding($store.config.fgColor), supportsOpacity: false)
                    ColorPicker("Labels", selection: colorBinding($store.config.labelColor), supportsOpacity: false)
                } header: { Text("Colours") } footer: {
                    if store.config.bgAutoColor && store.hasAsset(.background) {
                        Text("Colours come from the background picture; switch this off to use your own.")
                    }
                }
                Section {
                    pictureRow("Logo", .logo, $logoItem)
                    pictureRow("Background picture", .background, $bgItem)
                    VStack(alignment: .leading) {
                        Text("Colour over picture: \(store.config.bgOverlay)%")
                        Slider(value: Binding(get: { Double(store.config.bgOverlay) },
                                              set: { store.config.bgOverlay = Int($0) }), in: 0...90, step: 5)
                    }
                } header: { Text("Pictures") } footer: {
                    Text("The background shows on the card image, as a banner (Apple “Banner” layout) or blurred " +
                         "(“Full background”). Google Wallet needs a public link to it – see the Wallets tab.")
                }
                Section {
                    Toggle("Use member photos", isOn: $store.config.photosEnabled)
                    Button("Import photos from Files…") { target = .photos }
                    Text("\(store.members.filter { store.photoURL($0) != nil }.count) of \(store.members.count) members have a photo")
                        .foregroundStyle(.secondary)
                } header: { Text("Member photos") } footer: {
                    Text("Matched by file name: 1.jpg, 001.png, “Name Surname.jpg”, “Surname_Name.png”, email.jpg. " +
                         "You can also pick a photo from your library on each member's page.")
                }
                Section {
                    TextEditor(text: $store.config.qrTemplate).frame(minHeight: 90).font(.system(.body, design: .monospaced))
                } header: { Text("QR code content") } footer: {
                    Text("Placeholders: {reg} {name} {surname} {full_name} {email} {club} {season}")
                }
                Section("Preview") {
                    if let p = preview {
                        Image(uiImage: p).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button("Refresh preview") { render() }
                }
            }
            .navigationTitle("Card design")
            .fileImporter(target: $target)
            .task { render() }
            .onChange(of: store.revision) { render() }
            .onChange(of: logoItem) { _, i in load(i, into: .logo) { logoItem = nil } }
            .onChange(of: bgItem) { _, i in load(i, into: .background) { bgItem = nil } }
        }
    }

    @ViewBuilder
    func pictureRow(_ title: String, _ asset: Asset, _ item: Binding<PhotosPickerItem?>) -> some View {
        HStack {
            if let img = store.image(asset) {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 44, height: 32)
            }
            Text(title)
            Spacer()
            Menu(store.hasAsset(asset) ? "Change" : "Choose") {
                PhotosPicker(selection: item, matching: .images) { Label("Photo library", systemImage: "photo") }
                Button { target = .asset(asset) } label: { Label("Files", systemImage: "folder") }
                if store.hasAsset(asset) {
                    Button(role: .destructive) { store.removeAsset(asset) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .id("\(asset.rawValue)-\(store.revision)")
    }

    func load(_ item: PhotosPickerItem?, into asset: Asset, done: @escaping () -> Void) {
        guard let item else { return }
        Task {
            if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d),
               let png = img.pngData() {
                try? store.setAsset(asset, data: png, ext: "png")
            }
            done()
        }
    }

    func render() {
        let cfg = store.effectiveConfig()
        let m = store.members.first ?? Member(reg: "123", name: "Ana", surname: "Example", email: "ana@example.com")
        preview = CardRenderer.renderCard(member: m, config: cfg, qrText: cfg.qrText(for: m), photo: store.photo(m),
                                          logo: store.image(.logo), background: store.image(.background))
    }
}

// MARK: - Wallets
struct WalletsView: View {
    @EnvironmentObject var store: Store
    @State private var target: ImportTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Make Apple Wallet passes", isOn: $store.config.appleEnabled)
                    Picker("Layout", selection: $store.config.appleLayout) {
                        Text("Banner (picture + photo)").tag("storeCard")
                        Text("Full background (blurred)").tag("eventTicket")
                        Text("Classic (plain colour)").tag("generic")
                    }
                    TextField("Pass Type ID", text: $store.config.applePassTypeId).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Team ID", text: $store.config.appleTeamId).autocorrectionDisabled().textInputAutocapitalization(.characters)
                    Picker("Certificate", selection: $store.config.appleCertMode) {
                        Text(".cer + .pem key").tag("pem")
                        Text(".p12 file").tag("p12")
                    }
                    if store.config.appleCertMode == "p12" {
                        AssetRow(asset: .appleP12) { target = .asset(.appleP12) }
                        SecureField(".p12 password", text: $store.config.appleP12Password)
                    } else {
                        AssetRow(asset: .appleCert) { target = .asset(.appleCert) }
                        AssetRow(asset: .appleKey) { target = .asset(.appleKey) }
                    }
                    AssetRow(asset: .appleWWDR) { target = .asset(.appleWWDR) }
                    Button("Check certificate") { store.autofillApple() }
                } header: { Text("Apple Wallet") } footer: {
                    Text("Use the same files as in the Ubuntu app (pass.cer, pass_private_key.pem, AppleWWDRCAG4.cer). " +
                         "Easiest: Settings → Import from Ubuntu app.")
                }
                Section {
                    Toggle("Make Google Wallet passes", isOn: $store.config.googleEnabled)
                    TextField("Issuer ID", text: $store.config.googleIssuerId).keyboardType(.numberPad)
                    AssetRow(asset: .googleServiceAccount) { target = .asset(.googleServiceAccount) }
                    TextField("Pass class name", text: $store.config.googleClassSuffix).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Logo URL (public https, optional)", text: $store.config.googleLogoUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Banner image URL (public https, optional)", text: $store.config.googleHeroUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find my Issuer ID") { store.findIssuer() }
                    Button("Test connection") { store.testGoogle() }
                } header: { Text("Google Wallet") } footer: {
                    Text("Uses the service account key made by the Google setup script on Ubuntu.")
                }
            }
            .navigationTitle("Wallets")
            .fileImporter(target: $target)
        }
    }
}

// MARK: - Email
struct EmailView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("SMTP server", text: $store.config.smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $store.config.smtpPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    Picker("Security", selection: $store.config.smtpSecurity) {
                        Text("SSL/TLS").tag("SSL")
                        Text("None").tag("None")
                    }
                    TextField("Username", text: $store.config.smtpUser).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.emailAddress)
                    SecureField("Password (Gmail: App password)", text: $store.config.smtpPassword)
                    Button("Use Gmail settings") {
                        store.config.smtpHost = "smtp.gmail.com"; store.config.smtpPort = 465; store.config.smtpSecurity = "SSL"
                        if store.config.fromEmail.isEmpty { store.config.fromEmail = store.config.smtpUser }
                    }
                } header: { Text("Mail server") } footer: {
                    Text("Use SSL/TLS on port 465 (Gmail: smtp.gmail.com). STARTTLS on port 587 isn't supported.")
                }
                Section("Sender") {
                    TextField("From name", text: $store.config.fromName)
                    TextField("From email", text: $store.config.fromEmail).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.emailAddress)
                    TextField("Reply-to (optional)", text: $store.config.replyTo).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.emailAddress)
                }
                Section {
                    TextField("Subject", text: $store.config.emailSubject)
                    TextEditor(text: $store.config.emailBody).frame(minHeight: 220)
                } header: { Text("Message") } footer: {
                    Text("Placeholders: {name} {surname} {full_name} {reg} {email} {club} {season} {pass_filename}")
                }
                Section {
                    Toggle("Attach card image (PNG)", isOn: $store.config.attachPng)
                    Stepper("Pause between emails: \(store.config.sendDelaySeconds) s", value: $store.config.sendDelaySeconds, in: 0...30)
                    Button("Send test email to myself") { store.sendTestEmail(using: nil) }.disabled(store.busy)
                }
            }
            .navigationTitle("Email")
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var target: ImportTarget?
    @State private var shareURL: URL?
    @State private var askReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { target = .transfer } label: { Label("Import from Ubuntu app (.clubwallet)…", systemImage: "laptopcomputer.and.arrow.down") }
                } footer: {
                    Text("In the Ubuntu app: File → Export for iPhone app…, then get the file to this iPhone " +
                         "(email, Google Drive, iCloud) and pick it here – or open it from the Files app.")
                }
                Section("Settings file") {
                    Button { share(includeSecrets: false) } label: { Label("Export settings (without passwords)", systemImage: "square.and.arrow.up") }
                    Button { share(includeSecrets: true) } label: { Label("Export settings (with passwords)", systemImage: "square.and.arrow.up") }
                    Button { target = .settings } label: { Label("Import settings (.json)…", systemImage: "square.and.arrow.down") }
                }
                Section {
                    LabeledContent("Member list", value: store.membersFileName.isEmpty ? "–" : store.membersFileName)
                    LabeledContent("Emailed so far", value: "\(store.sent.count)")
                    Button("Forget who was emailed") { store.sent = [:]; store.saveSent() }
                } header: { Text("Data") } footer: {
                    Text("Generated cards are in the Files app → On My iPhone → Club Wallet → Cards.")
                }
                Section {
                    Button("Reset everything…", role: .destructive) { askReset = true }
                }
                Section {
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") +
                                   " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(target: $target)
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .confirmationDialog("Reset everything?", isPresented: $askReset, titleVisibility: .visible) {
                Button("Delete all settings, keys, photos and the member list", role: .destructive) { store.resetAll() }
            }
        }
    }

    func share(includeSecrets: Bool) { shareURL = store.exportSettingsFile(includeSecrets: includeSecrets) }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
