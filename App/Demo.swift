import UIKit
import ClubCore

/// Sample club: loaded from Settings → "Load sample club" (and automatically with "-demo" for CI screenshots).
enum Demo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var startTab: Int { Int(arg("-tab") ?? "0") ?? 0 }
    static var openFirstMember: Bool { arg("-screen") == "member" }
    static var screen: String { isOn ? (arg("-screen") ?? "") : "" }

    static func picture(_ size: CGSize, draw: (CGContext) -> Void) -> Data {
        CardRenderer.renderer(size, opaque: true).image { draw($0.cgContext) }.jpegData(compressionQuality: 0.9) ?? Data()
    }

    @MainActor
    static func install(into store: Store, force: Bool = false) {
        guard isOn || force else { return }
        store.resetAll()
        var c = AppConfig()
        c.clubName = "Your Sports Club"; c.season = "2026"; c.applePassTypeId = "pass.com.example.club"
        c.appleTeamId = "ABCDE12345"; c.googleIssuerId = "3388000000012345678"; c.smtpUser = "club@example.com"
        c.fromEmail = "club@example.com"; c.fromName = "Your Sports Club"
        store.config = c
        let csv = "Reg number;Name;Surname;email;Blood type;Rh\n1;John;Johnson;john@example.com;A;+\n" +
                  "2;Emma;Smith;emma@example.com;0;-\n3;Liam;Brown;liam@example.com;AB;+\n" +
                  "4;Olivia;Davis;olivia@example.com;B;+\n5;Noah;Wilson;noah@example.com;0;+\n" +
                  "6;Ava;Taylor;ava@example.com;A;-\n7;Lucas;Miller;lucas@example.com;;\n8;Mia;Anderson;mia@example.com;AB;-\n"
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
        let palette: [(UIColor, UIColor)] = [
            (UIColor(red: 0.75, green: 0.80, blue: 0.85, alpha: 1), UIColor(red: 0.80, green: 0.15, blue: 0.15, alpha: 1)),
            (UIColor(red: 0.86, green: 0.80, blue: 0.72, alpha: 1), UIColor(red: 0.15, green: 0.35, blue: 0.70, alpha: 1)),
            (UIColor(red: 0.78, green: 0.86, blue: 0.80, alpha: 1), UIColor(red: 0.10, green: 0.45, blue: 0.30, alpha: 1)),
            (UIColor(red: 0.88, green: 0.82, blue: 0.86, alpha: 1), UIColor(red: 0.55, green: 0.20, blue: 0.55, alpha: 1)),
            (UIColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 1), UIColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1)),
        ]
        for (i, m) in store.members.enumerated() where i < palette.count {
            let (bgc, shirt) = palette[i]
            let skin = [UIColor(red: 0.90, green: 0.75, blue: 0.62, alpha: 1), UIColor(red: 0.80, green: 0.62, blue: 0.48, alpha: 1)][i % 2]
            let p = picture(CGSize(width: 600, height: 800)) { ctx in
                ctx.setFillColor(bgc.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                ctx.setFillColor(shirt.cgColor); ctx.fillEllipse(in: CGRect(x: 90, y: 440, width: 420, height: 520))
                ctx.setFillColor(skin.cgColor); ctx.fillEllipse(in: CGRect(x: 205, y: 170, width: 190, height: 240))
                ctx.setFillColor(UIColor(white: 0.18, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: 195, y: 140, width: 210, height: 120))
            }
            store.setPhoto(m, data: p)
        }
        _ = photo
        let logo = CardRenderer.renderer(CGSize(width: 400, height: 400), opaque: false).image { ctx in
            UIColor(red: 0.05, green: 0.30, blue: 0.55, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 400, height: 400))
            UIColor.white.setStroke()
            let wave = UIBezierPath()
            wave.lineWidth = 22
            wave.move(to: CGPoint(x: 70, y: 250))
            wave.addCurve(to: CGPoint(x: 330, y: 250), controlPoint1: CGPoint(x: 150, y: 170), controlPoint2: CGPoint(x: 250, y: 330))
            wave.stroke()
            let t = "YSC" as NSString
            let f = UIFont.systemFont(ofSize: 110, weight: .heavy)
            let sz = t.size(withAttributes: [.font: f])
            t.draw(at: CGPoint(x: 200 - sz.width / 2, y: 70), withAttributes: [.font: f, .foregroundColor: UIColor.white])
        }.pngData()
        if let l = logo { try? store.setAsset(.logo, data: l, ext: "png") }
        for i in [1, 3, 4] where i < store.members.count { store.sent[store.sentKey(store.members[i])] = "2026-10-12 18:30" }
        store.saveSent()
        if screen == "progress" { store.config.appleEnabled = false; store.config.googleEnabled = false }
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
