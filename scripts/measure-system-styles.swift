// Замер системных цветов и стилей текста macOS для дизайн-системы (DESIGN-SYSTEM-2026-11-09.md).
// Запуск: source scripts/sdk.sh; swiftc -sdk "${SDKROOT:-$(xcrun --show-sdk-path)}" scripts/measure-system-styles.swift -o build/measure && build/measure

import AppKit
func hex(_ c: NSColor) -> String {
    guard let s = c.usingColorSpace(.sRGB) else { return "n/a" }
    let r = Int(round(s.redComponent*255)), g = Int(round(s.greenComponent*255)), b = Int(round(s.blueComponent*255)), a = s.alphaComponent
    return String(format: "#%02X%02X%02X a=%.3f", r, g, b, a)
}
let colors: [(String, NSColor)] = [
 ("systemRed", .systemRed), ("systemOrange", .systemOrange), ("systemGreen", .systemGreen), ("systemBlue", .systemBlue), ("systemPurple", .systemPurple), ("systemYellow", .systemYellow), ("systemGray", .systemGray),
 ("labelColor", .labelColor), ("secondaryLabelColor", .secondaryLabelColor), ("tertiaryLabelColor", .tertiaryLabelColor), ("quaternaryLabelColor", .quaternaryLabelColor),
 ("quaternarySystemFill", .quaternarySystemFill), ("tertiarySystemFill", .tertiarySystemFill),
 ("windowBackgroundColor", .windowBackgroundColor), ("controlBackgroundColor", .controlBackgroundColor), ("textBackgroundColor", .textBackgroundColor), ("underPageBackgroundColor", .underPageBackgroundColor),
 ("separatorColor", .separatorColor), ("gridColor", .gridColor), ("controlAccentColor", .controlAccentColor), ("controlColor", .controlColor), ("selectedContentBackgroundColor", .selectedContentBackgroundColor), ("alternatingRow1", NSColor.alternatingContentBackgroundColors[1]), ("textColor", .textColor),
]
for name in ["aqua", "darkAqua"] {
    let app = NSAppearance(named: name == "aqua" ? .aqua : .darkAqua)!
    print("== \(name)")
    app.performAsCurrentDrawingAppearance {
        for (n, c) in colors { print("\(n)\t\(hex(c))") }
    }
}
print("== fonts")
let styles: [(String, NSFont.TextStyle)] = [("largeTitle", .largeTitle), ("title1", .title1), ("title2", .title2), ("title3", .title3), ("headline", .headline), ("body", .body), ("callout", .callout), ("subheadline", .subheadline), ("footnote", .footnote), ("caption1", .caption1), ("caption2", .caption2)]
for (n, s) in styles {
    let f = NSFont.preferredFont(forTextStyle: s)
    let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    let w = traits?[.weight] as? CGFloat ?? 0
    print("\(n)\tsize=\(f.pointSize)\tweight=\(w)\tname=\(f.fontName)\tlineHeight=\(NSLayoutManager().defaultLineHeight(for: f))")
}
