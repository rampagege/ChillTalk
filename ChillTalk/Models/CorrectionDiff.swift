import Foundation

/// Finds word substitutions between what was inserted and what the user corrected it to,
/// e.g. "发给令尼亚那边" → "发给 Linear 那边" yields ("令尼亚", "Linear").
enum CorrectionDiff {
    struct Substitution: Equatable, Hashable {
        var wrong: String
        var correct: String
    }

    /// Longer spans are sentence rewrites, not misrecognized words.
    static let maxWrongLength = 12
    static let maxCorrectLength = 24
    /// Share of the original's characters that must survive for the edit to count as a correction.
    static let minSimilarity = 0.5

    static func substitutions(from original: String, to corrected: String) -> [Substitution] {
        let a = Array(original)
        let b = Array(corrected)
        var result: [Substitution] = []

        let (changes, common) = hunks(a, b)
        // Mostly rewritten: the user changed what they meant, not how a word was heard.
        // Measured against the original: replacing a transliteration with a longer English
        // word ("令尼亚" → "Linear") shouldn't count as a rewrite.
        guard Double(common) >= Double(a.count) * minSimilarity else { return [] }

        for hunk in expandToLatinWords(changes, a, b) {
            var (aStart, aEnd, bStart, bEnd) = hunk
            // Pure insertions/deletions aren't substitutions.
            guard aEnd > aStart, bEnd > bStart else { continue }
            // A single changed CJK character ("宁" → "林") isn't a usable rule on its own.
            // Prefer the following character: names usually continue to the right, while the
            // character before is often a particle like 跟/给.
            if aEnd - aStart == 1 && isCJKLike(a[aStart]) {
                if aEnd < a.count && bEnd < b.count && !isSeparator(a[aEnd]) {
                    aEnd += 1; bEnd += 1
                } else if aStart > 0 && bStart > 0 && !isSeparator(a[aStart - 1]) {
                    aStart -= 1; bStart -= 1
                }
            }
            let wrong = trim(String(a[aStart..<aEnd]))
            let correct = trim(String(b[bStart..<bEnd]))
            guard !wrong.isEmpty, !correct.isEmpty,
                  wrong.count <= maxWrongLength, correct.count <= maxCorrectLength,
                  normalized(wrong) != normalized(correct) else { continue }
            let substitution = Substitution(wrong: wrong, correct: correct)
            if !result.contains(substitution) { result.append(substitution) }
        }
        return result
    }

    // MARK: - Private

    /// Changed regions as (aStart, aEnd, bStart, bEnd), from a character-level LCS.
    /// Adjacent changes separated only by spaces/punctuation are merged. Also returns the
    /// number of unchanged characters.
    private static func hunks(_ a: [Character], _ b: [Character]) -> ([(Int, Int, Int, Int)], Int) {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n == 0 || m == 0 { return ([], 0) }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var raw: [(Int, Int, Int, Int)] = []
        var i = 0, j = 0
        var open: (Int, Int)? = nil
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                if let start = open { raw.append((start.0, i, start.1, j)); open = nil }
                i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) { j += 1 } else { i += 1 }
            }
        }
        if let start = open { raw.append((start.0, n, start.1, m)) }

        var merged: [(Int, Int, Int, Int)] = []
        for hunk in raw {
            if let last = merged.last, shouldMerge(last, hunk, a, b) {
                merged[merged.count - 1] = (last.0, hunk.1, last.2, hunk.3)
            } else {
                merged.append(hunk)
            }
        }
        return (merged, lcs[0][0])
    }

    /// A change touching an English/alphanumeric word covers that whole word on both sides:
    /// "j1v" → "jev" is one word, not "1v" → "ev"; "chilltak" → "ChillTalk" isn't lost as a
    /// case change plus an inserted letter. Overlapping results are merged.
    private static func expandToLatinWords(_ hunks: [(Int, Int, Int, Int)],
                                           _ a: [Character], _ b: [Character]) -> [(Int, Int, Int, Int)] {
        var result: [(Int, Int, Int, Int)] = []
        for var h in hunks {
            // Grow left while both sides continue the same word.
            while h.0 > 0 && h.2 > 0 && isWordChar(a[h.0 - 1]) && isWordChar(b[h.2 - 1])
                    && (touchesWord(a, h.0, h.1) || touchesWord(b, h.2, h.3)) {
                h.0 -= 1; h.2 -= 1
            }
            while h.1 < a.count && h.3 < b.count && isWordChar(a[h.1]) && isWordChar(b[h.3])
                    && (touchesWord(a, h.0, h.1) || touchesWord(b, h.2, h.3)) {
                h.1 += 1; h.3 += 1
            }
            if let last = result.last, h.0 <= last.1 || h.2 <= last.3 {
                result[result.count - 1] = (min(last.0, h.0), max(last.1, h.1), min(last.2, h.2), max(last.3, h.3))
            } else {
                result.append(h)
            }
        }
        return result
    }

    /// Whether the span (or the spot, for an empty span) is part of a Latin word.
    private static func touchesWord(_ s: [Character], _ start: Int, _ end: Int) -> Bool {
        if s[start..<end].contains(where: isWordChar) { return true }
        return (start > 0 && isWordChar(s[start - 1])) || (end < s.count && isWordChar(s[end]))
    }

    /// Letters of space-separated scripts: English/digits and Korean Hangul.
    private static func isWordChar(_ c: Character) -> Bool {
        if c.isASCII { return c.isLetter || c.isNumber }
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
    }

    private static func isCJKLike(_ c: Character) -> Bool {
        !c.isASCII && !isSeparator(c) && !isWordChar(c)
    }

    /// Merge when only spaces/punctuation separate two changes, or when two small changes
    /// sit a few characters apart inside one word ("四美格鲁泰" → "司美格鲁肽" is one term,
    /// not "四美→司美" + "鲁泰→鲁肽").
    private static func shouldMerge(_ last: (Int, Int, Int, Int), _ next: (Int, Int, Int, Int),
                                    _ a: [Character], _ b: [Character]) -> Bool {
        let gapA = a[last.1..<next.0], gapB = b[last.3..<next.2]
        if gapA.allSatisfy(isSeparator) && gapB.allSatisfy(isSeparator) { return true }
        let small = { (h: (Int, Int, Int, Int)) in h.1 - h.0 <= 2 && h.3 - h.2 <= 2 }
        return gapA.count <= 3 && !gapA.contains(where: isSeparator) && small(last) && small(next)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Punctuation-, whitespace- and case-insensitive form, to drop cosmetic edits.
    private static func normalized(_ s: String) -> String {
        String(s.filter { !isSeparator($0) }).lowercased()
    }
}
