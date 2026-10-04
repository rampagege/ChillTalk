import Combine
import Foundation

struct VocabularyEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case correction
        case manual
        case pack
        case imported
    }

    let id: UUID
    /// Correct spelling. Sent to ASR as a hot word and listed in the polish prompt.
    var term: String
    /// Ways the ASR got it wrong; replaced with `term` when `autoReplace` is on.
    var misrecognitions: [String]
    var autoReplace: Bool
    /// Starred "key term": sent as a super hot word. Optional so older files decode.
    var isKey: Bool?
    let source: Source
    /// How many times a replacement fired.
    var hitCount: Int
    let createdAt: Date
    var lastUsedAt: Date?
    /// Last user edit, for merging across Macs. Optional so older files decode.
    var updatedAt: Date?

    var modifiedAt: Date { updatedAt ?? createdAt }
}

/// The user's personal vocabulary: hot words for recognition, replacement rules for
/// known misrecognitions, and a glossary for polish. Stored locally as JSON.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()
    /// DashScope accepts up to 2000 instant hot words.
    static let maxHotwords = 2000
    static let hotwordWeight = 4
    /// DashScope's weight for super hot words, of which at most 50 are allowed.
    static let keyWeight = 50
    static let maxKeyTerms = 50
    /// Shorter misrecognitions are too likely to match ordinary words.
    static let minReplaceLength = 2

    /// Newest first.
    @Published private(set) var entries: [VocabularyEntry] = []

    /// Deleted entry ids → deletion time, so deletions propagate through sync.
    private(set) var deleted: [UUID: Date] = [:]

    private let url: URL
    private let deletedURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChillTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("vocabulary.json")
        deletedURL = dir.appendingPathComponent("vocabulary-deleted.json")
        entries = load()
        deleted = (try? Data(contentsOf: deletedURL)).flatMap { try? Self.decoder.decode([UUID: Date].self, from: $0) } ?? [:]
    }

    // MARK: - Editing

    /// Adds a term, merging misrecognitions into an existing entry with the same term.
    @discardableResult
    func add(term rawTerm: String, misrecognitions: [String], source: VocabularyEntry.Source) -> VocabularyEntry? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let wrong = Self.cleanMisrecognitions(misrecognitions, term: term)

        if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            var entry = entries[index]
            entry.term = term
            entry.misrecognitions = Self.cleanMisrecognitions(entry.misrecognitions + wrong, term: term)
            entry.updatedAt = Date()
            entries.remove(at: index)
            entries.insert(entry, at: 0)
            save()
            return entry
        }
        let entry = VocabularyEntry(id: UUID(), term: term, misrecognitions: wrong, autoReplace: true, isKey: nil,
                                    source: source, hitCount: 0, createdAt: Date(), lastUsedAt: nil, updatedAt: Date())
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    /// Adds many terms at once (packs, imports); returns how many were new.
    @discardableResult
    func addMany(_ items: [(term: String, misrecognitions: [String])], source: VocabularyEntry.Source) -> Int {
        let before = entries.count
        for item in items {
            let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let wrong = Self.cleanMisrecognitions(item.misrecognitions, term: term)
            if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                let merged = Self.cleanMisrecognitions(entries[index].misrecognitions + wrong, term: entries[index].term)
                if merged != entries[index].misrecognitions {
                    entries[index].misrecognitions = merged
                    entries[index].updatedAt = Date()
                }
            } else {
                entries.insert(VocabularyEntry(id: UUID(), term: term, misrecognitions: wrong, autoReplace: true, isKey: nil,
                                               source: source, hitCount: 0, createdAt: Date(), lastUsedAt: nil,
                                               updatedAt: Date()), at: 0)
            }
        }
        save()
        return entries.count - before
    }

    func contains(term: String) -> Bool {
        entries.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
    }

    func update(_ entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var cleaned = entry
        cleaned.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.term.isEmpty else { return }
        cleaned.misrecognitions = Self.cleanMisrecognitions(entry.misrecognitions, term: cleaned.term)
        cleaned.updatedAt = Date()
        entries[index] = cleaned
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        deleted[id] = Date()
        save()
    }

    // MARK: - Sync

    /// Merges another Mac's vocabulary. Per entry, the most recent edit wins; deletions win
    /// over older edits; the same term added separately on two Macs collapses into one entry
    /// (the one with the smaller id, so every Mac picks the same). Returns whether anything
    /// changed locally.
    @discardableResult
    func merge(remote: [VocabularyEntry], remoteDeleted: [UUID: Date]) -> Bool {
        var changed = false
        for (id, date) in remoteDeleted where (deleted[id] ?? .distantPast) < date {
            deleted[id] = date
            if let index = entries.firstIndex(where: { $0.id == id }), entries[index].modifiedAt <= date {
                entries.remove(at: index)
                changed = true
            }
        }
        for entry in remote {
            if let deletedAt = deleted[entry.id], deletedAt >= entry.modifiedAt { continue }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                if entry.modifiedAt > entries[index].modifiedAt {
                    var incoming = entry
                    // Hit counts are per-Mac statistics; keep the larger.
                    incoming.hitCount = max(entry.hitCount, entries[index].hitCount)
                    entries[index] = incoming
                    changed = true
                }
            } else {
                entries.insert(entry, at: 0)
                changed = true
            }
        }
        if collapseDuplicateTerms() { changed = true }
        if changed { save() } else { saveDeleted() }
        return changed
    }

    /// Same term under two ids (added independently on two Macs): keep the smaller id,
    /// union the misrecognitions, and delete the other id everywhere.
    private func collapseDuplicateTerms() -> Bool {
        var changed = false
        var seen: [String: Int] = [:]
        var index = 0
        while index < entries.count {
            let key = entries[index].term.lowercased()
            if let firstIndex = seen[key] {
                let a = entries[firstIndex], b = entries[index]
                var keep = a.id.uuidString < b.id.uuidString ? a : b
                let drop = keep.id == a.id ? b : a
                keep.misrecognitions = Self.cleanMisrecognitions(a.misrecognitions + b.misrecognitions, term: keep.term)
                keep.hitCount = max(a.hitCount, b.hitCount)
                keep.isKey = (a.isKey == true || b.isKey == true) ? true : nil
                keep.updatedAt = max(a.modifiedAt, b.modifiedAt)
                entries[firstIndex] = keep
                entries.remove(at: index)
                deleted[drop.id] = keep.updatedAt
                changed = true
            } else {
                seen[key] = index
                index += 1
            }
        }
        return changed
    }

    // MARK: - Use

    /// Hot words for the ASR request, most recently useful first.
    func hotwords() -> [String: Int] {
        let ranked = entries.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        var result: [String: Int] = [:]
        var keyCount = 0
        for entry in ranked.prefix(Self.maxHotwords) {
            if entry.isKey == true && keyCount < Self.maxKeyTerms {
                result[entry.term] = Self.keyWeight
                keyCount += 1
            } else {
                result[entry.term] = Self.hotwordWeight
            }
        }
        return result
    }

    var keyTermCount: Int { entries.filter { $0.isKey == true }.count }

    /// Everything the ASR request should carry: hot words plus the user's context text.
    func recognitionHints() -> RecognitionHints {
        let settings = SettingsManager.shared
        return RecognitionHints(hotwords: hotwords(), context: settings.getRecognitionContext(),
                                language: settings.getDictationLanguage(), mixEnglish: settings.mixesEnglish())
    }

    /// Terms to keep verbatim during polish.
    func glossary(limit: Int = 200) -> [String] {
        Array(entries.prefix(limit).map(\.term))
    }

    /// Replaces known misrecognitions in one left-to-right pass, longest match first, so a
    /// replacement is never re-matched by a shorter rule. Updates hit counts.
    /// What the current vocabulary would do to `text`, without recording any hits.
    func preview(_ text: String) -> (text: String, hits: [UUID: Int]) {
        var (result, hits) = Self.replace(in: text, rules: replacementRules())
        if SettingsManager.shared.isPhoneticCorrectionEnabled(), SettingsManager.shared.getDictationLanguage().usesPinyin {
            let keyIDs = Set(entries.filter { $0.isKey == true }.map(\.id))
            let (phonetic, phoneticHits) = PhoneticMatcher.correct(result, patterns: phoneticPatterns(), allowShort: keyIDs)
            result = phonetic
            hits.merge(phoneticHits, uniquingKeysWith: +)
        }
        return (result, hits)
    }

    func applyReplacements(to text: String) -> String {
        let (result, hits) = preview(text)
        guard !hits.isEmpty else { return text }
        let now = Date()
        for (id, count) in hits {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].hitCount += count
                entries[index].lastUsedAt = now
            }
        }
        save()
        return result
    }

    /// Pronunciation patterns: the term itself when it's Chinese, plus every Chinese
    /// misrecognition (which is how English terms like Linear get a pronunciation).
    func phoneticPatterns() -> [PhoneticMatcher.Pattern] {
        entries.filter(\.autoReplace).flatMap { entry in
            ([entry.term] + entry.misrecognitions).compactMap {
                PhoneticMatcher.pattern(for: $0, term: entry.term, id: entry.id)
            }
        }
    }

    private func replacementRules() -> [(wrong: [Character], term: String, id: UUID)] {
        entries
            .filter(\.autoReplace)
            .flatMap { entry in
                entry.misrecognitions
                    .filter { $0.count >= Self.minReplaceLength }
                    .map { (wrong: Array($0), term: entry.term, id: entry.id) }
            }
            .sorted { $0.wrong.count > $1.wrong.count }
    }

    nonisolated static func replace(in text: String,
                                    rules: [(wrong: [Character], term: String, id: UUID)]) -> (String, [UUID: Int]) {
        guard !rules.isEmpty else { return (text, [:]) }
        let chars = Array(text)
        var output = ""
        var hits: [UUID: Int] = [:]
        var i = 0
        outer: while i < chars.count {
            for rule in rules where i + rule.wrong.count <= chars.count {
                if chars[i..<(i + rule.wrong.count)].elementsEqual(rule.wrong),
                   isWholeWord(chars, i, i + rule.wrong.count) {
                    output += rule.term
                    hits[rule.id, default: 0] += 1
                    i += rule.wrong.count
                    continue outer
                }
            }
            output.append(chars[i])
            i += 1
        }
        return (output, hits)
    }

    /// English/alphanumeric edges must be word boundaries, so "Clade" doesn't fire inside
    /// "Clades". CJK has no spaces between words, so it's matched anywhere.
    private nonisolated static func isWholeWord(_ chars: [Character], _ start: Int, _ end: Int) -> Bool {
        let isWord = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        if isWord(chars[start]) && start > 0 && isWord(chars[start - 1]) { return false }
        if isWord(chars[end - 1]) && end < chars.count && isWord(chars[end]) { return false }
        return true
    }

    private static func cleanMisrecognitions(_ values: [String], term: String) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != term && seen.insert($0).inserted }
    }

    // MARK: - Persistence

    private func load() -> [VocabularyEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode([VocabularyEntry].self, from: data) { return value }
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        print("⚠️ vocabulary.json was unreadable, moved to \(backup.lastPathComponent)")
        return []
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func saveDeleted() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Tombstones older than 90 days have long reached every Mac.
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        deleted = deleted.filter { $0.value > cutoff }
        try? encoder.encode(deleted).write(to: deletedURL, options: .atomic)
    }

    private func save() {
        saveDeleted()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            print("⚠️ Failed to save vocabulary: \(error.localizedDescription)")
        }
    }
}
