import Foundation

/// Spoken editing commands, applied to a whole utterance before it's pasted:
///   "…first idea. Scratch that. Second idea."  → drops the sentence before "scratch that"
///   "Scratch that" (alone)                     → removes the last dictation pasted there
///   "Clear the input" (alone or leading)       → empties the input box first
///   "…, send it" (trailing)                    → presses Return after pasting
/// Destructive commands only trigger when said on their own (or leading, for clear), so
/// "can you clear the input field in the form?" is still just text.
struct VoiceCommands {
    var text: String
    var clearFirst = false
    var undoLast = false
    var submit = false

    private static let clear = ["clear the input", "clear input", "clear the field", "clear the box",
                                "clear everything", "clear it all", "clear all"]
    private static let scratch = ["scratch that", "undo that", "delete that", "strike that"]
    private static let send = ["send it", "send that", "submit it", "submit that", "press enter", "hit enter"]

    static func interpret(_ raw: String) -> VoiceCommands {
        var out = VoiceCommands(text: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let whole = norm(out.text)
        if clear.contains(whole) { return VoiceCommands(text: "", clearFirst: true) }
        if scratch.contains(whole) { return VoiceCommands(text: "", undoLast: true) }

        // Leading "Clear the input. <new text>"
        for c in clear where whole.hasPrefix(c + " ") {
            out.clearFirst = true
            out.text = dropLeadingWords(out.text, count: c.split(separator: " ").count)
            break
        }
        // Trailing "…, send it."
        let now = norm(out.text)
        for s in send where now == s || now.hasSuffix(" " + s) {
            out.submit = true
            out.text = dropTrailingWords(out.text, count: s.split(separator: " ").count)
            break
        }
        // "… scratch that …" in the middle: drop the sentence before each occurrence.
        out.text = applyScratch(out.text, undoLast: &out.undoLast)
        return out
    }

    /// Lowercase, letters/digits/spaces only.
    static func norm(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func applyScratch(_ s: String, undoLast: inout Bool) -> String {
        let pattern = #"[,.;!?]?\s*\b(scratch that|strike that)\b[.,!?]?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        var text = s
        while let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) {
            let before = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Keep everything up to the end of the previous sentence.
            let kept: String
            if let end = before.lastIndex(where: { ".!?".contains($0) }) {
                kept = String(before[...end])
            } else {
                kept = ""
                if before.isEmpty { undoLast = true }  // "Scratch that. New text" → undo the last paste too
            }
            text = [kept, capitalizeFirst(after)].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return text
    }

    private static func dropLeadingWords(_ s: String, count: Int) -> String {
        var words = 0, i = s.startIndex, inWord = false
        while i < s.endIndex {
            let isWord = s[i].isLetter || s[i].isNumber
            if isWord && !inWord { words += 1; if words > count { break } }
            inWord = isWord
            i = s.index(after: i)
        }
        let rest = String(s[i...]).drop { $0.isWhitespace || $0.isPunctuation }  // leading only; keep the "?"
        return capitalizeFirst(String(rest))
    }

    private static func dropTrailingWords(_ s: String, count: Int) -> String {
        var t = s.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        for _ in 0..<count {
            guard let sp = t.lastIndex(where: { $0 == " " }) else { t = ""; break }
            t = String(t[..<sp])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if let last = t.last, ",;:".contains(last) { t.removeLast() }
        if let last = t.last, !".!?".contains(last), !t.isEmpty { t += "." }
        return t
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
