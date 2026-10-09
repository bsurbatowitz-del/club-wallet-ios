import UIKit
import ClubCore

/// Demo content used only when the app is started with "-demo" (CI screenshots in the simulator).
enum Demo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var startTab: Int { Int(arg("-tab") ?? "0") ?? 0 }
    static var openFirstMember: Bool { arg("-screen") == "member" }

    static func picture(_ size: CGSize, draw: (CGContext) -> Void) -> Data {
        CardRenderer.renderer(size, opaque: true).image { draw($0.cgContext) }.jpegData(compressionQuality: 0.9) ?? Data()
    }

    @MainActor
    static func install(into store: Store) {
        guard isOn else { return }
        store.resetAll()
        var c = AppConfig()
        c.clubName = "Triatlon Klub Budva"; c.season = "2026"; c.applePassTypeId = "pass.me.tkbudva.member"
        c.appleTeamId = "ABCDE12345"; c.googleIssuerId = "3388000000012345678"; c.smtpUser = "club@example.com"
        c.fromEmail = "club@example.com"
        store.config = c
        let csv = "Reg number;Name;Surname;email;Blood type;Rh\n1;Bojan;Šurbatović;bojan@example.com;A;+\n" +
                  "2;Ana;Đokić;ana@example.com;0;-\n3;Marko;Marković;marko@example.com;AB;\n4;Ivana;Horvat;not-an-email;;\n"
        store.importMembers(data: Data(csv.utf8), fileName: "members.csv")
        let bg = picture(CGSize(width: 1600, height: 900)) { ctx in
            let colors = [UIColor(red: 1, green: 0.6, blue: 0.3, alpha: 1).cgColor, UIColor(red: 0.05, green: 0.3, blue: 0.55, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 900), options: [])
            ctx.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 1000, y: 260, width: 260, height: 260))
        }
        try? store.setAsset(.background, data: bg, ext: "jpg")
        let photo = picture(CGSize(width: 600, height: 800)) { ctx in
            ctx.setFillColor(UIColor(red: 0.75, green: 0.8, blue: 0.85, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ctx.setFillColor(UIColor(red: 0.9, green: 0.75, blue: 0.62, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: 200, y: 160, width: 200, height: 250))
            ctx.setFillColor(UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: 100, y: 430, width: 400, height: 500))
        }
        if let m = store.members.first { store.setPhoto(m, data: photo) }
        store.sent[store.sentKey(store.members[1])] = "2026-10-01 18:30"
        store.alert = nil
        // rendered pictures for CI to inspect (Documents/demo)
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("demo")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cfg = store.effectiveConfig()
        if let m = store.members.first {
            let bgImg = store.image(.background), ph = store.photo(m)
            for overlay in [0, 20, 35] {
                var c2 = cfg; c2.bgOverlay = overlay
                let card = CardRenderer.renderCard(member: m, config: c2, qrText: c2.qrText(for: m), photo: ph, logo: nil, background: bgImg)
                try? card.pngData()?.write(to: out.appendingPathComponent("card-overlay\(overlay).png"))
                let imgs = CardRenderer.appleImages(config: c2, layout: "storeCard", photo: ph, logo: nil, background: bgImg)
                try? imgs["strip@2x.png"]?.write(to: out.appendingPathComponent("strip-overlay\(overlay).png"))
            }
        }
    }
}
