import Foundation

/// Corrects vocabulary terms the ASR spelled differently but pronounced the same, by
/// comparing pinyin. E.g. with 司美格鲁肽 in the vocabulary, 四美格鲁泰 is fixed even though
/// that exact misspelling was never seen.
enum PhoneticMatcher {
    struct Pattern {
        let term: String
        let id: UUID
        /// Normalized syllables to match.
        let syllables: [String]
        /// Raw (tone-less) syllables, for strict matching of short patterns.
        let rawSyllables: [String]
    }

    /// Shorter patterns collide with ordinary words (李明 / 黎明), so they need an exact
    /// pinyin match and are only used when the caller allows it.
    static let minFuzzySyllables = 3

    // MARK: - Building patterns

    /// Pattern from a CJK string (the term itself, or one of its recorded misrecognitions).
    static func pattern(for text: String, term: String, id: UUID) -> Pattern? {
        let chars = Array(text)
        guard chars.count >= 2, chars.allSatisfy(isCJK) else { return nil }
        let raw = chars.compactMap(syllable)
        guard raw.count == chars.count else { return nil }
        return Pattern(term: term, id: id, syllables: raw.map(normalize), rawSyllables: raw)
    }

    // MARK: - Matching

    /// - Parameter allowShort: ids whose 2-syllable patterns may be used (key terms).
    static func correct(_ text: String, patterns: [Pattern], allowShort: Set<UUID>) -> (String, [UUID: Int]) {
        let usable = patterns
            .filter { $0.syllables.count >= minFuzzySyllables || allowShort.contains($0.id) }
            .sorted { $0.syllables.count > $1.syllables.count }
        guard !usable.isEmpty else { return (text, [:]) }

        let chars = Array(text)
        let raw: [String?] = chars.map { isCJK($0) ? syllable($0) : nil }
        let normalized: [String?] = raw.map { $0.map(normalize) }

        var output = ""
        var hits: [UUID: Int] = [:]
        var i = 0
        outer: while i < chars.count {
            if raw[i] != nil {
                for p in usable where i + p.syllables.count <= chars.count {
                    let range = i..<(i + p.syllables.count)
                    let window = String(chars[range])
                    guard window != p.term, matches(p, raw: raw[range], normalized: normalized[range]) else { continue }
                    output += p.term
                    hits[p.id, default: 0] += 1
                    i += p.syllables.count
                    continue outer
                }
            }
            output.append(chars[i])
            i += 1
        }
        return (output, hits)
    }

    private static func matches(_ p: Pattern, raw: ArraySlice<String?>, normalized: ArraySlice<String?>) -> Bool {
        let n = p.syllables.count
        if n < minFuzzySyllables {
            // Short: every syllable must be exactly the same (tones ignored).
            return zip(raw, p.rawSyllables).allSatisfy { $0 == $1 }
        }
        var mismatches = 0
        for (candidate, expected) in zip(normalized, p.syllables) {
            guard let candidate = candidate else { return false }
            if candidate != expected {
                mismatches += 1
                // Long terms tolerate one misheard syllable.
                if mismatches > (n >= 4 ? 1 : 0) { return false }
            }
        }
        return true
    }

    // MARK: - Pinyin

    private static var cache: [Character: String] = [:]
    private static let cacheLock = NSLock()

    /// Tone-less lowercase pinyin for one CJK character.
    static func syllable(_ c: Character) -> String? {
        cacheLock.lock()
        if let cached = cache[c] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let s = NSMutableString(string: String(c))
        guard CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false) else { return nil }
        let result = (s as String).lowercased().trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty, result != String(c) else { return nil }

        cacheLock.lock()
        cache[c] = result
        cacheLock.unlock()
        return result
    }

    /// Merges sounds commonly confused in Mandarin as spoken across regions and by ASR:
    /// zh/z, ch/c, sh/s, n/l initials and -ng/-n finals.
    static func normalize(_ syllable: String) -> String {
        var s = syllable
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where s.hasPrefix(from) {
            s = to + s.dropFirst(from.count)
        }
        if s.hasPrefix("n") && s.count > 1 { s = "l" + s.dropFirst() }
        if s.hasSuffix("ng") && s.count > 2 { s = String(s.dropLast()) }
        return s
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
