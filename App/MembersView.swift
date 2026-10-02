import SwiftUI
import PhotosUI
import PassKit
import UniformTypeIdentifiers
import ClubCore

let spreadsheetTypes: [UTType] = [UTType(filenameExtension: "ods"), UTType(filenameExtension: "xlsx"),
                                  .commaSeparatedText, .spreadsheet].compactMap { $0 }

struct MembersView: View {
    @EnvironmentObject var store: Store
    @State private var selection = Set<Int>()
    @State private var editMode: EditMode = .inactive
    @State private var importing = false
    @State private var askSend = false
    @State private var sendList: [Member] = []

    var selectedMembers: [Member] { store.members.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if store.members.isEmpty {
                    ContentUnavailableView {
                        Label("No members yet", systemImage: "person.3")
                    } description: {
                        Text("Import your member list (.ods, .xlsx or .csv with Reg number, Name, Surname, email) – " +
                             "or import everything from the Ubuntu app under Settings.")
                    } actions: {
                        Button("Import member list") { importing = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $selection) {
                        Section {
                            ForEach(store.members) { m in
                                NavigationLink(value: m) { MemberRow(member: m) }
                            }
                        } header: {
                            Text("\(store.membersFileName) · \(store.members.count) members")
                        }
                    }
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("Members")
            .navigationDestination(for: Member.self) { MemberDetailView(member: $0) }
            .toolbar {
                if !store.members.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Select") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            if !editMode.isEditing { selection.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label("Import member list…", systemImage: "square.and.arrow.down") }
                        if !store.members.isEmpty {
                            Divider()
                            Button { store.run(store.members, send: false) } label: {
                                Label("Make cards for everyone", systemImage: "wallet.pass")
                            }
                            Button { prepareSend(store.members) } label: {
                                Label("Email cards to everyone…", systemImage: "paperplane")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                if editMode.isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(selection.count == store.members.count ? "None" : "All") {
                            selection = selection.count == store.members.count ? [] : Set(store.members.map(\.id))
                        }
                        Spacer()
                        Text("\(selection.count) selected").font(.footnote)
                        Spacer()
                        Button("Make") { store.run(selectedMembers, send: false) }.disabled(selection.isEmpty)
                        Button("Email") { prepareSend(selectedMembers) }.disabled(selection.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: spreadsheetTypes + [.data]) { result in
                if case .success(let url) = result {
                    do { store.importMembers(data: try Store.read(url), fileName: url.lastPathComponent) }
                    catch { store.show(error, title: "Import failed") }
                }
            }
            .confirmationDialog("Email membership cards", isPresented: $askSend, titleVisibility: .visible) {
                let notYet = sendList.filter { store.sentDate($0) == nil }
                if !notYet.isEmpty && notYet.count < sendList.count {
                    Button("Email \(notYet.count) not emailed yet") { store.run(notYet, send: true) }
                }
                Button(notYet.count == sendList.count ? "Email \(sendList.count) member(s)" : "Email all \(sendList.count) (again)") {
                    store.run(sendList, send: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cards are made and sent from \(store.fromAddress(store.config)).")
            }
        }
    }

    func prepareSend(_ list: [Member]) {
        sendList = list
        askSend = true
    }
}

struct MemberRow: View {
    @EnvironmentObject var store: Store
    let member: Member

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let t = store.thumbnail(member) {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.square").resizable().scaledToFit().foregroundStyle(.tertiary).padding(6)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(member.fullName).font(.body.weight(.medium))
                Text("#\(member.reg) · \(member.email.isEmpty ? "no email" : member.email)")
                    .font(.footnote)
                    .foregroundStyle(member.emailValid ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer()
            if let d = store.sentDate(member) {
                VStack(alignment: .trailing) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(d.prefix(10)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .id("\(member.id)-\(store.revision)")
    }
}

struct MemberDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    let member: Member
    @State private var preview: UIImage?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var pass: PKPass?
    @State private var showPass = false
    @State private var working = false
    @State private var lastCard: GeneratedCard?
    @State private var sharing = false

    var body: some View {
        Form {
            Section {
                if let p = preview {
                    Image(uiImage: p).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            Section("Member") {
                LabeledContent("Reg. No.", value: member.reg)
                LabeledContent("Name", value: member.name)
                LabeledContent("Surname", value: member.surname)
                LabeledContent("Email", value: member.email)
                if let d = store.sentDate(member) { LabeledContent("Emailed", value: d) }
            }
            Section("Photo") {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label(store.photoURL(member) == nil ? "Choose photo" : "Change photo", systemImage: "person.crop.square")
                }
                if store.photoURL(member) != nil {
                    Button(role: .destructive) { store.removePhoto(member); render() } label: {
                        Label("Remove photo", systemImage: "trash")
                    }
                }
            }
            Section {
                Button { addToAppleWallet() } label: { Label("Add to Apple Wallet on this iPhone", systemImage: "wallet.pass") }
                    .disabled(working || !store.config.appleEnabled)
                Button { openGoogle() } label: { Label("Open Google Wallet link", systemImage: "link") }
                    .disabled(working || !store.config.googleEnabled)
                Button { store.run([member], send: true) } label: { Label("Email card to member", systemImage: "paperplane") }
                    .disabled(working || !member.emailValid)
                if lastCard != nil {
                    Button { sharing = true } label: { Label("Share card files…", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Test & send")
            } footer: {
                Text("Google Wallet passes can only be saved on Android phones – on iPhone the link shows Google's web page.")
            }
            if working { Section { HStack { ProgressView(); Text("Working…") } } }
        }
        .navigationTitle(member.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .task { render() }
        .onChange(of: store.revision) { render() }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self) { store.setPhoto(member, data: d) }
                pickedPhoto = nil
                render()
            }
        }
        .sheet(isPresented: $showPass) { if let p = pass { AddPassView(pass: p).ignoresSafeArea() } }
        .sheet(isPresented: $sharing) {
            if let c = lastCard { ShareSheet(items: [c.pkpassURL, c.pngURL].compactMap { $0 }) }
        }
    }

    func render() {
        let cfg = store.effectiveConfig()
        preview = CardRenderer.renderCard(member: member, config: cfg, qrText: cfg.qrText(for: member),
                                          photo: store.photo(member), logo: store.image(.logo), background: store.image(.background))
    }

    func addToAppleWallet() {
        working = true
        Task {
            defer { working = false }
            do {
                let card = try await store.generateSingle(member, apple: true, google: false)
                lastCard = card
                guard let data = card.pkpass else { return }
                pass = try PKPass(data: data)
                showPass = true
            } catch { store.show(error, title: "Apple Wallet") }
        }
    }

    func openGoogle() {
        working = true
        Task {
            defer { working = false }
            do {
                let card = try await store.generateSingle(member, apple: false, google: true)
                lastCard = card
                if let s = card.googleURL, let u = URL(string: s) { openURL(u) }
            } catch { store.show(error, title: "Google Wallet") }
        }
    }
}
