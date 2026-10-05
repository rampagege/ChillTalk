import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Posted after settings were changed by another Mac through sync.
    static let settingsSyncedFromCloud = Notification.Name("SettingsSyncedFromCloud")
}

/// Syncs vocabulary, settings, usage and history through the iCloud Drive folder.
///
/// Every Mac writes only its own folder (`ChillTalk/devices/<id>/`) and reads everyone
/// else's, so iCloud never sees two writers on one file and never makes conflict copies.
/// API keys are never synced.
@MainActor
final class SyncService: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case vocabulary, settings, usage, history
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case unavailable        // iCloud Drive not enabled
        case off                // nothing selected
        case idle(Date?)
        case syncing
        case failed(String)
    }

    struct Device: Identifiable, Codable, Equatable {
        let id: String
        var name: String
        var updatedAt: Date
    }

    static let shared = SyncService(root: SyncService.defaultRoot(), defaults: .standard,
                                    history: .shared, vocabulary: .shared)

    @Published private(set) var status: Status = .off
    @Published private(set) var otherDevices: [Device] = []
    @Published var enabled: [Kind: Bool] {
        didSet { persistToggles(); updateTimer(); syncSoon() }
    }
    @Published var mergeHistory: Bool {
        didSet { persistToggles(); applyRemoteHistoryVisibility(); syncSoon() }
    }

    let deviceID: String
    let deviceName: String
    private let root: URL?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingRemote = false

    /// UserDefaults keys synced as settings (no API keys; those live in the Keychain).
    static let settingKeys = [
        "asrProvider", "dashScopeASRModel", "dashScopeBatchASRModel", "polishEnabled", "polishProvider", "dashScopePolishModel",
        "openRouterModel", "hotkeyPreset", "trailingPeriod", "phoneticCorrection",
        "dictationLanguage", "mixEnglish", "voiceProcessing", "recognitionMode"
    ]
    private static let contextKey = "recognitionContext"

    init(root: URL?, defaults: UserDefaults, history: HistoryStore, vocabulary: VocabularyStore,
         deviceName: String = Host.current().localizedName ?? "Mac") {
        self.root = root
        self.defaults = defaults
        self.history = history
        self.vocabulary = vocabulary
        self.deviceName = deviceName
        if let id = defaults.string(forKey: "sync.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "sync.deviceID")
        }
        var toggles: [Kind: Bool] = [:]
        for kind in Kind.allCases { toggles[kind] = defaults.bool(forKey: "sync.\(kind.rawValue)") }
        enabled = toggles
        mergeHistory = defaults.object(forKey: "sync.mergeHistory") as? Bool ?? true
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/ChillTalk`, if iCloud Drive is on.
    nonisolated static func defaultRoot() -> URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("ChillTalk", isDirectory: true)
    }

    var isAvailable: Bool { root != nil }
    var isAnyEnabled: Bool { enabled.values.contains(true) }

    // MARK: - Lifecycle

    func start() {
        applyRemoteHistoryVisibility()
        // Local changes → push shortly after.
        history.$records.dropFirst().sink { [weak self] _ in self?.syncSoon() }.store(in: &cancellables)
        history.$usage.dropFirst().sink { [weak self] _ in self?.syncSoon() }.store(in: &cancellables)
        vocabulary.$entries.dropFirst().sink { [weak self] _ in
            guard self?.isApplyingRemote == false else { return }
            self?.syncSoon()
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        updateTimer()
        syncNow()
    }

    /// Polls other Macs every 30s, but only while at least one kind is synced.
    private func updateTimer() {
        if isAnyEnabled && isAvailable {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncNow() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Debounced sync after a local change.
    func syncSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func syncNow() {
        guard let root = root else { status = .unavailable; return }
        guard isAnyEnabled else {
            status = .off
            history.remoteRecords = []
            history.remoteUsage = [:]
            return
        }
        status = .syncing
        do {
            let mine = root.appendingPathComponent("devices/\(deviceID)", isDirectory: true)
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            // Stamp local edits first, so a not-yet-pushed local change beats an older remote one.
            if enabled[.settings] == true { Self.settingKeys.forEach(stampSetting) }
            if enabled[.vocabulary] == true { stampSetting(Self.contextKey) }
            let others = try readOtherDevices(root: root)
            pull(from: others)
            try push(to: mine)
            status = .idle(Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Push (this Mac's folder)

    private func push(to folder: URL) throws {
        try write(Device(id: deviceID, name: deviceName, updatedAt: Date()), to: folder.appendingPathComponent("device.json"))

        if enabled[.vocabulary] == true {
            let snapshot = VocabularySnapshot(
                entries: vocabulary.entries,
                deleted: vocabulary.deleted,
                context: defaults.string(forKey: Self.contextKey) ?? "",
                contextUpdatedAt: defaults.object(forKey: "sync.stamp.\(Self.contextKey)") as? Date
            )
            try write(snapshot, to: folder.appendingPathComponent("vocabulary.json"))
        }
        if enabled[.settings] == true {
            var values: [String: SyncedSetting] = [:]
            for key in Self.settingKeys {
                guard let value = SyncedSetting.Value(defaults.object(forKey: key)),
                      let stamp = defaults.object(forKey: "sync.stamp.\(key)") as? Date else { continue }
                values[key] = SyncedSetting(value: value, updatedAt: stamp)
            }
            try write(values, to: folder.appendingPathComponent("settings.json"))
        }
        if enabled[.usage] == true {
            try write(history.usage, to: folder.appendingPathComponent("usage.json"))
        }
        if enabled[.history] == true {
            try write(history.records, to: folder.appendingPathComponent("history.json"))
        }
    }

    /// Records when a local setting last changed (compared with what was last pushed).
    private func stampSetting(_ key: String) {
        let current = defaults.object(forKey: key)
        let last = defaults.object(forKey: "sync.last.\(key)")
        guard current != nil else { return }
        if !Self.equal(current, last) || defaults.object(forKey: "sync.stamp.\(key)") == nil {
            defaults.set(Date(), forKey: "sync.stamp.\(key)")
            defaults.set(current, forKey: "sync.last.\(key)")
        }
    }

    // MARK: - Pull (other Macs' folders)

    private struct RemoteDevice {
        let info: Device
        let folder: URL
    }

    private func readOtherDevices(root: URL) throws -> [RemoteDevice] {
        let devicesDir = root.appendingPathComponent("devices", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: devicesDir, includingPropertiesForKeys: nil) else {
            otherDevices = []
            return []
        }
        let remotes: [RemoteDevice] = folders.compactMap { folder in
            guard folder.lastPathComponent != deviceID,
                  let info: Device = read(folder.appendingPathComponent("device.json")) else { return nil }
            return RemoteDevice(info: info, folder: folder)
        }
        otherDevices = remotes.map(\.info).sorted { $0.updatedAt > $1.updatedAt }
        return remotes
    }

    private func pull(from remotes: [RemoteDevice]) {
        if enabled[.vocabulary] == true {
            isApplyingRemote = true
            for remote in remotes {
                guard let snapshot: VocabularySnapshot = read(remote.folder.appendingPathComponent("vocabulary.json")) else { continue }
                vocabulary.merge(remote: snapshot.entries, remoteDeleted: snapshot.deleted)
                if let stamp = snapshot.contextUpdatedAt,
                   stamp > (defaults.object(forKey: "sync.stamp.\(Self.contextKey)") as? Date ?? .distantPast) {
                    applySetting(Self.contextKey, value: snapshot.context, stamp: stamp)
                }
            }
            isApplyingRemote = false
        }

        if enabled[.settings] == true {
            var changed = false
            for remote in remotes {
                guard let values: [String: SyncedSetting] = read(remote.folder.appendingPathComponent("settings.json")) else { continue }
                for (key, setting) in values where Self.settingKeys.contains(key) {
                    let localStamp = defaults.object(forKey: "sync.stamp.\(key)") as? Date ?? .distantPast
                    if setting.updatedAt > localStamp {
                        applySetting(key, value: setting.value.object, stamp: setting.updatedAt)
                        changed = true
                    }
                }
            }
            if changed { NotificationCenter.default.post(name: .settingsSyncedFromCloud, object: nil) }
        }

        if enabled[.usage] == true {
            var total: [String: DailyUsage] = [:]
            for remote in remotes {
                guard let usage: [String: DailyUsage] = read(remote.folder.appendingPathComponent("usage.json")) else { continue }
                for (day, value) in usage { total[day] = HistoryStore.sum([total[day] ?? DailyUsage(), value]) }
            }
            history.remoteUsage = total
        } else {
            history.remoteUsage = [:]
        }

        if enabled[.history] == true {
            var records: [DictationRecord] = []
            for remote in remotes {
                guard var list: [DictationRecord] = read(remote.folder.appendingPathComponent("history.json")) else { continue }
                for i in list.indices { list[i].deviceName = remote.info.name }
                records += list
            }
            history.remoteRecords = records
        } else {
            history.remoteRecords = []
        }
        applyRemoteHistoryVisibility()
    }

    private func applySetting(_ key: String, value: Any, stamp: Date) {
        defaults.set(value, forKey: key)
        defaults.set(value, forKey: "sync.last.\(key)")
        defaults.set(stamp, forKey: "sync.stamp.\(key)")
        if key == Self.contextKey {
            NotificationCenter.default.post(name: .settingsSyncedFromCloud, object: nil)
        }
    }

    private func applyRemoteHistoryVisibility() {
        history.showsRemoteRecords = enabled[.history] == true && mergeHistory
    }

    private func persistToggles() {
        for (kind, on) in enabled { defaults.set(on, forKey: "sync.\(kind.rawValue)") }
        defaults.set(mergeHistory, forKey: "sync.mergeHistory")
    }

    // MARK: - Files

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        // Sub-second precision: "last edit wins" must order edits made within one second.
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Reads a JSON file; if iCloud evicted it to a placeholder, asks for a download and
    /// returns nil (the next sync picks it up).
    private func read<T: Decodable>(_ url: URL) -> T? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
            }
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }
}

struct VocabularySnapshot: Codable {
    var entries: [VocabularyEntry]
    var deleted: [UUID: Date]
    var context: String
    var contextUpdatedAt: Date?
}

struct SyncedSetting: Codable {
    enum Value: Codable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)

        init?(_ object: Any?) {
            switch object {
            case let v as String: self = .string(v)
            case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): self = .bool(v.boolValue)
            case let v as Int: self = .int(v)
            default: return nil
            }
        }

        var object: Any {
            switch self {
            case .string(let v): return v
            case .bool(let v): return v
            case .int(let v): return v
            }
        }
    }

    let value: Value
    let updatedAt: Date
}
