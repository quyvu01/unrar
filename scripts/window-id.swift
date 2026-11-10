// Prints the CGWindowID of the largest on-screen window owned by the given app.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Unrar"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = windows.max { a, b in
    func area(_ w: [String: Any]) -> Double {
        let r = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (r["Width"] ?? 0) * (r["Height"] ?? 0)
    }
    return area(a) < area(b)
}
if let id = best?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
