import Foundation

/// Декодирует HTML из байтов. Порядок: charset из заголовка → BOM → `<meta charset>` →
/// проверка на UTF-8 → windows-1251. Строковым инициализаторам угадывать не даём.
public enum HTMLTextDecoder {
    public static func decode(_ data: Data, contentType: String?) -> (text: String, charset: String) {
        if data.isEmpty { return ("", "") }

        if let name = charset(fromContentType: contentType), let enc = encoding(named: name),
           let s = String(data: data, encoding: enc) {
            return (s, name.lowercased())
        }

        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return (s, "utf-8")
        }
        if bytes.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) {
            return (s.trimmingPrefix("\u{FEFF}").description, "utf-16le")
        }
        if bytes.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) {
            return (s.trimmingPrefix("\u{FEFF}").description, "utf-16be")
        }

        if let name = sniffMetaCharset(data), let enc = encoding(named: name) {
            if let s = String(data: data, encoding: enc) {
                return (s, name.lowercased())
            }
        }

        if let s = String(data: data, encoding: .utf8) { return (s, "utf-8") }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, "windows-1251") }
        return (String(decoding: data, as: UTF8.self), "utf-8 (с ошибками)")
    }

    static func charset(fromContentType ct: String?) -> String? {
        guard let ct, let r = ct.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var v = ct[r.upperBound...]
        if let semi = v.firstIndex(of: ";") { v = v[..<semi] }
        let name = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        return name.isEmpty ? nil : name
    }

    static func sniffMetaCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : UInt8(ascii: " ") }, as: UTF8.self)
        let pattern = #"<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9_:.\-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let r = Range(m.range(at: 1), in: head)
        else { return nil }
        return String(head[r])
    }

    static func encoding(named name: String) -> String.Encoding? {
        let lower = name.lowercased()
        // Частые ошибочные названия.
        let aliases = ["cp1251": "windows-1251", "win-1251": "windows-1251", "utf8": "utf-8"]
        let canonical = aliases[lower] ?? lower
        let cf = CFStringConvertIANACharSetNameToEncoding(canonical as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
