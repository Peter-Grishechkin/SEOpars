// Печатает CGWindowID видимого обычного окна процесса: winid <pid>.
// Нужен для `screencapture -l` в scripts/render-screenshots.sh.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("использование: winid <pid>")
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
       let h = b["Height"] as? Double, h > 100 {
        print(id)
        break
    }
}
