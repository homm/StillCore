import AppKit

func sanitizeANSI(_ input: String) -> String {
    var s = input
    // Убираем возврат каретки + erase line (например "\r\u{1B}[2K")
    s = s.replacingOccurrences(of: "\r", with: "")
    s = s.replacingOccurrences(of: "\u{1B}[2K", with: "")    
    return s
}

func attributedFromANSI(_ input: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    let pattern = #"\u001B\[(\d+)(;\d+)*m"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let s = sanitizeANSI(input)

    var pos = s.startIndex
    for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        let r = Range(match.range, in: s)!
        let before = String(s[pos..<r.lowerBound])
        result.append(NSAttributedString(string: before, attributes: attributes))

        // разбор кодов
        let codes = s[r].dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
        for code in codes {
            switch code {
            case 0: // reset
                attributes[.foregroundColor] = NSColor.labelColor
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            case 1: // bold
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            case 2: // dim
                attributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.4)

            case 30: attributes[.foregroundColor] = NSColor.black
            case 31: attributes[.foregroundColor] = NSColor.systemRed
            case 32: attributes[.foregroundColor] = NSColor.systemGreen
            case 33: attributes[.foregroundColor] = NSColor.systemYellow
            case 34: attributes[.foregroundColor] = NSColor.systemBlue
            case 35: attributes[.foregroundColor] = NSColor.magenta
            case 36: attributes[.foregroundColor] = NSColor.systemCyan
            case 37: attributes[.foregroundColor] = NSColor.white
            case 39: attributes[.foregroundColor] = NSColor.labelColor

            default: break
            }
        }
        pos = r.upperBound
    }
    if pos < s.endIndex {
        result.append(NSAttributedString(string: String(s[pos...]), attributes: attributes))
    }
    return result
}
