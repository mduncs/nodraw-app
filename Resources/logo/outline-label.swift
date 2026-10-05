import Foundation
import CoreText

// Headless: resolve the system's SF Mono medium face and export glyph outlines.
let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SFMono-Terminal.ttf")
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as! [CTFontDescriptor]
let descriptor = descriptors.first { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String)?.contains("Medium") == true } ?? descriptors[0]
let font = CTFontCreateWithFontDescriptor(descriptor, 44, nil)
let name = CTFontCopyPostScriptName(font) as String
precondition(name.contains("SFMono"), "Expected SF Mono, got \(name)")
fputs("Label font: \(name)\n", stderr)
var x: CGFloat = 200
print("<g fill=\"#11110f\" fill-opacity=\".85\" aria-label=\"nodraw 256.256\">")
for character in "nodraw 256.256".utf16 {
    var code = character
    var glyph: CGGlyph = 0
    precondition(CTFontGetGlyphsForCharacters(font, &code, &glyph, 1))
    if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
        var commands: [String] = []
        path.applyWithBlock { element in
            let e = element.pointee
            func point(_ i: Int) -> String { "\(e.points[i].x) \(e.points[i].y)" }
            switch e.type {
            case .moveToPoint: commands.append("M\(point(0))")
            case .addLineToPoint: commands.append("L\(point(0))")
            case .addQuadCurveToPoint: commands.append("Q\(point(0)) \(point(1))")
            case .addCurveToPoint: commands.append("C\(point(0)) \(point(1)) \(point(2))")
            case .closeSubpath: commands.append("Z")
            @unknown default: fatalError("Unknown path element")
            }
        }
        print("<path transform=\"matrix(1 0 0 -1 \(x) 244)\" d=\"\(commands.joined(separator: " "))\"/>")
    }
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    x += advance.width
}
print("</g>")
