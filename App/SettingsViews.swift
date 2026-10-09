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
    /// iOS closes the picker (clearing `target`) *before* it delivers the file, so remember what was asked for.
    @State private var pending: ImportTarget?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                             allowedContentTypes: (target ?? pending)?.types ?? [.data],
                             allowsMultipleSelection: (target ?? pending)?.multiple ?? false) { result in
            let t = pending
            pending = nil
            if case .failure(let e) = result { store.show(e, title: "Import failed"); return }
            guard let t, case .success(let urls) = result, !urls.isEmpty else { return }
            switch t {
            case .asset(let a): store.importAsset(a, from: urls[0])
            case .photos: store.importPhotos(urls)
            case .settings: store.importSettings(from: urls[0])
            case .transfer:
                do { store.openTransfer(try Store.read(urls[0])) } catch { store.show(error, title: "Import failed") }
            }
        }
        .onChange(of: target?.id) { _, _ in if let t = target { pending = t } }
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

/// A text field with its name on the left (so filled-in fields still say what they are).
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var keyboard: UIKeyboardType = .default
    var plain = false          // no autocapitalisation / autocorrect (ids, emails, URLs)
    var secure = false

    var body: some View {
        LabeledContent(label) {
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(plain ? .never : .sentences)
                        .autocorrectionDisabled(plain)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Design
struct DesignView: View {
    @EnvironmentObject var store: Store
    @State private var target: ImportTarget?
    @State private var libraryItem: PhotosPickerItem?
    @State private var libraryAsset: Asset?
    @State private var showLibrary = false
    @State private var preview: UIImage?
    @State private var walletPreview: UIImage?
    @State private var loadingPicture = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    LabeledField(label: "Club", text: $store.config.clubName, prompt: "Club name")
                    LabeledField(label: "Card title", text: $store.config.cardTitle, prompt: "Membership Card")
                    LabeledField(label: "Season", text: $store.config.season, prompt: "2026")
                    LabeledField(label: "Expires", text: $store.config.expirationDate, prompt: "YYYY-MM-DD (optional)",
                                 keyboard: .numbersAndPunctuation, plain: true)
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
                    pictureRow("Logo", .logo)
                    pictureRow("Background picture", .background)
                    if loadingPicture { HStack { ProgressView(); Text("Loading picture…") } }
                    VStack(alignment: .leading) {
                        Text("Colour tint over picture: \(store.config.bgOverlay)%  (0 = picture as it is)")
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
                Section {
                    if let p = preview {
                        Image(uiImage: p).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let w = walletPreview {
                        Text(store.config.appleLayout == "eventTicket" ? "Apple Wallet background (iOS blurs it)" : "Apple Wallet banner")
                            .font(.footnote).foregroundStyle(.secondary)
                        Image(uiImage: w).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: store.config.appleLayout == "eventTicket" ? 220 : 140)
                    } else if store.hasAsset(.background) && store.config.appleLayout == "generic" {
                        Text("The Apple Wallet layout is Classic (plain colour) – choose Banner on the Wallets tab to show the picture in Wallet.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Refresh preview") { render() }
                } header: { Text("Preview") }
            }
            .navigationTitle("Card design")
            .fileImporter(target: $target)
            .task { render() }
            .onChange(of: store.revision) { render() }
            .onChange(of: store.config.bgOverlay) { render() }
            .onChange(of: store.config.bgAutoColor) { render() }
            .onChange(of: store.config.appleLayout) { render() }
            .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
            .onChange(of: libraryItem) { _, item in
                guard let item, let asset = libraryAsset else { return }
                loadingPicture = true
                Task {
                    do {
                        if let d = try await item.loadTransferable(type: Data.self) {
                            try store.setPicture(asset, data: d)
                        } else {
                            store.show("Picture", "That photo could not be loaded.")
                        }
                    } catch { store.show(error, title: "Picture") }
                    loadingPicture = false
                    libraryItem = nil
                }
            }
        }
    }

    @ViewBuilder
    func pictureRow(_ title: String, _ asset: Asset) -> some View {
        HStack {
            if let img = store.image(asset) {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 44, height: 32)
            }
            Text(title)
            Spacer()
            Menu(store.hasAsset(asset) ? "Change" : "Choose") {
                Button { libraryAsset = asset; showLibrary = true } label: { Label("Photo library", systemImage: "photo") }
                Button { target = .asset(asset) } label: { Label("Files", systemImage: "folder") }
                if store.hasAsset(asset) {
                    Button(role: .destructive) { store.removeAsset(asset) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .id("\(asset.rawValue)-\(store.revision)")
    }

    func render() {
        let cfg = store.effectiveConfig()
        let m = store.members.first ?? Member(reg: "123", name: "Ana", surname: "Example", email: "ana@example.com")
        let bg = store.image(.background), ph = store.photo(m), logo = store.image(.logo)
        preview = CardRenderer.renderCard(member: m, config: cfg, qrText: cfg.qrText(for: m), photo: ph,
                                          logo: logo, background: bg)
        let imgs = CardRenderer.appleImages(config: cfg, layout: cfg.appleLayout, photo: ph, logo: logo, background: bg)
        walletPreview = (imgs["strip@2x.png"] ?? imgs["background@2x.png"]).flatMap { UIImage(data: $0) }
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
                    LabeledField(label: "Pass Type ID", text: $store.config.applePassTypeId, prompt: "pass.com.club.member", plain: true)
                    LabeledField(label: "Team ID", text: $store.config.appleTeamId, prompt: "10 characters", plain: true)
                    Picker("Certificate", selection: $store.config.appleCertMode) {
                        Text(".cer + .pem key").tag("pem")
                        Text(".p12 file").tag("p12")
                    }
                    if store.config.appleCertMode == "p12" {
                        AssetRow(asset: .appleP12) { target = .asset(.appleP12) }
                        LabeledField(label: ".p12 password", text: $store.config.appleP12Password, secure: true)
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
                    LabeledField(label: "Issuer ID", text: $store.config.googleIssuerId, prompt: "3388…", keyboard: .numberPad, plain: true)
                    AssetRow(asset: .googleServiceAccount) { target = .asset(.googleServiceAccount) }
                    LabeledField(label: "Pass class", text: $store.config.googleClassSuffix, prompt: "membership", plain: true)
                    LabeledField(label: "Logo URL", text: $store.config.googleLogoUrl, prompt: "https://… (optional)", keyboard: .URL, plain: true)
                    LabeledField(label: "Banner URL", text: $store.config.googleHeroUrl, prompt: "https://… (optional)", keyboard: .URL, plain: true)
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
                    LabeledField(label: "Server", text: $store.config.smtpHost, prompt: "smtp.gmail.com", keyboard: .URL, plain: true)
                    LabeledContent("Port") {
                        TextField("465", value: $store.config.smtpPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Picker("Security", selection: $store.config.smtpSecurity) {
                        Text("SSL/TLS").tag("SSL")
                        Text("None").tag("None")
                    }
                    LabeledField(label: "Username", text: $store.config.smtpUser, prompt: "you@gmail.com", keyboard: .emailAddress, plain: true)
                    LabeledField(label: "Password", text: $store.config.smtpPassword, prompt: "Gmail App password", secure: true)
                    Button("Use Gmail settings") {
                        store.config.smtpHost = "smtp.gmail.com"; store.config.smtpPort = 465; store.config.smtpSecurity = "SSL"
                        if store.config.fromEmail.isEmpty { store.config.fromEmail = store.config.smtpUser }
                    }
                } header: { Text("Mail server") } footer: {
                    Text("Use SSL/TLS on port 465 (Gmail: smtp.gmail.com). STARTTLS on port 587 isn't supported.")
                }
                Section("Sender") {
                    LabeledField(label: "From name", text: $store.config.fromName, prompt: "Club name")
                    LabeledField(label: "From email", text: $store.config.fromEmail, prompt: "club@gmail.com", keyboard: .emailAddress, plain: true)
                    LabeledField(label: "Reply-to", text: $store.config.replyTo, prompt: "optional", keyboard: .emailAddress, plain: true)
                }
                Section {
                    LabeledField(label: "Subject", text: $store.config.emailSubject)
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
