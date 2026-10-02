import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ClubCore

/// Draws the card image, the Apple Wallet pass pictures and QR codes (same layout as the Ubuntu app).
enum CardRenderer {
    // MARK: basics
    static func color(_ hex: String, _ fallback: RGB) -> UIColor {
        let c = RGB.parse(hex, default: fallback)
        return UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func renderer(_ size: CGSize, opaque: Bool) -> UIGraphicsImageRenderer {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: f)
    }

    static func qr(_ text: String, size: CGFloat) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return UIImage() }
        let scale = size / out.extent.width
        let scaled = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }

    /// Scale + crop to exactly `size` (like CSS background-size: cover). focusY 0.42 keeps faces in view.
    static func cover(_ img: UIImage, _ size: CGSize, focusY: CGFloat = 0.5) -> UIImage {
        let s = max(size.width / img.size.width, size.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        let x = (size.width - w) / 2
        let y = max(size.height - h, min(0, size.height / 2 - h * focusY))
        return renderer(size, opaque: true).image { _ in img.draw(in: CGRect(x: x, y: y, width: w, height: h)) }
    }

    static func fit(_ img: UIImage, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        let s = min(maxW / img.size.width, maxH / img.size.height, 1)
        return CGSize(width: floor(img.size.width * s), height: floor(img.size.height * s))
    }

    static func font(_ size: CGFloat, bold: Bool) -> UIFont { .systemFont(ofSize: size, weight: bold ? .bold : .regular) }

    /// Draw text, shrinking it until it fits `maxWidth`.
    static func text(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool, color: UIColor, maxWidth: CGFloat? = nil,
                     minSize: CGFloat = 12) {
        var fs = size
        var f = font(fs, bold: bold)
        if let mw = maxWidth {
            while fs > minSize, (s as NSString).size(withAttributes: [.font: f]).width > mw { fs -= 2; f = font(fs, bold: bold) }
        }
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }

    /// Dark fade from the left edge so white text stays readable on light pictures.
    static func scrim(_ ctx: CGContext, width: CGFloat, height: CGFloat, strength: CGFloat, reach: CGFloat) {
        let colors = [UIColor.black.withAlphaComponent(strength).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width * reach, y: 0), options: [])
        ctx.restoreGState()
    }

    static func jpeg(_ img: UIImage, maxSide: CGFloat, quality: CGFloat = 0.88) -> Data? {
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: floor(img.size.width * s), height: floor(img.size.height * s))
        return renderer(size, opaque: true).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: quality)
    }

    static func squareJPEG(_ img: UIImage, side: CGFloat) -> Data? {
        cover(img, CGSize(width: side, height: side), focusY: 0.42).jpegData(compressionQuality: 0.88)
    }

    // MARK: colours from the background picture
    static func rgbToHLS(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, l, 0) }
        let d = mx - mn
        let s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
        var h: CGFloat
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, l, s)
    }

    static func hlsToRGB(_ h: CGFloat, _ l: CGFloat, _ s: CGFloat) -> RGB {
        func v(_ m1: CGFloat, _ m2: CGFloat, _ hue0: CGFloat) -> CGFloat {
            var hue = hue0.truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            if hue < 1.0 / 6 { return m1 + (m2 - m1) * hue * 6 }
            if hue < 0.5 { return m2 }
            if hue < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - hue) * 6 }
            return m1
        }
        if s == 0 { let x = Int(l * 255); return RGB(r: x, g: x, b: x) }
        let m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s
        let m1 = 2 * l - m2
        return RGB(r: Int(v(m1, m2, h + 1.0 / 3) * 255), g: Int(v(m1, m2, h) * 255), b: Int(v(m1, m2, h - 1.0 / 3) * 255))
    }

    /// Background colour = the picture's dominant colourful tone (deepened); white text; light label colour.
    static func colors(from img: UIImage) -> (bg: String, fg: String, label: String) {
        let n = 32
        guard let cg = cover(img, CGSize(width: n, height: n)).cgImage else { return ("#0B3C5D", "#FFFFFF", "#9FD3F5") }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weight = [CGFloat](repeating: 0, count: 12)
        var sums = [(CGFloat, CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        var avg = (CGFloat(0), CGFloat(0), CGFloat(0))
        for i in 0..<(n * n) {
            let r = CGFloat(px[i * 4]) / 255, g = CGFloat(px[i * 4 + 1]) / 255, b = CGFloat(px[i * 4 + 2]) / 255
            avg.0 += r; avg.1 += g; avg.2 += b
            let (h, l, s) = rgbToHLS(r, g, b)
            if l > 0.92 || l < 0.06 { continue }
            let bin = min(11, Int(h * 12))
            let w = 0.35 + s
            weight[bin] += w
            sums[bin].0 += r * w; sums[bin].1 += g * w; sums[bin].2 += b * w; sums[bin].3 += w
        }
        var r: CGFloat, g: CGFloat, b: CGFloat
        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), sums[best].3 > 0 {
            r = sums[best].0 / sums[best].3; g = sums[best].1 / sums[best].3; b = sums[best].2 / sums[best].3
        } else {
            let c = CGFloat(n * n); r = avg.0 / c; g = avg.1 / c; b = avg.2 / c
        }
        let (h, l, s) = rgbToHLS(r, g, b)
        let bg = hlsToRGB(h, min(l, 0.32), min(1, s * 1.1))
        let label = hlsToRGB(h, 0.80, min(1, s + 0.2))
        return (bg.hex, "#FFFFFF", label.hex)
    }

    // MARK: card image (email attachment)
    static func renderCard(member m: Member, config c: AppConfig, qrText: String, photo: UIImage?, logo: UIImage?,
                           background: UIImage?) -> UIImage {
        let W: CGFloat = 1012, H: CGFloat = 638, pad: CGFloat = 48
        let bgc = color(c.bgColor, RGB(r: 11, g: 60, b: 93))
        let fg = color(c.fgColor, RGB(r: 255, g: 255, b: 255))
        let lc = color(c.labelColor, RGB(r: 159, g: 211, b: 245))
        return renderer(CGSize(width: W, height: H), opaque: true).image { ctx in
            if let bg = background {
                cover(bg, CGSize(width: W, height: H)).draw(at: .zero)
                bgc.withAlphaComponent(CGFloat(max(0, min(100, c.bgOverlay))) / 100).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                scrim(ctx.cgContext, width: W, height: H, strength: 0.5, reach: 0.75)
            } else {
                bgc.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            }
            // QR bottom-right
            let qs: CGFloat = 250
            let qx = W - pad - qs, qy = H - pad - qs
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: qx - 8, y: qy - 8, width: qs + 16, height: qs + 16), cornerRadius: 16).fill()
            qr(qrText, size: qs * 2).draw(in: CGRect(x: qx, y: qy, width: qs, height: qs))

            // photo top-right
            var rightLimit = W - pad
            if let p = photo {
                let ph = qy - pad - 30
                let pw = min(qs, floor(ph * 0.82))
                let px = qx + (qs - pw) / 2
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: px - 5, y: pad - 5, width: pw + 10, height: ph + 10), cornerRadius: 22).fill()
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: CGRect(x: px, y: pad, width: pw, height: ph), cornerRadius: 18).addClip()
                cover(p, CGSize(width: pw, height: ph), focusY: 0.42).draw(at: CGPoint(x: px, y: pad))
                ctx.cgContext.restoreGState()
                rightLimit = px - 28
            }

            // header
            var x = pad
            if let lg = logo {
                let sz = fit(lg, maxW: 220, maxH: 90)
                lg.draw(in: CGRect(origin: CGPoint(x: x, y: pad), size: sz))
                x += sz.width + 24
            }
            text(c.clubName, at: CGPoint(x: x, y: pad - 6), size: 44, bold: true, color: fg, maxWidth: rightLimit - x)
            text(c.cardTitle.uppercased(), at: CGPoint(x: x, y: pad + 52), size: 24, bold: true, color: lc,
                 maxWidth: rightLimit - x)

            // fields
            let maxW = min(qx, rightLimit + 28) - pad - 30
            var y: CGFloat = 205
            func field(_ label: String, _ value: String, _ size: CGFloat, _ yy: CGFloat) {
                text(label.uppercased(), at: CGPoint(x: pad, y: yy), size: 20, bold: true, color: lc)
                text(value, at: CGPoint(x: pad, y: yy + 24), size: size, bold: true, color: fg, maxWidth: maxW)
            }
            field("Member", m.fullName, 46, y)
            y += 100
            field("Reg. No.", m.reg, 40, y)
            if !c.season.isEmpty {
                text("SEASON", at: CGPoint(x: pad + 250, y: y), size: 20, bold: true, color: lc)
                text(c.season, at: CGPoint(x: pad + 250, y: y + 24), size: 40, bold: true, color: fg)
            }
            y += 92
            text("EMAIL", at: CGPoint(x: pad, y: y), size: 20, bold: true, color: lc)
            text(m.email, at: CGPoint(x: pad, y: y + 24), size: 26, bold: false, color: fg, maxWidth: qx - pad - 30)
        }
    }

    // MARK: Apple pass images
    static func defaultIcon(_ size: CGFloat, _ c: AppConfig) -> UIImage {
        renderer(CGSize(width: size, height: size), opaque: true).image { ctx in
            color(c.bgColor, RGB(r: 11, g: 60, b: 93)).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let initials = c.clubName.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
            let f = font(size * 0.42, bold: true)
            let s = (initials.isEmpty ? "C" : initials) as NSString
            let ts = s.size(withAttributes: [.font: f])
            s.draw(at: CGPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2),
                   withAttributes: [.font: f, .foregroundColor: color(c.fgColor, RGB(r: 255, g: 255, b: 255))])
        }
    }

    static func rounded(_ img: UIImage, _ size: CGSize, radius: CGFloat) -> UIImage {
        renderer(size, opaque: false).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius).addClip()
            cover(img, size, focusY: 0.42).draw(at: .zero)
        }
    }

    /// icon / logo / thumbnail / background / strip PNGs for the chosen layout (generic, eventTicket, storeCard).
    static func appleImages(config c: AppConfig, layout: String, photo: UIImage?, logo: UIImage?, background: UIImage?) -> [String: Data] {
        var out: [String: Data] = [:]
        let bgc = color(c.bgColor, RGB(r: 11, g: 60, b: 93))
        for (mult, suffix) in [(CGFloat(1), ""), (2, "@2x"), (3, "@3x")] {
            let iconSize = 29 * mult
            let icon: UIImage
            if let lg = logo {
                icon = renderer(CGSize(width: iconSize, height: iconSize), opaque: false).image { _ in
                    let sz = fit(lg, maxW: iconSize, maxH: iconSize)
                    lg.draw(in: CGRect(x: (iconSize - sz.width) / 2, y: (iconSize - sz.height) / 2, width: sz.width, height: sz.height))
                }
                let ls = fit(lg, maxW: 160 * mult, maxH: 50 * mult)
                out["logo\(suffix).png"] = renderer(ls, opaque: false).image { _ in lg.draw(in: CGRect(origin: .zero, size: ls)) }.pngData()
            } else {
                icon = defaultIcon(iconSize, c)
            }
            out["icon\(suffix).png"] = icon.pngData()

            if (layout == "generic" || layout == "eventTicket"), let p = photo {
                let t = 90 * mult
                out["thumbnail\(suffix).png"] = rounded(p, CGSize(width: t, height: t), radius: 10 * mult).pngData()
            }
            if layout == "eventTicket", let bg = background {
                out["background\(suffix).png"] = cover(bg, CGSize(width: 180 * mult, height: 220 * mult)).pngData()
            }
            if layout == "storeCard", background != nil || photo != nil {
                let size = CGSize(width: 375 * mult, height: 123 * mult)
                out["strip\(suffix).png"] = renderer(size, opaque: true).image { ctx in
                    if let bg = background {
                        cover(bg, size).draw(at: .zero)
                        bgc.withAlphaComponent(CGFloat(max(0, min(100, c.bgOverlay))) / 100).setFill()
                    } else {
                        bgc.setFill()
                    }
                    ctx.fill(CGRect(origin: .zero, size: size))
                    if background != nil { scrim(ctx.cgContext, width: size.width, height: size.height, strength: 0.5, reach: 0.6) }
                    if let p = photo {
                        let ps = floor(size.height * 0.80)
                        let bx = size.width - ps - 14 * mult, by = (size.height - ps) / 2
                        UIColor.white.withAlphaComponent(0.92).setFill()
                        UIBezierPath(roundedRect: CGRect(x: bx - 2 * mult, y: by - 2 * mult, width: ps + 4 * mult,
                                                         height: ps + 4 * mult), cornerRadius: 14 * mult).fill()
                        rounded(p, CGSize(width: ps, height: ps), radius: 12 * mult).draw(at: CGPoint(x: bx, y: by))
                    }
                }.pngData()
            }
        }
        return out
    }
}
