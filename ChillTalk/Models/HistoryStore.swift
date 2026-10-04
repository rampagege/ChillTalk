import Combine
import Foundation

struct DictationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// ASR output before polish.
    let rawText: String
    /// What was inserted.
    let finalText: String
    let audioSeconds: Double
    let asrProvider: String
    let polished: Bool
    /// The user's fix from the history page, if any. Optional so older files still decode.
    var correctedText: String?
    /// Set only on records synced from another Mac (its name); nil for this Mac's records.
    var deviceName: String?

    var isFromOtherDevice: Bool { deviceName != nil }

    /// What the history shows: the correction if there is one, otherwise what was inserted.
    var displayText: String { correctedText ?? finalText }
}

/// Per-day totals. Numbers only, no text, so statistics keep working with history off.
struct DailyUsage: Codable, Equatable {
    var count = 0
    var characters = 0
    var audioSeconds: Double = 0
    var estimatedCostYuan: Double = 0
}

/// Local dictation history and usage statistics, stored as JSON in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxRecords = 500

    /// Newest first.
    @Published private(set) var records: [DictationRecord] = []
    /// Keyed by "yyyy-MM-dd" in the user's time zone.
    @Published private(set) var usage: [String: DailyUsage] = [:]
    /// Other Macs' records and usage, filled in by SyncService when sync is on.
    @Published var remoteRecords: [DictationRecord] = []
    @Published var remoteUsage: [String: DailyUsage] = [:]
    /// Whether the list shows other Macs' records alongside this Mac's.
    @Published var showsRemoteRecords = false

    /// What the history list shows, newest first.
    var displayRecords: [DictationRecord] {
        guard showsRemoteRecords, !remoteRecords.isEmpty else { return records }
        return (records + remoteRecords).sorted { $0.date > $1.date }
    }

    @Published var isHistoryEnabled: Bool {
        didSet { defaults.set(isHistoryEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "historyEnabled"
    private let directory: URL
    private let defaults: UserDefaults
    private let calendar: Calendar

    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var usageURL: URL { directory.appendingPathComponent("usage.json") }

    init(directory: URL? = nil, defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChillTalk", isDirectory: true)
        self.defaults = defaults
        self.calendar = calendar
        self.isHistoryEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        records = load([DictationRecord].self, from: historyURL) ?? []
        usage = load([String: DailyUsage].self, from: usageURL) ?? [:]
    }

    func record(rawText: String, finalText: String, audioSeconds: Double, asrProvider: String,
                polished: Bool, estimatedCostYuan: Double, date: Date = Date()) {
        let key = dayKey(for: date)
        var day = usage[key] ?? DailyUsage()
        day.count += 1
        day.characters += finalText.count
        day.audioSeconds += audioSeconds
        day.estimatedCostYuan += estimatedCostYuan
        usage[key] = day
        save(usage, to: usageURL)

        guard isHistoryEnabled else { return }
        let entry = DictationRecord(id: UUID(), date: date, rawText: rawText, finalText: finalText,
                                    audioSeconds: audioSeconds, asrProvider: asrProvider, polished: polished)
        records.insert(entry, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        save(records, to: historyURL)
    }

    func correct(id: UUID, text: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].correctedText = text
        save(records, to: historyURL)
    }

    /// Deletes history text. Usage statistics are kept.
    func clearHistory() {
        records = []
        save(records, to: historyURL)
    }

    /// This Mac's usage plus other Macs' (when usage sync is on).
    func usage(on date: Date = Date()) -> DailyUsage {
        let key = dayKey(for: date)
        return Self.sum([usage[key], remoteUsage[key]].compactMap { $0 })
    }

    func monthUsage(containing date: Date = Date()) -> DailyUsage {
        let prefix = String(dayKey(for: date).prefix(7))  // yyyy-MM
        let days = Array(usage.filter { $0.key.hasPrefix(prefix) }.values)
            + Array(remoteUsage.filter { $0.key.hasPrefix(prefix) }.values)
        return Self.sum(days)
    }

    static func sum(_ days: [DailyUsage]) -> DailyUsage {
        days.reduce(into: DailyUsage()) { total, day in
            total.count += day.count
            total.characters += day.characters
            total.audioSeconds += day.audioSeconds
            total.estimatedCostYuan += day.estimatedCostYuan
        }
    }

    // MARK: - Persistence

    private func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(type, from: data) {
            return value
        }
        // Corrupt file: keep it for inspection and start fresh rather than failing launch.
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        print("⚠️ \(url.lastPathComponent) was unreadable, moved to \(backup.lastPathComponent)")
        return nil
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            print("⚠️ Failed to save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
